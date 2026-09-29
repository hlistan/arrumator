import ArrumatorCore
import Foundation

/// A document's labels as the model gave them, cleaned, with notes on what was dropped or changed.
public struct ValidatedLabels: Sendable, Codable, Hashable {
    public var labels: [DocumentLabel]
    public var notes: [String]
}

/// Checks the model's answer naming a document's signals. Each value is tidied to one line and cut to length, repeats
/// are dropped, each kind keeps its most significant first, and a language becomes its ISO 639-1 code. A language that
/// is none is dropped rather than repaired, as is anything past `maxPerKind`; a list missing from the answer goes back
/// to the model.
public struct LabelValidator: Sendable {
    public let config: LabelsConfig

    public init(config: LabelsConfig) { self.config = config }

    public func validate(_ text: String) throws -> ValidatedLabels {
        let answer: [String: [String]]
        do { answer = try JSONDecoder().decode([String: [String]].self, from: Data(AnswerValidator.stripThinking(text).utf8)) } catch {
            throw AnswerValidationError.notJSON(String(describing: error))
        }
        var problems: [String] = []
        var notes: [String] = []
        var labels: [DocumentLabel] = []
        for kind in LabelKind.allCases {
            let key = ClassificationSchema.labelsKey(kind)
            guard let values = answer[key] else {
                problems.append("\(key) is missing; give [] when the document shows none")
                continue
            }
            var seen = Set<String>()
            for written in values {
                var value = Self.oneLine(written)
                guard !value.isEmpty else { continue }
                if kind == .language {
                    guard let code = DocumentLabel.languageCode(value) else {
                        notes.append("\(key): “\(value)” is not an ISO 639 language, dropped")
                        continue
                    }
                    value = code
                }
                value = shortened(value)
                guard seen.insert(AnswerValidator.folded(value)).inserted else { continue }
                guard seen.count <= config.maxPerKind else {
                    notes.append("\(key): more than \(config.maxPerKind), the rest dropped")
                    break
                }
                labels.append(DocumentLabel(kind: kind, value: value))
            }
        }
        guard problems.isEmpty else { throw AnswerValidationError.invalid(problems) }
        return ValidatedLabels(labels: labels, notes: notes)
    }

    /// Runs of white space, line breaks and control characters become one space.
    static func oneLine(_ text: String) -> String {
        text.unicodeScalars.split { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
    }

    /// At most `maxValueChars` characters, cut after the last whole word that fits when there is one.
    func shortened(_ value: String) -> String {
        guard value.count > config.maxValueChars else { return value }
        // One character more, so a word ending exactly at the limit is seen to be whole.
        let cut = value.prefix(config.maxValueChars + 1)
        guard let space = cut.lastIndex(of: " ") else { return String(value.prefix(config.maxValueChars)) }
        return String(cut[..<space])
    }
}

/// The production `DocumentLabeler`: the local model reads the document with a prompt of its own (`labels-system.md`)
/// and names its signals, which become its labels. The model is asked as when it names a file, the fast model first;
/// every call is recorded in the trace.
public struct LabelExtractor: DocumentLabeler {
    public let gate: InferenceGate
    public let models: ModelManager
    public let prompts: PromptBuilder

    public init(gate: InferenceGate, models: ModelManager, prompts: PromptBuilder) {
        self.gate = gate
        self.models = models
        self.prompts = prompts
    }

    public func labels(for content: ExtractedContent, settings: AppSettings, config: PipelineConfig,
                       trace: TraceContext) async throws -> [DocumentLabel]? {
        let resolved = try config.models(for: settings.models)
        let tiers = LLMClassifier.Tier.distinct([
            LLMClassifier.Tier(model: resolved.fast, numCtx: resolved.fastNumCtx, keepAlive: resolved.keepAliveChat),
            LLMClassifier.Tier(model: resolved.chat, numCtx: resolved.numCtx, keepAlive: resolved.keepAliveChat)])
        let system = try prompts.labelsSystem(maxPerKind: config.labels.maxPerKind)
        let user = try prompts.labelsUser(content: content)
        let validator = LabelValidator(config: config.labels)
        let prompts = prompts
        let input = ["tiers": tiers.map(\.model).joined(separator: ",")]
        let started = Date()
        do {
            let answer = try await LLMClassifier(gate: gate, models: models, config: config.classification).ask(
                system: system, user: user, schema: ClassificationSchema.labels(maxPerKind: config.labels.maxPerKind), tiers: tiers,
                repairPrompt: { try prompts.repair(errors: $0) }, validate: { try validator.validate($0) })
            await trace.record(.label, status: answer.calls.count > 1 ? .warn : .ok, startedAt: started, input: input,
                               output: LabelTrace(labels: answer.answer.labels, notes: answer.answer.notes, calls: answer.calls))
            return answer.answer.labels
        } catch let error as ModelAnswerError {
            if case let .exhausted(calls) = error {
                await trace.record(.label, status: .error, startedAt: started, input: input,
                                   output: LabelTrace(labels: [], notes: [], calls: calls), error: error.localizedDescription)
            }
            Log.warning(.classify, "The model gave no labels", ["error": error.localizedDescription])
            return nil
        }
    }
}

/// What the labelling step records: the labels, what validation changed, and every model call.
struct LabelTrace: Codable {
    var labels: [DocumentLabel]
    var notes: [String]
    var calls: [ModelCall]
}
