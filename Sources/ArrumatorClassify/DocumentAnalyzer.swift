import ArrumatorCore
import Foundation

/// The production `DocumentAnalyzing`. The senders the app knows are recognised in the document first, by identifiers,
/// domains and names; then the local model reads it once, with the app's own prompt (`labels-system.md`), and says
/// what it is, picks out its signals, which become its labels, and names its file. Every model call is recorded in
/// the trace.
public struct DocumentAnalyzer: DocumentAnalyzing {
    public let senders: SenderStore
    public let gate: InferenceGate
    public let models: ModelManager
    public let prompts: PromptBuilder

    public init(senders: SenderStore, gate: InferenceGate, models: ModelManager, prompts: PromptBuilder) {
        self.senders = senders
        self.gate = gate
        self.models = models
        self.prompts = prompts
    }

    public func analyse(_ content: ExtractedContent, settings: AppSettings, config: PipelineConfig,
                        trace: TraceContext) async throws -> AnalysisOutcome {
        let resolved = try config.models(for: settings.models)

        // 1. Senders the app knows, recognised in the document. An identifier on several senders' documents (the
        //    user's own tax number, printed on every bill) identifies none of them.
        let ambiguous = Set(try await senders.identifiersBySender().values.flatMap(\.keys)
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }.filter { $0.value > 1 }.keys)
        let resolver = CorrespondentResolver(correspondents: try await senders.correspondents(), config: config.analysis,
                                             entities: config.entities, ambiguousKeys: ambiguous)
        let matches = await trace.measure(.correspondent, output: { (m: [CorrespondentMatch]) in
            m.prefix(5).map { ["name": $0.correspondent.canonicalName, "by": $0.matchedBy.rawValue, "evidence": $0.evidence,
                               "strength": String(format: "%.2f", $0.strength)] }
        }) { resolver.resolve(content) }

        // 2. The model reads the document.
        let tiers = LLMClassifier.Tier.distinct([
            LLMClassifier.Tier(model: resolved.chat, numCtx: resolved.numCtx, keepAlive: resolved.keepAliveChat),
            LLMClassifier.Tier(model: resolved.fast, numCtx: resolved.fastNumCtx, keepAlive: resolved.keepAliveChat)])
        let validator = AnswerValidator(config: config.analysis, labels: config.labels, entities: config.entities)
        let prompts = prompts
        let input = ["tiers": tiers.map(\.model).joined(separator: ",")]
        let started = Date()
        var answer: ModelAnswer<ValidatedAnalysis>?
        do {
            answer = try await LLMClassifier(gate: gate, models: models, config: config.analysis).ask(
                system: try prompts.analysisSystem(), user: try prompts.analysisUser(content: content, correspondents: matches),
                schema: ClassificationSchema.analysis(maxPerKind: config.labels.maxPerKind), tiers: tiers,
                repairPrompt: { try prompts.repair(errors: $0) }, validate: { try validator.validate($0) })
            await trace.record(.analyse, status: (answer?.calls.count ?? 0) > 1 ? .warn : .ok, startedAt: started, input: input,
                               output: AnalysisTrace(answer: answer?.answer, calls: answer?.calls ?? []))
        } catch let error as ModelAnswerError {
            if case let .exhausted(calls) = error {
                await trace.record(.analyse, status: .error, startedAt: started, input: input,
                                   output: AnalysisTrace(answer: nil, calls: calls), error: error.localizedDescription)
            }
            Log.warning(.classify, "The model gave no valid answer", ["error": error.localizedDescription])
        }

        // 3. The document as read, with the sender the app knows it by.
        let reading = answer?.answer.correspondent ?? ""
        let sender = Self.sender(reading: reading, resolver: resolver, matches: matches)
        let embedding = try await embedding(for: content, sender: sender?.canonicalName ?? answer?.answer.correspondent,
                                            settings: settings, config: config, trace: trace)
        let (date, dateSource) = Self.documentDate(answer?.answer.documentDate, content: content)
        let labels = answer?.answer.labels
        var problems: [String] = []
        if answer == nil { problems.append("the model gave no valid answer") }
        if content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && content.visual == nil {
            problems.append("no text could be read")
        }
        if content.hasWarning(.encrypted) { problems.append("encrypted") }
        if content.hasWarning(.corrupted) { problems.append("corrupted") }
        let analysis = DocumentAnalysis(
            correspondent: sender?.canonicalName ?? answer?.answer.correspondent, correspondentID: sender?.id,
            documentType: answer?.answer.documentType ?? .other, documentDate: date, dateSource: dateSource,
            periodYear: answer?.answer.periodYear, title: answer?.answer.title ?? content.source.stem,
            // A document that waits for the user keeps its own name: what the model read of it is in doubt.
            fileName: problems.isEmpty ? answer?.answer.fileName : nil,
            language: labels?.first { $0.kind == .language }?.value ?? content.language.primary,
            model: answer?.model, problems: problems)
        return AnalysisOutcome(analysis: analysis, labels: labels, embedding: embedding?.vector, embeddingModel: embedding?.model)
    }

    public func embedding(for content: ExtractedContent, sender: String?, settings: AppSettings, config: PipelineConfig,
                          trace: TraceContext) async throws -> (vector: [Float], model: String)? {
        let resolved = try config.models(for: settings.models)
        let embedder = OllamaEmbedder(gate: gate, model: resolved.embed, keepAlive: resolved.keepAliveEmbed,
                                      numCtx: config.analysis.embeddingNumCtx)
        let summary = content.embeddingSummary(correspondentHint: sender, maxChars: config.analysis.embeddingSummaryChars)
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

    /// Who the document is from, as far as the app knows the sender: the known sender the model named, one the
    /// model wrote another way (its full legal name, say) that the document shows, or, when the model named nobody,
    /// the one an identifier or domain in the document belongs to. A sender the app does not know is nil.
    static func sender(reading: String, resolver: CorrespondentResolver, matches: [CorrespondentMatch]) -> Correspondent? {
        if let named = resolver.known(reading) { return named }
        guard !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return matches.first { [.stableKey, .emailDomain, .webDomain].contains($0.matchedBy) }?.correspondent
        }
        return matches.first { resolver.resembles(reading, $0.correspondent) }?.correspondent
    }

    /// The model's date, with where the extractor found it when it did; without one, the date the extractor chose.
    static func documentDate(_ answer: String?, content: ExtractedContent) -> (String?, DateSource) {
        if let d = answer {
            if let detected = content.entities.dates.first(where: { $0.date == d }) { return (d, detected.source) }
            return (d, .llm)
        }
        if let d = content.entities.documentDate { return (d.date, d.source) }
        return (nil, .none)
    }
}

/// What the analysis step records: the validated answer and every model call.
struct AnalysisTrace: Codable {
    var answer: ValidatedAnalysis?
    var calls: [ModelCall]
}
