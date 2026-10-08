import ArrumatorCore
import Foundation

/// The JSON schema two labels that look alike are judged in: why, in a sentence, then whether they are one. The reason
/// comes first, so the answer follows from it. Only string types are used, which every grammar backend supports.
enum LabelPairSchema {
    static let reasonKey = "reason"
    static let answerKey = "answer"

    static var judgement: JSONValue {
        ClassificationSchema.object([
            JSONEntry(reasonKey, ClassificationSchema.string()),
            JSONEntry(answerKey, ClassificationSchema.string(LabelJudgement.allCases.map(\.rawValue))),
        ])
    }
}

/// The model's judgement of two labels that look alike, checked: one of `LabelJudgement`, and the reason it gave.
struct JudgedPair: Sendable, Codable, Hashable {
    var judgement: LabelJudgement
    var reason: String
}

/// Checks an answer to a pair of labels by its structure: JSON with an answer the schema names, and a reason that is not
/// blank. A reason is not checked for what it says, only that one is given, as the answer is to follow from it.
enum LabelPairValidator {
    private struct Raw: Decodable {
        var reason: String
        var answer: String
    }

    static func validate(_ text: String) throws -> JudgedPair {
        let raw: Raw
        do { raw = try JSON.decoder.decode(Raw.self, from: Data(text.utf8)) } catch {
            throw AnswerValidationError.notJSON(error.localizedDescription)
        }
        var problems: [String] = []
        let judgement = LabelJudgement(rawValue: raw.answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if judgement == nil {
            problems.append("\"answer\" is “\(raw.answer)”; it must be " + LabelJudgement.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or "))
        }
        let reason = DocumentLabel.oneLine(raw.reason)
        if reason.isEmpty { problems.append("\"reason\" is blank; say in one sentence what makes them one or tells them apart") }
        guard let judgement, problems.isEmpty else { throw AnswerValidationError.invalid(problems) }
        return JudgedPair(judgement: judgement, reason: reason)
    }
}

/// The production `LabelPairJudging`: the chat model of the profile in use is shown two labels of one kind that look
/// alike, how many documents have each and the names of some of them, and judges, with the app's own prompt
/// (`alike-system.md`), whether they are one label written two ways or two, saying why first. It is asked as documents
/// are read (`LLMClassifier.Effort.documents`), and an invalid answer goes back to it `analysis.repairAttempts` times.
/// Telling two names apart that differ by a letter is a judgement of meaning that writing alone cannot make: the record
/// linkage literature leaves such pairs to a review, which the model gives in the person's place, told that a wrong
/// "same" costs more than a wrong "different" (docs/organizing-principles-sources.md#sources-for-keeping-labels-one-vocabulary).
/// Every call is recorded in the trace (`judge`).
public struct LabelPairJudge: LabelPairJudging {
    public let gate: InferenceGate
    public let models: ModelManager
    public let library: PromptTemplates

    public init(gate: InferenceGate, models: ModelManager, library: PromptTemplates) {
        self.gate = gate
        self.models = models
        self.library = library
    }

    public func judge(_ pair: LabelSuggestion, use: LabelPairUse, profile: ModelProfile, config: PipelineConfig,
                      trace: TraceContext) async throws -> LabelVerdict {
        let model = profile.chatModel
        let input = JudgeInput(model: model, pair: pair, use: use)
        let started = Date()
        do {
            let answer = try await LLMClassifier(gate: gate, models: models, effort: .documents(config)).ask(
                system: try library.render("alike-system", [:]), user: try userPrompt(pair, use: use),
                schema: LabelPairSchema.judgement, model: model,
                repairPrompt: { try library.render("repair-user", ["errors": $0]) }, validate: LabelPairValidator.validate)
            await trace.record(.judge, status: answer.calls.count > 1 ? .warn : .ok, startedAt: started, input: input,
                               output: JudgeTrace(answer: answer.answer, exchange: answer.calls))
            return LabelVerdict(judgement: answer.answer.judgement, reason: answer.answer.reason, model: answer.model, problem: nil)
        } catch let error as ModelAnswerError {
            await trace.record(.judge, status: error.status, startedAt: started, input: input,
                               output: JudgeTrace(answer: nil, exchange: error.calls), error: error.localizedDescription)
            if let cause = error.cause { throw cause }
            Log.warning(.classify, "The model gave no valid answer about two labels that look alike", ["error": error.localizedDescription])
            return LabelVerdict(judgement: nil, reason: nil, model: nil, problem: "the model gave no valid answer (\(error.localizedDescription))")
        }
    }

    /// What the model is asked: the kind, then each label as a JSON string with how many documents have it and the names
    /// of the newest it is shown, each a JSON string too, so a label or a name holding a comma reads as one.
    func userPrompt(_ pair: LabelSuggestion, use: LabelPairUse) throws -> String {
        let documents = { (names: [String]) in
            try names.isEmpty ? "" : library.render("alike-documents", ["documents": ClassificationSchema.listed(names)])
                .trimmingCharacters(in: .newlines)
        }
        return try library.render("alike-user", [
            "kind": pair.kind.rawValue,
            "first": ClassificationSchema.listed([pair.value]), "first_count": Format.count(use.valueDocuments, "document"),
            "first_documents": try documents(use.valueNames),
            "second": ClassificationSchema.listed([pair.into]), "second_count": Format.count(use.intoDocuments, "document"),
            "second_documents": try documents(use.intoNames),
        ])
    }
}

/// What judging two labels records it was asked: the model, the pair and the names of documents it was shown.
struct JudgeInput: Encodable {
    var model: String
    var pair: LabelSuggestion
    var use: LabelPairUse
}

/// What judging two labels records: the checked answer, and every model call under `TraceStep.exchangeKey`, which
/// retention clears.
struct JudgeTrace: Codable {
    var answer: JudgedPair?
    var exchange: [ModelCall]
}
