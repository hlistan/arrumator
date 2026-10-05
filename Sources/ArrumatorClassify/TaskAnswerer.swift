import ArrumatorCore
import Foundation

/// The JSON schema a question about a task's documents is answered in: the answer first, so it streams as it is
/// written, then the documents it draws on and a request for more documents. Only string, array and object types are
/// used, which every grammar backend supports, so a document's number is a string.
public enum ConversationSchema {
    static let answerKey = "answer"
    static let sourcesKey = "sources"
    static let findKey = "find"

    public static var answer: JSONValue {
        ClassificationSchema.object([
            JSONEntry(answerKey, ClassificationSchema.string()),
            JSONEntry(sourcesKey, .orderedObject([JSONEntry("type", "array"), JSONEntry("items", ClassificationSchema.string())])),
            JSONEntry(findKey, ClassificationSchema.string()),
        ])
    }
}

/// Raw answer to a question about a task's documents.
struct ConversationAnswer: Decodable {
    var answer: String
    var sources: [String]
    var find: String
}

/// An answer the model gave, checked, and notes on what was dropped; or as far as it came before it was cut off, and why
/// it is incomplete.
public struct ValidatedAnswer: Sendable, Codable, Hashable {
    public var text: String
    public var sources: [Int64]
    public var find: String?
    public var notes: [String]
    public var incomplete: String?
}

/// Parses and checks an answer against what it was shown. The answer is untrusted input: a source is kept only when it
/// is the number of a document the answer was shown, as a citation is checked against the sources it claims (Gao et
/// al., ALCE, EMNLP 2023; docs/organizing-principles-sources.md#sources-for-conversations), each once; the request for
/// more documents is kept on one line, none when it is empty. An answer without text, one that only begins an answer
/// (`unfinished`), or a list missing from it, goes back to the model with the reasons.
public struct ConversationAnswerValidator: Sendable {
    /// The documents the answer was shown, by number, with their names.
    public let names: [Int64: String]
    public var shown: Set<Int64> { Set(names.keys) }

    public init(names: [Int64: String]) { self.names = names }

    /// Shown documents whose names do not matter to the check.
    public init(shown: Set<Int64>) { self.init(names: Dictionary(uniqueKeysWithValues: shown.map { ($0, "") })) }

    public func validate(_ text: String) throws -> ValidatedAnswer {
        let raw: ConversationAnswer
        do {
            raw = try JSONDecoder().decode(ConversationAnswer.self, from: Data(ModelOutput.jsonObject(text).utf8))
        } catch let DecodingError.keyNotFound(key, _) {
            throw AnswerValidationError.invalid(["\(key.stringValue) is missing; give \"\" or [] when there is nothing to give"])
        } catch {
            throw AnswerValidationError.notJSON(String(describing: error))
        }
        let answer = named(raw.answer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw AnswerValidationError.invalid(["\(ConversationSchema.answerKey) is empty"]) }
        if let unfinished = Self.unfinished(answer) { throw AnswerValidationError.invalid([unfinished]) }
        var notes: [String] = []
        var sources: [Int64] = []
        for written in raw.sources {
            let number = written.trimmingCharacters(in: Self.numberMarks)
            guard let id = Int64(number), shown.contains(id) else {
                notes.append("\(ConversationSchema.sourcesKey): “\(written)” is no document the answer was shown, dropped")
                continue
            }
            if !sources.contains(id) { sources.append(id) }
        }
        let find = DocumentLabel.oneLine(raw.find)
        return ValidatedAnswer(text: answer, sources: sources, find: find.isEmpty ? nil : find, notes: notes, incomplete: nil)
    }

    /// The answer with each shown document's number, written as the documents are shown to the model (`[42]`), given as
    /// its name, which is all the person sees of it: a number before the name goes, one alone becomes the name. The prompt
    /// asks for names; a model that writes numbers all the same is not left to show them. A number in brackets that is
    /// Markdown of its own stays as written: a link's words (`[42](…)`), a reference (`[42]: …`, `[42][…]`), and anything
    /// in code, inline or fenced, which shows text as it is.
    func named(_ answer: String) -> String {
        let whole = NSRange(answer.startIndex..., in: answer)
        let code = Self.codePattern.matches(in: answer, range: whole).map(\.range)
        var out = answer
        for match in Self.numberPattern.matches(in: answer, range: whole).reversed()
        where !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            guard let whole = Range(match.range, in: answer), let digits = Range(match.range(at: 1), in: answer),
                  let id = Int64(answer[digits]), let name = names[id], !name.isEmpty else { continue }
            let following = answer[whole.upperBound...]
            let spaced = answer[whole].last?.isWhitespace == true ? " " : ""
            out.replaceSubrange(whole, with: following.lowercased().hasPrefix(Self.namePrefix(name)) ? "" : name + spaced)
        }
        return out
    }

    /// A shown document's number as the model writes it, `[42]`, and the space after it; not when Markdown makes it a
    /// link's words or a reference, followed by `(`, `:` or `[`.
    static let numberPattern = regex(#"\[\s*(\d+)\s*\](?![(:\[])\s*"#)
    /// Code in Markdown: a fenced block, to its end or the answer's, and an inline span.
    static let codePattern = regex(#"(?s)```.*?(?:```|\z)|`[^`\n]*`"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) } catch {
            preconditionFailure("A pattern literal that does not compile: \(pattern)")
        }
    }

    /// Why `answer` only begins an answer, which goes back to the model; nil when it gives one. By its Markdown alone, in
    /// any language: an answer of headings and rules has nothing under them, a paragraph all in bold with a rule after it
    /// being a heading too, unless a heading carries a figure, which is an answer ("# 340 € in total"); and an answer
    /// whose one paragraph or list item, alone or under headings, ends with a colon announces what follows, and nothing
    /// does. An answer that gives something before a last line ending with a colon is an answer: a document's own field
    /// ("Assinatura:") or a total ("合计：") can end it.
    static func unfinished(_ answer: String) -> String? {
        guard let blocks = AnswerMarkdown.blocks(answer) else { return nil }
        let written = blocks.filter { !String($0.text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let ruled = blocks.last?.kind == .rule
        let titles = written.filter { block in
            if case .heading = block.kind { return true }
            return ruled && block.kind == .paragraph && block.text.runs.allSatisfy { run in
                run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                    || String(block.text[run.range].characters).allSatisfy(\.isWhitespace)
            }
        }
        let figures = titles.contains { $0.text.characters.contains(where: \.isNumber) }
        guard let last = written.last, titles.count < written.count || figures else {
            return "\(ConversationSchema.answerKey) holds only headings or rules: give the answer itself, in full"
        }
        guard written.count - titles.count == 1 else { return nil }
        switch last.kind {
        case .paragraph, .item:
            guard let end = String(last.text.characters).trimmingCharacters(in: .whitespacesAndNewlines).last, announcing.contains(end) else { return nil }
            return "\(ConversationSchema.answerKey) announces what follows and ends there: give what it announces, in full"
        case .heading, .quote, .code, .rule:
            return nil
        }
    }

    /// What ends a sentence that announces what follows: a colon, as Latin and other scripts write it, and as Chinese and
    /// Japanese write it full width.
    static let announcing: Set<Character> = [":", "："]

    /// How much of a name, after a number, shows the model wrote the name too.
    static func namePrefix(_ name: String) -> String { String(name.lowercased().prefix(namePrefixLength)) }
    static let namePrefixLength = 8

    /// What a model may write around a document's number, as it is shown: `[42]`, `#42`.
    static let numberMarks = CharacterSet(charactersIn: "[]# ").union(.whitespacesAndNewlines)
}

/// The text of an answer's `answer` field as the model writes its JSON object, read as the object streams in, its
/// escapes decoded: what the app shows of the answer before it is complete, and keeps of one cut off at its length
/// limit. Before the field begins it is empty; a model thinking aloud in `<think>` writes nothing of it.
enum StreamedAnswer {
    static func text(in partial: String) -> String {
        guard let start = valueStart(in: partial) else { return "" }
        return decoded(partial[start...])
    }

    /// Where the `answer` field's string begins, after its opening quote; nil before it has begun, or while the model
    /// thinks aloud.
    static func valueStart(in partial: String) -> String.Index? {
        var rest = Substring(partial)
        if let think = rest.range(of: "<think>") {
            guard let end = rest.range(of: "</think>", range: think.upperBound..<rest.endIndex) else { return nil }
            rest = rest[end.upperBound...]
        }
        guard let key = rest.range(of: "\"\(ConversationSchema.answerKey)\"") else { return nil }
        var i = key.upperBound
        for expected: Character in [":", "\""] {
            while i < rest.endIndex, rest[i].isWhitespace { i = rest.index(after: i) }
            guard i < rest.endIndex, rest[i] == expected else { return nil }
            i = rest.index(after: i)
        }
        return i
    }

    /// A JSON string's characters up to its closing quote or as far as it has come, its escapes decoded; an escape not
    /// complete yet ends it.
    static func decoded(_ string: Substring) -> String {
        var text = ""
        var pendingHigh: UInt32?
        var i = string.startIndex
        while i < string.endIndex, string[i] != "\"" {
            guard string[i] == "\\" else {
                text.append(string[i])
                i = string.index(after: i)
                continue
            }
            let escaped = string.index(after: i)
            guard escaped < string.endIndex else { break }
            guard string[escaped] == "u" else {
                text.append(simpleEscapes[string[escaped]] ?? string[escaped])
                i = string.index(after: escaped)
                continue
            }
            let digits = string.index(after: escaped)
            guard let end = string.index(digits, offsetBy: unicodeDigits, limitedBy: string.endIndex),
                  let code = UInt32(string[digits..<end], radix: 16) else { break }
            append(code, to: &text, pendingHigh: &pendingHigh)
            i = end
        }
        return text
    }

    /// Adds the character a `\uXXXX` escape writes, the high half of a surrogate pair waiting for its low half.
    private static func append(_ code: UInt32, to text: inout String, pendingHigh: inout UInt32?) {
        if highSurrogates.contains(code) {
            pendingHigh = code
        } else if let high = pendingHigh, lowSurrogates.contains(code) {
            let scalar = surrogateBase + ((high - highSurrogates.lowerBound) << surrogateShift) + (code - lowSurrogates.lowerBound)
            if let s = Unicode.Scalar(scalar) { text.unicodeScalars.append(s) }
            pendingHigh = nil
        } else if let s = Unicode.Scalar(code) {
            text.unicodeScalars.append(s)
        }
    }

    /// The escapes JSON writes a character with by a letter, and the character each stands for; any other escaped
    /// character stands for itself (RFC 8259, section 7).
    static let simpleEscapes: [Character: Character] = ["n": "\n", "t": "\t", "r": "\r", "b": "\u{8}", "f": "\u{c}"]

    /// JSON's `\uXXXX` escape: four hexadecimal digits, a character beyond them written as a UTF-16 surrogate pair
    /// (RFC 8259, section 7).
    static let unicodeDigits = 4
    static let highSurrogates: ClosedRange<UInt32> = 0xD800...0xDBFF
    static let lowSurrogates: ClosedRange<UInt32> = 0xDC00...0xDFFF
    static let surrogateBase: UInt32 = 0x10000
    static let surrogateShift: UInt32 = 10
}

/// The production `TaskQuestionAnswering`. The local model answers with the app's own prompt (`conversation-system.md`),
/// shown how many documents the set holds and those of them its context holds (`TaskContextBuilder`), the conversation so
/// far, today's date, the question and the language it is written in (`LanguageDetector`), in a fixed schema
/// (`ConversationSchema`) that `ConversationAnswerValidator` checks; an answer that
/// cannot be read goes back to the model with what was wrong, as a document's does. One model answers: the chat model
/// of the profile it is given, which must be installed. The task's effort (`conversation.efforts`) says how much it
/// thinks first, with the answer length and time that needs; an answer that takes longer is no answer, and one cut off
/// at its length is kept as far as it came, saying so. The answer is streamed as it is written. Every call is recorded
/// in the trace with what it was shown.
public struct TaskAnswerer: TaskQuestionAnswering {
    public let gate: InferenceGate
    public let models: ModelManager
    public let library: PromptTemplates

    public init(gate: InferenceGate, models: ModelManager, library: PromptTemplates) {
        self.gate = gate
        self.models = models
        self.library = library
    }

    public func answer(_ question: String, context: TaskContext, effort: TaskEffort, profile: ModelProfile, today: String,
                       config: PipelineConfig, trace: TraceContext,
                       progress: @escaping @Sendable (AnswerProgress) async -> Void) async throws -> TaskAnswer {
        let preset = try config.conversation.effort(effort)
        let model = profile.chatModel
        let system = try library.render("conversation-system", [:])
        let language = LanguageDetector(config: config.extraction).name(of: question)
        let library = library
        let numPredict = preset.numPredict
        // Fitted at `ollama.charsPerToken` first, then, while Ollama counts the prompt filling the context, at what it
        // counted (`PromptBudget.measured`), as often as `ollama.refitAttempts` allows; every call is traced.
        var charsPerToken = config.ollama.charsPerToken
        var refits: [Double] = []
        var earlier: [ModelCall] = []
        let started = Date()
        while true {
            let budget = PromptBudget(numCtx: config.conversation.numCtx, numPredict: preset.numPredict, charsPerToken: charsPerToken)
            var shown = context
            var trim = ContextTrim()
            var user = try userPrompt(question, context: shown, today: today, language: language)
            // What the answer is shown is cut, the least it needs first, until the prompt fits the model's context.
            while !budget.fits(system, user), let less = trim.less(of: shown) {
                shown = less
                user = try userPrompt(question, context: shown, today: today, language: language)
            }
            guard budget.fits(system, user) else {
                throw PromptError.tooLong(template: "conversation-user", chars: system.count + user.count, room: budget.room)
            }
            let validator = ConversationAnswerValidator(names: Dictionary(shown.documents.map { ($0.id, $0.name) },
                                                                          uniquingKeysWith: { first, _ in first }))
            let input = AnswerInput(effort: effort, model: model, think: preset.think, today: today, language: language, read: shown.read.count,
                                    listed: shown.listed.count, unlisted: shown.unlisted, exchanges: shown.conversation.count,
                                    trimmed: trim.isEmpty ? nil : trim, refitted: refits.isEmpty ? nil : refits)
            var fitted = config
            fitted.ollama.charsPerToken = charsPerToken
            let calls: [ModelCall]
            let outcome: Result<ModelAnswer<ValidatedAnswer>, ModelAnswerError>
            do {
                let answer = try await LLMClassifier(gate: gate, models: models, effort: .conversation(preset, config: fitted)).ask(
                    system: system, user: user, schema: ConversationSchema.answer, model: model,
                    repairPrompt: { try library.render("repair-user", ["errors": $0]) },
                    partial: { _, sofar in
                        let text = StreamedAnswer.text(in: sofar.message.content)
                        await progress(AnswerProgress(text: text, thinking: text.isEmpty && !(sofar.message.thinking ?? "").isEmpty))
                    },
                    cutOff: { content in
                        ValidatedAnswer(text: validator.named(StreamedAnswer.text(in: content)).trimmingCharacters(in: .whitespacesAndNewlines),
                                        sources: [], find: nil, notes: [], incomplete: AnswerValidationError.cutOff(numPredict).localizedDescription)
                    },
                    validate: { try validator.validate($0) })
                // A model that thought until it ran out wrote nothing of its answer, which is no answer.
                (calls, outcome) = answer.answer.text.isEmpty ? (answer.calls, .failure(.exhausted(answer.calls))) : (answer.calls, .success(answer))
            } catch let error as ModelAnswerError {
                (calls, outcome) = (error.calls, .failure(error))
            }
            let interrupted = if case let .failure(error) = outcome { error.cause != nil } else { false }
            if !interrupted, refits.count < config.ollama.refitAttempts, let measured = budget.measured(calls) {
                refits.append(measured)
                earlier += calls
                charsPerToken = measured
                continue
            }
            let full = budget.full(calls)
            let notes = [PromptBudget.refitted(refits), full].compactMap { $0 }
            let exchange = earlier + calls
            switch outcome {
            case let .success(answer):
                await trace.record(.answer, status: exchange.count > 1 || answer.answer.incomplete != nil || !notes.isEmpty ? .warn : .ok,
                                   startedAt: started, input: input,
                                   output: AnswerTrace(answer: answer.answer, promptTokens: PromptBudget.promptTokens(exchange), exchange: exchange),
                                   error: notes.isEmpty ? nil : notes.joined(separator: "; "))
                // An answer to a prompt that still filled the context may not have read all it was shown, which it says.
                return TaskAnswer(text: answer.answer.text, sources: answer.answer.sources, find: answer.answer.find, model: answer.model,
                                  problem: answer.answer.incomplete ?? (full == nil ? nil : PromptBudget.contextFullProblem))
            case let .failure(error):
                await trace.record(.answer, status: error.status, startedAt: started, input: input,
                                   output: AnswerTrace(answer: nil, promptTokens: PromptBudget.promptTokens(exchange), exchange: exchange),
                                   error: ([error.localizedDescription] + notes).joined(separator: "; "))
                if let cause = error.cause { throw cause }
                Log.warning(.classify, "The model gave no valid answer to a question", ["error": error.localizedDescription])
                throw error
            }
        }
    }

    /// What the model is asked: today's date, what it is shown of the set and the conversation, the question and, when it
    /// is sure of it, the language the question is written in, which the answer is written in.
    func userPrompt(_ question: String, context: TaskContext, today: String, language: String?) throws -> String {
        let written = try language.map { try library.render("conversation-language", ["language": $0]) + "\n\n" } ?? ""
        return try library.render("conversation-user", ["today": today, "documents": try documentsBlock(context),
                                                        "conversation": try conversationBlock(context.conversation), "question": question,
                                                        "language": written])
    }

    /// How many documents the set holds, then the documents shown with their text, each under its number, then those
    /// listed by name alone, then how many more there are; or that the set holds none.
    func documentsBlock(_ context: TaskContext) throws -> String {
        guard !context.documents.isEmpty else { return try library.render("conversation-empty", [:]) }
        var blocks = [try library.render("conversation-count", ["count": String(context.documents.count + context.unlisted)])]
        blocks += try context.read.map { document in
            try library.render("conversation-document", ["number": String(document.id), "name": document.name,
                                                         "about": Self.about(document), "text": document.text ?? ""])
        }
        if !context.listed.isEmpty {
            let lines = context.listed.map { "- [\($0.id)] \($0.name) · " + Self.about($0) }
            blocks.append(try library.render("conversation-listed", ["documents": lines.joined(separator: "\n")]))
        }
        if context.unlisted > 0 { blocks.append(try library.render("conversation-unlisted", ["count": String(context.unlisted)])) }
        return blocks.joined(separator: "\n\n")
    }

    /// The conversation so far, the first exchange first, followed by a blank line; empty when there is none.
    func conversationBlock(_ exchanges: [Exchange]) throws -> String {
        guard !exchanges.isEmpty else { return "" }
        let lines = try exchanges.map { try library.render("conversation-exchange", ["question": $0.question, "answer": $0.answer]) }
        return try library.render("conversation-history", ["exchanges": lines.joined(separator: "\n\n")]) + "\n\n"
    }

    /// A document's date and labels, of the kinds the model gives, as it is shown them, each label a JSON string
    /// (`ClassificationSchema.listed`): never the user's tags.
    static func about(_ document: ContextDocument) -> String {
        let labels = ClassificationSchema.answerOrder.compactMap { kind -> String? in
            let values = document.labels.values(kind)
            return values.isEmpty ? nil : "\(kind.rawValue): " + ClassificationSchema.listed(values)
        }
        return labels.isEmpty ? "-" : labels.joined(separator: "; ")
    }
}

/// What answering a question records it was answered with: the effort, the model, what the effort wanted the model told
/// about thinking, the day, the language the model was told the question is in, when it was, and how much it was shown:
/// documents with their text, listed by name, not shown, and earlier exchanges, and what was left out of that so the
/// prompt fit the model's context, when anything was, with the characters a token it was fitted at again each time
/// Ollama counted it filling the context (`PromptBudget.measured`). What was sent is each `ModelCall` of the exchange,
/// which retention clears.
struct AnswerInput: Encodable {
    var effort: TaskEffort
    var model: String
    var think: OllamaThink
    var today: String
    var language: String?
    var read: Int
    var listed: Int
    var unlisted: Int
    var exchanges: Int
    var trimmed: ContextTrim?
    var refitted: [Double]?
}

/// What answering a question records: the checked answer, the tokens each prompt took, and every model call under `TraceStep.exchangeKey`, which
/// retention clears.
struct AnswerTrace: Codable {
    var answer: ValidatedAnswer?
    /// The tokens each call's prompt took, as Ollama counted them (`PromptBudget.promptTokens`), which retention keeps.
    var promptTokens: [Int]
    var exchange: [ModelCall]
}
