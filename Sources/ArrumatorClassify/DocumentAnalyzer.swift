import ArrumatorCore
import Foundation

/// The production `DocumentAnalyzing`. The chat model of the profile in use reads the document once, with the app's own
/// prompt (`labels-system.md`) and what the archive's labels and the user's decisions about them say
/// (`archive-labels.md`), picks out its signals, which become its labels and all it is described by, and names its file;
/// an invalid answer goes back to it `analysis.repairAttempts` times. Its embedding model makes the vector the document
/// is found by meaning with. Every model call is recorded in the trace.
public struct DocumentAnalyzer: DocumentAnalyzing {
    public let gate: InferenceGate
    public let models: ModelManager
    public let prompts: PromptBuilder

    public init(gate: InferenceGate, models: ModelManager, prompts: PromptBuilder) {
        self.gate = gate
        self.models = models
        self.prompts = prompts
    }

    public func analyse(_ content: ExtractedContent, guidance: LabelGuidance, settings: AppSettings, config: PipelineConfig,
                        trace: TraceContext) async throws -> AnalysisOutcome {
        let model = try settings.modelProfile().chatModel
        let validator = AnswerValidator(labels: config.labels)
        let input = ["model": model]
        let started = Date()
        var answer: ModelAnswer<ValidatedAnalysis>?
        do {
            answer = try await LLMClassifier(gate: gate, models: models, effort: .documents(config)).ask(
                system: try prompts.analysisSystem(), user: try prompts.analysisUser(content: content, guidance: guidance),
                schema: ClassificationSchema.analysis(maxPerKind: config.labels.maxPerKind), model: model,
                repairPrompt: { try prompts.repair(errors: $0) }, validate: { try validator.validate($0) })
            await trace.record(.analyse, status: (answer?.calls.count ?? 0) > 1 ? .warn : .ok, startedAt: started, input: input,
                               output: AnalysisTrace(answer: answer?.answer, exchange: answer?.calls ?? []))
        } catch let error as ModelAnswerError {
            await trace.record(.analyse, status: .error, startedAt: started, input: input,
                               output: AnalysisTrace(answer: nil, exchange: error.calls), error: error.localizedDescription)
            Log.warning(.classify, "The model gave no valid answer", ["error": error.localizedDescription])
        }

        let labels = answer?.answer.labels
        let embedding = try await embedding(for: content, senders: labels?.values(.sender) ?? [], settings: settings, config: config,
                                            trace: trace)
        var problems: [String] = []
        if answer == nil { problems.append(DocumentAnalysis.Problem.noAnswer) }
        if content.hasWarning(.encrypted) { problems.append(DocumentAnalysis.Problem.encrypted) }
        if content.hasWarning(.corrupted) { problems.append(DocumentAnalysis.Problem.corrupted) }
        if content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && content.visual == nil {
            problems.append(DocumentAnalysis.Problem.noText)
        }
        // A document that waits for the user keeps its own name: what the model read of it is in doubt.
        let analysis = DocumentAnalysis(fileName: problems.isEmpty ? answer?.answer.fileName : nil, model: answer?.model, problems: problems)
        return AnalysisOutcome(analysis: analysis, labels: labels, embedding: embedding?.vector, embeddingModel: embedding?.model)
    }

    public func embedding(for content: ExtractedContent, senders: [String], settings: AppSettings, config: PipelineConfig,
                          trace: TraceContext) async throws -> (vector: [Float], model: String)? {
        let embedder = OllamaEmbedder(gate: gate, model: try settings.modelProfile().embedModel, keepAlive: config.ollama.keepAlive.embed,
                                      numCtx: config.analysis.embeddingNumCtx)
        let summary = content.embeddingSummary(senders: senders, maxChars: config.analysis.embeddingSummaryChars,
                                               identifiersLimit: config.analysis.embeddingIdentifiersLimit)
        let started = Date()
        do {
            guard let vector = try await embedder.embed([summary]).first else { return nil }
            await trace.record(.embed, startedAt: started, input: ["model": embedder.modelId, "chars": String(summary.count)],
                               output: ["dimension": String(vector.count)])
            return (vector, embedder.modelId)
        } catch let error as OllamaError where error.isTransient {
            throw error
        } catch {
            await trace.record(.embed, status: .warn, startedAt: started, input: ["model": embedder.modelId],
                               error: error.localizedDescription)
            Log.warning(.classify, "Embedding unavailable; the document is found by its words only", ["error": error.localizedDescription])
            return nil
        }
    }
}

/// What the analysis step records: the validated answer, and every model call under `TraceStep.exchangeKey`, which
/// retention clears.
struct AnalysisTrace: Codable {
    var answer: ValidatedAnalysis?
    var exchange: [ModelCall]
}
