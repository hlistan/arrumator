import ArrumatorCore
import Foundation

/// The JSON schema a search request is answered in: one list of labels per kind the model gives, as a document's
/// answer has them and in the same order, each label with the words of the request that ask for it; then the words the
/// text must contain, the arrangement by those kinds and a name. A task never asks for a tag, the user's own: the user
/// adds tagged documents to its set and arranges it by them. Only string, array and object types are used, which every
/// grammar backend supports.
public enum SearchSchema {
    static let valueKey = "value"
    static let askedAsKey = "asked_as"
    static let wordsKey = "words"
    static let groupingKey = "group_by"
    static let titleKey = "title"

    public static func plan(_ tasks: TasksConfig) -> JSONValue {
        let types = DocumentType.allCases.filter { $0 != .other }.map(\.rawValue)
        return ClassificationSchema.object(ClassificationSchema.answerOrder.map { kind in
            JSONEntry(ClassificationSchema.labelsKey(kind), .orderedObject([
                JSONEntry("type", "array"),
                JSONEntry("items", ClassificationSchema.object([
                    JSONEntry(valueKey, ClassificationSchema.string(kind == .type ? types : nil)),
                    JSONEntry(askedAsKey, ClassificationSchema.string()),
                ])),
                JSONEntry("maxItems", .number(Double(tasks.maxValuesPerKind))),
            ]))
        } + [
            JSONEntry(wordsKey, ClassificationSchema.stringArray(maxItems: tasks.maxWords)),
            JSONEntry(groupingKey, ClassificationSchema.stringArray(maxItems: tasks.maxGroupingDepth,
                                                                     enumValues: LabelKind.modelKinds.map(\.rawValue))),
            JSONEntry(titleKey, ClassificationSchema.string()),
        ])
    }
}

/// Raw answer to a search request: a list per kind the schema asks for, and nothing else of labels.
struct SearchAnswer: Decodable {
    /// A label asked for, and the words of the request the model says ask for it.
    struct Criterion: Decodable {
        var value: String
        var askedAs: String

        enum CodingKeys: String, CodingKey {
            case value
            case askedAs = "asked_as"
        }
    }

    var labels: [LabelKind: [Criterion]]
    var words: [String]
    var grouping: [String]
    var title: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnalysisAnswer.Key.self)
        var labels: [LabelKind: [Criterion]] = [:]
        for kind in ClassificationSchema.answerOrder {
            labels[kind] = try container.decode([Criterion].self, forKey: AnalysisAnswer.Key(stringValue: ClassificationSchema.labelsKey(kind)))
        }
        self.labels = labels
        words = try container.decode([String].self, forKey: AnalysisAnswer.Key(stringValue: SearchSchema.wordsKey))
        grouping = try container.decode([String].self, forKey: AnalysisAnswer.Key(stringValue: SearchSchema.groupingKey))
        title = try container.decode(String.self, forKey: AnalysisAnswer.Key(stringValue: SearchSchema.titleKey))
    }
}

/// A plan the model gave, checked, and notes on what was changed or dropped.
public struct ValidatedSearchPlan: Sendable, Codable, Hashable {
    public var plan: SearchPlan
    public var notes: [String]
}

/// Parses and checks the answer to a search request against the request itself.
///
/// Every kind a plan gives leaves documents out, so a label nobody asked for, such as the country every document of the
/// archive is from, silently hides what was wanted. A label is therefore kept only when every word the model quotes for
/// it (`asked_as`) is a word of the request, whatever its case, accents or punctuation: the model must ground each label
/// in the request, and the app checks the quote, as generated claims are checked against the sources they cite (Gao et
/// al., ALCE, EMNLP 2023; docs/organizing-principles-sources.md#sources-for-search-tasks). A quote may leave words out
/// or run them together ("agosto de 2026" from "agosto e setembro de 2026"), but never add one. Words ask for one thing:
/// a label whose quote has only words a label of an earlier kind (`ClassificationSchema.answerOrder`) already quotes is
/// dropped, so "faturas de Portugal" asks for documents under Portuguese law and not also for documents written in
/// Portuguese. A word is kept only when
/// it is a word of the request and no label's quote already has it.
///
/// A label is kept as a document's label of its kind is (`DocumentLabel.normalized`), except that a date or deadline may
/// be a year, a month or a span, as a period is; one with nothing to match by is dropped, and so is any beyond
/// `tasks.maxValuesPerKind` of a kind. Words are kept once each, up to `tasks.maxWords`; the arrangement names each kind
/// once, up to `tasks.maxGroupingDepth`. What is dropped is noted for the trace. A list missing from the answer, a kind
/// the arrangement does not know, or a plan left asking for nothing at all goes back to the model, with the reasons.
public struct SearchPlanValidator: Sendable {
    public let tasks: TasksConfig
    public let labels: LabelsConfig

    public init(tasks: TasksConfig, labels: LabelsConfig) {
        self.tasks = tasks
        self.labels = labels
    }

    public func validate(_ text: String, request: String) throws -> ValidatedSearchPlan {
        let raw: SearchAnswer
        do {
            raw = try JSONDecoder().decode(SearchAnswer.self, from: Data(ModelOutput.jsonObject(text).utf8))
        } catch let DecodingError.keyNotFound(key, _) {
            throw AnswerValidationError.invalid(["\(key.stringValue) is missing; give [] when the request does not limit it"])
        } catch {
            throw AnswerValidationError.notJSON(String(describing: error))
        }
        let asked = Self.words(request)
        var notes: [String] = []
        var quoted = Set<String>()
        let criteria = ClassificationSchema.answerOrder.flatMap { labels(of: $0, in: raw, asked: asked, quoted: &quoted, notes: &notes) }
        let words = distinct(raw.words.map(DocumentLabel.oneLine).filter { word in
            let key = Self.words(word)
            guard !key.isEmpty else { return false }
            guard key.isSubset(of: asked) else {
                notes.append("\(SearchSchema.wordsKey): “\(word)” is not in the request, dropped")
                return false
            }
            guard !key.isSubset(of: quoted) else {
                notes.append("\(SearchSchema.wordsKey): “\(word)” is asked for by a label already, dropped")
                return false
            }
            return true
        }, limit: tasks.maxWords, what: SearchSchema.wordsKey, notes: &notes)
        var grouping: [LabelKind] = []
        for written in raw.grouping {
            guard let kind = LabelKind(rawValue: written.trimmingCharacters(in: .whitespaces)), !kind.isUsersOwn else {
                throw AnswerValidationError.invalid(["\(SearchSchema.groupingKey): “\(written)” is no kind of label"])
            }
            if !grouping.contains(kind) { grouping.append(kind) }
        }
        if grouping.count > tasks.maxGroupingDepth {
            notes.append("\(SearchSchema.groupingKey): more than \(tasks.maxGroupingDepth), the rest dropped")
            grouping = Array(grouping.prefix(tasks.maxGroupingDepth))
        }
        let plan = SearchPlan(title: DocumentLabel.shortened(DocumentLabel.oneLine(raw.title), to: tasks.maxTitleChars), labels: criteria,
                              words: words, grouping: grouping)
        guard !plan.isEmpty else {
            throw AnswerValidationError.invalid(notes + ["nothing to search by: give the labels the request asks for, each with "
                + "\(SearchSchema.askedAsKey) copied from the request"])
        }
        return ValidatedSearchPlan(plan: plan, notes: notes)
    }

    private func labels(of kind: LabelKind, in raw: SearchAnswer, asked: Set<String>, quoted: inout Set<String>,
                        notes: inout [String]) -> [DocumentLabel] {
        let key = ClassificationSchema.labelsKey(kind)
        // What labels of the kinds before this one quote: words that already ask for something.
        let earlier = quoted
        let kept = (raw.labels[kind] ?? []).filter { !DocumentLabel.oneLine($0.value).isEmpty }.compactMap { criterion -> String? in
            // A date or deadline asked for may be any span of time, as a period is.
            let normalized = DocumentLabel.normalized(criterion.value, kind: SearchPlan.timeKinds.contains(kind) ? .period : kind)?.value
            guard let value = normalized, !LabelUsage.searchKey(value).isEmpty else {
                notes.append("\(key): “\(DocumentLabel.oneLine(criterion.value))” is no \(kind.rawValue), dropped")
                return nil
            }
            let quote = Self.words(criterion.askedAs)
            guard !quote.isEmpty, quote.isSubset(of: asked) else {
                notes.append("\(key): “\(value)” is not asked for by the request (“\(DocumentLabel.oneLine(criterion.askedAs))”), dropped")
                return nil
            }
            guard !quote.isSubset(of: earlier) else {
                notes.append("\(key): “\(value)” is asked for by words a label of another kind quotes "
                    + "(“\(DocumentLabel.oneLine(criterion.askedAs))”), dropped")
                return nil
            }
            quoted.formUnion(quote)
            return DocumentLabel.shortened(value, to: labels.maxValueChars)
        }
        return distinct(kept, limit: tasks.maxValuesPerKind, what: key, notes: &notes).map { DocumentLabel(kind: kind, value: $0) }
    }

    /// The words of a text, folded as labels are matched (`LabelUsage.searchKey`).
    static func words(_ text: String) -> Set<String> {
        Set(LabelUsage.searchKey(text).split(separator: " ").map(String.init))
    }

    /// Each value once, however it is cased or accented, the first `limit` of them.
    private func distinct(_ values: [String], limit: Int, what: String, notes: inout [String]) -> [String] {
        var seen = Set<String>()
        let unique = values.filter { seen.insert(AnswerValidator.folded($0)).inserted }
        if unique.count > limit { notes.append("\(what): more than \(limit), the rest dropped") }
        return Array(unique.prefix(limit))
    }
}

/// The production `SearchPromptInterpreting`. The local model reads the request with the app's own prompt
/// (`search-system.md`), told the archive's labels in use (`search-archive.md`) and today's date, and answers in a fixed
/// schema (`SearchSchema`), which `SearchPlanValidator` checks; an invalid answer goes back to the model with what was
/// wrong, as a document's does. One model reads it: the chat model of the profile it is given, the task's own or the one
/// Settings uses, which must be installed, with the context documents are read with. The task's effort
/// (`tasks.efforts`) says how much that model thinks before it answers, with the answer length and time thinking needs,
/// how often an answer goes back and how much vocabulary it is shown; an answer that takes longer than that time is no
/// answer, and is not asked for again (`LLMClassifier.ask`). Every call is recorded in the trace, with what the effort
/// wanted the model told about thinking and what it was sent.
public struct SearchPromptInterpreter: SearchPromptInterpreting {
    public let gate: InferenceGate
    public let models: ModelManager
    public let library: PromptTemplates

    public init(gate: InferenceGate, models: ModelManager, library: PromptTemplates) {
        self.gate = gate
        self.models = models
        self.library = library
    }

    public func interpret(_ prompt: String, effort: TaskEffort, profile: ModelProfile, vocabulary: [LabelKind: [LabelUsage]], today: String,
                          config: PipelineConfig, trace: TraceContext) async throws -> SearchInterpretation {
        let preset = try config.tasks.preset(effort)
        // A chat model Ollama does not have fails the task with that reason (`LLMClassifier`), rather than another model
        // reading it in its place unasked.
        let model = profile.chatModel
        let validator = SearchPlanValidator(tasks: config.tasks, labels: config.labels)
        let system = try library.render("search-system", [
            "max_per_kind": String(config.tasks.maxValuesPerKind), "max_words": String(config.tasks.maxWords),
            "max_depth": String(config.tasks.maxGroupingDepth), "max_title_chars": String(config.tasks.maxTitleChars)])
        // The archive's labels are shown fewer, the least used first, until the prompt fits the model's context.
        let budget = PromptBudget(numCtx: config.analysis.numCtx, numPredict: preset.numPredict, charsPerToken: config.ollama.charsPerToken)
        var limits = preset.promptLabels
        var leftOut = 0
        var user = try userPrompt(prompt, vocabulary: vocabulary, limits: limits, today: today)
        while !budget.fits(system, user), let kind = Self.mostShown(vocabulary, limits: limits) {
            limits[kind] = min(limits[kind] ?? 0, vocabulary[kind]?.count ?? 0) - 1
            leftOut += 1
            user = try userPrompt(prompt, vocabulary: vocabulary, limits: limits, today: today)
        }
        guard budget.fits(system, user) else {
            throw PromptError.tooLong(template: "search-user", chars: system.count + user.count, room: budget.room)
        }
        let library = library
        let input = InterpretInput(effort: effort, model: model, think: preset.think, today: today, labelsLeftOut: leftOut == 0 ? nil : leftOut)
        let started = Date()
        do {
            let answer = try await LLMClassifier(gate: gate, models: models, effort: .task(preset, config: config)).ask(
                system: system, user: user, schema: SearchSchema.plan(config.tasks), model: model,
                repairPrompt: { try library.render("repair-user", ["errors": $0]) }, validate: { try validator.validate($0, request: prompt) })
            let full = budget.full(answer.calls)
            await trace.record(.interpret, status: answer.calls.count > 1 || full != nil ? .warn : .ok, startedAt: started, input: input,
                               output: InterpretTrace(answer: answer.answer, promptTokens: PromptBudget.promptTokens(answer.calls),
                                                      exchange: answer.calls), error: full)
            return SearchInterpretation(plan: answer.answer.plan, model: answer.model, problem: nil)
        } catch let error as ModelAnswerError {
            await trace.record(.interpret, status: error.status, startedAt: started, input: input,
                               output: InterpretTrace(answer: nil, promptTokens: PromptBudget.promptTokens(error.calls), exchange: error.calls),
                               error: ([error.localizedDescription] + [budget.full(error.calls)].compactMap { $0 }).joined(separator: "; "))
            if let cause = error.cause { throw cause }
            Log.warning(.classify, "The model gave no valid answer to a search request", ["error": error.localizedDescription])
            return SearchInterpretation(plan: nil, model: nil, problem: "the model gave no valid answer (\(error.localizedDescription))")
        }
    }

    /// What the model is asked: the archive's labels as `limits` shows them, today's date and the request.
    func userPrompt(_ prompt: String, vocabulary: [LabelKind: [LabelUsage]], limits: [LabelKind: Int], today: String) throws -> String {
        try library.render("search-user", ["archive": try archiveBlock(vocabulary, limits: limits), "today": today, "request": prompt])
    }

    /// The kind of which `limits` shows the most labels, the one to show one fewer of; nil when none is shown.
    static func mostShown(_ vocabulary: [LabelKind: [LabelUsage]], limits: [LabelKind: Int]) -> LabelKind? {
        let shown = ClassificationSchema.answerOrder.map { ($0, min(limits[$0] ?? 0, vocabulary[$0]?.count ?? 0)) }.filter { $0.1 > 0 }
        return shown.max { $0.1 < $1.1 }?.0
    }

    /// The labels the archive uses of each kind `limits` names, the most used first, by the answer's name for their
    /// kind, one kind per line; empty for an archive without any. A kind `limits` does not name is shown none.
    func archiveBlock(_ vocabulary: [LabelKind: [LabelUsage]], limits: [LabelKind: Int]) throws -> String {
        let used = ClassificationSchema.answerOrder.compactMap { kind -> String? in
            guard let limit = limits[kind] else { return nil }
            let values = (vocabulary[kind] ?? []).prefix(limit).map(\.label.value)
            return values.isEmpty ? nil : "- \(ClassificationSchema.labelsKey(kind)): " + values.joined(separator: "; ")
        }
        guard !used.isEmpty else { return "" }
        return try library.render("search-archive", ["used": used.joined(separator: "\n")]) + "\n\n"
    }
}

/// What reading a search request records it was read with: the effort, the model, what the effort wanted the model told
/// about thinking, the day, and how many of the archive's labels the effort would show were left out so the prompt fit
/// the model's context, when any were. What was sent, as the model allows, is each `ModelCall.think` of the exchange, which
/// retention clears; this stays, so the trace still says how much the model was asked to think once the exchange is gone.
struct InterpretInput: Encodable {
    var effort: TaskEffort
    var model: String
    var think: OllamaThink
    var today: String
    var labelsLeftOut: Int?
}

/// What reading a search request records: the validated plan, and every model call under `TraceStep.exchangeKey`, which
/// retention clears.
struct InterpretTrace: Codable {
    var answer: ValidatedSearchPlan?
    /// The tokens each call's prompt took, as Ollama counted them (`PromptBudget.promptTokens`), which retention keeps.
    var promptTokens: [Int]
    var exchange: [ModelCall]
}
