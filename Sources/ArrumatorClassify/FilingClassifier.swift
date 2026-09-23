import ArrumatorCore
import Foundation

/// The production `DocumentClassifier`. Flow: analyse → learned evidence (rules, near-identical past filings) →
/// for a new arrival, place directly when that evidence is confident; otherwise the model decides folder and file
/// name from the archive's logic, with the learned evidence as advice. When rethinking a filed document the model
/// always decides. The learner then updates memories and rules from whatever was decided.
public struct FilingClassifier: DocumentClassifier {
    public let store: any LearningStore
    public let logic: LogicStore
    public let memories: MemoryIndex
    public let gate: InferenceGate
    public let models: ModelManager
    public let prompts: PromptBuilder
    private let names = NameVectors()

    public init(store: any LearningStore, logic: LogicStore, memories: MemoryIndex, gate: InferenceGate, models: ModelManager,
                prompts: PromptBuilder) {
        self.store = store
        self.logic = logic
        self.memories = memories
        self.gate = gate
        self.models = models
        self.prompts = prompts
    }

    public func classify(_ content: ExtractedContent, taxonomy: TaxonomySnapshot, settings: AppSettings,
                         config: PipelineConfig, mode: ClassificationMode, trace: TraceContext) async throws -> ClassificationOutcome {
        let cc = config.classification
        let resolved = try config.models(for: settings.models)
        let embedder = OllamaEmbedder(gate: gate, model: resolved.embed, keepAlive: resolved.keepAliveEmbed, numCtx: cc.embeddingNumCtx)
        let evidence = LearnedEvidence(config: config.learning)
        let correspondents = try await store.correspondents()
        let ambiguous = Set(try await store.stableKeyOwners(minWeight: config.learning.trustedMemoryMinWeight)
            .filter { $0.value.count > 1 }.keys)
        let resolver = CorrespondentResolver(correspondents: correspondents, config: cc, entities: config.entities,
                                             ambiguousKeys: ambiguous)

        // 1. Learned correspondents
        let matches = await trace.measure(.correspondent, output: { (m: [CorrespondentMatch]) in
            m.prefix(5).map { ["name": $0.correspondent.canonicalName, "by": $0.matchedBy.rawValue, "evidence": $0.evidence,
                               "strength": String(format: "%.2f", $0.strength)] }
        }) { resolver.resolve(content) }

        // 2. Similar past filings
        let summary = content.embeddingSummary(correspondentHint: matches.first?.correspondent.canonicalName,
                                               maxChars: cc.embeddingSummaryChars)
        let vector = try await embed(summary, embedder: embedder, trace: trace)
        var neighbors: [ScoredMemory] = []
        if let vector {
            try await memories.load(model: embedder.modelId)
            neighbors = await memories.nearest(vector, config: cc.knn, now: Date())
        }
        if case let .rethink(documentID) = mode {
            // Its own past filing would simply repeat the old placement, and so would filings the user never confirmed.
            neighbors = neighbors.filter { $0.memory.documentID != documentID && $0.memory.weight >= config.rethink.memoryMinWeight }
        }
        let embeddingModel = vector == nil ? nil : embedder.modelId

        // 3. Learned rules (document-type conditions use what near-identical past filings agree on)
        let estimatedType = evidence.estimatedType(neighbors)
        let engine = RuleEngine(rules: try await store.rules(), config: cc)
        let (ruleHit, evaluations) = engine.evaluateBeforeModel(content, matches: matches, detectedType: estimatedType)
        let consensus = evidence.consensus(neighbors, taxonomy: taxonomy)
        await trace.record(.rules, startedAt: Date(), input: ["rules": String(engine.rules.count)],
                           output: EvidenceTrace(rule: ruleHit.map { RuleSummary($0.rule) }, evaluations: evaluations,
                                                 estimatedType: estimatedType, consensus: consensus))

        // 4. A new arrival with confident learned evidence → place directly, no model call
        let mayPlaceDirectly = mode == .arrival
        if mayPlaceDirectly, let hit = ruleHit, evidence.trusts(hit.rule), let folder = taxonomy.folder(id: hit.rule.action.folderID),
           folder.acceptsFiles {
            let decision = direct(folder: folder, confidence: hit.rule.reliability, decidedBy: .rule,
                                  rationale: "Learned rule “\(hit.rule.name)” (reliability \(String(format: "%.2f", hit.rule.reliability)))",
                                  type: hit.rule.action.documentType ?? estimatedType, correspondentID: hit.rule.action.correspondentID,
                                  content: content, matches: matches, correspondents: correspondents, settings: settings, ruleID: hit.rule.id)
            if decision.band == .auto {
                try await store.recordRuleHit(ruleID: hit.rule.id, at: Date())
                await trace.record(.calibrate, startedAt: Date(), input: ["mode": "learned rule"], output: decision.confidence)
                return ClassificationOutcome(
                    decision: try await named(decision, folder: folder, content: content, matches: matches, taxonomy: taxonomy,
                                              settings: settings, config: config, trace: trace),
                    embedding: vector, embeddingModel: embeddingModel)
            }
        }
        if mayPlaceDirectly, let consensus, let folder = taxonomy.folder(id: consensus.folderID) {
            let decision = direct(folder: folder, confidence: consensus.meanSimilarity, decidedBy: .knnOnly,
                                  rationale: "\(consensus.count) near-identical past filings are all in \(folder.code) \(folder.name)",
                                  type: consensus.documentType, correspondentID: consensus.correspondentID, content: content,
                                  matches: matches, correspondents: correspondents, settings: settings, ruleID: nil)
            if decision.band == .auto {
                await trace.record(.calibrate, startedAt: Date(), input: ["mode": "past filings"], output: decision.confidence)
                return ClassificationOutcome(
                    decision: try await named(decision, folder: folder, content: content, matches: matches, taxonomy: taxonomy,
                                              settings: settings, config: config, trace: trace),
                    embedding: vector, embeddingModel: embeddingModel)
            }
        }

        // 5. Not confident → the model decides, with the learned evidence as context
        var folderVectors: [String: [Float]] = [:]
        let userAreas = taxonomy.areas.filter { $0.origin != .system }
        if vector != nil, !taxonomy.fileableCategories.isEmpty {
            folderVectors = try await FolderEmbeddingCache(store: store, embedder: embedder, taxonomy: config.taxonomy)
                .vectors(for: taxonomy.fileableCategories)
        }
        let candidates = await trace.measure(.candidates, output: { (c: CandidateSet) in CandidatesTraceOutput(c) }) {
            CandidateGenerator(config: cc).generate(documentVector: vector, folderVectors: folderVectors, memories: neighbors,
                                                   taxonomy: taxonomy)
        }
        let hints = self.hints(matches: matches, ruleHit: ruleHit, consensus: consensus, neighbors: neighbors, taxonomy: taxonomy,
                               evidence: evidence, rulesPlaceDirectly: mayPlaceDirectly)
        let tiers = [LLMClassifier.Tier(model: resolved.chat, numCtx: resolved.numCtx, keepAlive: resolved.keepAliveChat),
                     LLMClassifier.Tier(model: resolved.fast, numCtx: resolved.fastNumCtx, keepAlive: resolved.keepAliveChat)]
            .reduce(into: [LLMClassifier.Tier]()) { acc, t in if !acc.contains(where: { $0.model == t.model }) { acc.append(t) } }
        let system = try prompts.classifySystem(folderLanguage: settings.folderNamingLanguage, logic: try await logic.current())
        let user = try prompts.classifyUser(content: content, candidates: candidates, taxonomy: taxonomy, hints: hints,
                                            correspondents: matches)
        let areaCodes = userAreas.map(\.code)
        let schema = ClassificationSchema.classify(folders: candidates.ranked.map(\.code), areas: areaCodes,
                                                   languages: config.extraction.languages, maxTags: cc.maxTags)
        let validator = AnswerValidator(taxonomy: taxonomy, config: cc, entities: config.entities, languages: config.extraction.languages)
        let prompts = prompts
        let started = Date()
        var answer: ModelAnswer<ValidatedDecision>?
        do {
            answer = try await LLMClassifier(gate: gate, models: models, config: cc).ask(
                system: system, user: user, schema: schema, tiers: tiers, repairPrompt: { try prompts.repair(errors: $0) },
                validate: { try validator.validate($0) })
            await trace.record(.llm, status: (answer?.calls.count ?? 0) > 1 ? .warn : .ok, startedAt: started,
                               input: ["tiers": tiers.map(\.model).joined(separator: ",")], output: answer?.calls)
        } catch let error as ModelAnswerError {
            if case let .exhausted(calls) = error {
                await trace.record(.llm, status: .error, startedAt: started, output: calls, error: error.localizedDescription)
            }
        }
        await trace.record(.validate, status: answer == nil ? .error : .ok, startedAt: Date(),
                           output: ["notes": answer?.answer.notes.joined(separator: "; ") ?? "no valid answer"])
        guard let model = answer else {
            return ClassificationOutcome(decision: unanswered(content: content, settings: settings, candidates: candidates),
                                         embedding: vector, embeddingModel: embeddingModel)
        }
        let a = model.answer

        // 6. Check the mapping from the model's ideal home onto the tree, then calibrate against learned evidence
        let placement = try await guardPlacement(a, embedder: embedder, available: vector != nil, taxonomy: taxonomy, config: cc,
                                                 trace: trace)
        let (postHit, _) = engine.evaluateAfterModel(content, matches: matches, documentType: a.documentType)
        let checkingRule = ruleHit ?? postHit
        var confidence = await trace.measure(.calibrate, output: { (r: ConfidenceReport) in r }) {
            Calibrator(config: config.calibration).calibrate(CalibrationInput(
                llmConfidence: a.confidence, chosenCode: placement.folderCode, isNewFolder: placement.newFolder != nil,
                idealSimilarity: placement.idealSimilarity, candidates: candidates, ruleHit: checkingRule?.rule,
                ruleAgrees: checkingRule.map { $0.rule.action.folderCode == placement.folderCode } ?? false,
                content: ExtractedContentSummary(content)), thresholds: settings.thresholds)
        }
        // A rule that the model ended up agreeing with has been used, even though it did not place the file itself.
        if let checkingRule, checkingRule.rule.action.folderCode == placement.folderCode {
            try? await store.recordRuleHit(ruleID: checkingRule.rule.id, at: Date())
        }
        var reasons: [String] = []
        if content.hasWarning(.encrypted) || content.hasWarning(.corrupted) {
            confidence.band = .review
            reasons.append(content.hasWarning(.encrypted) ? "encrypted" : "corrupted")
        }
        if placement.newFolder != nil && !settings.autoCreateFolders {
            confidence.band = .review
            reasons.append("a new folder is proposed and automatic folder creation is off")
        }
        if confidence.band == .review && reasons.isEmpty { reasons.append("low confidence") }
        let known = resolver.known(a.raw.correspondent)
        let (date, dateSource) = documentDate(a.documentDate, content: content)
        let decision = FilingDecision(
            folderCode: placement.folderCode, proposedNewFolder: placement.newFolder,
            alternatives: candidates.ranked.filter { $0.code != placement.folderCode }.prefix(cc.alternativesCount)
                .map { FolderAlternative(code: $0.code, score: $0.score) },
            correspondent: known?.canonicalName ?? nonEmpty(a.raw.correspondent) ?? matches.first?.correspondent.canonicalName,
            correspondentID: known?.id ?? (nonEmpty(a.raw.correspondent) == nil ? matches.first?.correspondent.id : nil),
            documentType: a.documentType, documentDate: date, dateSource: dateSource, periodYear: a.periodYear,
            title: nonEmpty(a.raw.title) ?? content.source.stem, fileName: nonEmpty(a.raw.fileName), tags: a.tags, language: a.language,
            confidence: confidence, decidedBy: .llm, rationale: a.raw.rationale, modelInfo: model.model, reviewReasons: reasons)
        return ClassificationOutcome(decision: decision, embedding: vector, embeddingModel: embeddingModel)
    }

    // MARK: Pieces

    /// Lets `PlacementGuard` check the mapping from the model's ideal home onto the tree using name embeddings.
    private func guardPlacement(_ a: ValidatedDecision, embedder: OllamaEmbedder, available: Bool, taxonomy: TaxonomySnapshot,
                                config: ClassificationConfig, trace: TraceContext) async throws -> GuardedPlacement {
        let unchanged = GuardedPlacement(folderCode: a.folderCode, newFolder: a.newFolder, idealSimilarity: nil, notes: [])
        guard available, !taxonomy.fileableCategories.isEmpty || !taxonomy.areas.isEmpty else { return unchanged }
        let started = Date()
        let vectors = try await names.vectors(for: PlacementGuard.names(for: a, taxonomy: taxonomy), embedder: embedder)
        let result = PlacementGuard(config: config.placementGuard).review(a, taxonomy: taxonomy, names: vectors)
        await trace.record(.validate, status: result.notes.isEmpty ? .ok : .warn, startedAt: started,
                           input: ["ideal": "\(a.ideal.newAreaName ?? a.ideal.areaCode ?? "") / \(a.ideal.name)",
                                   "chosen": a.folderCode ?? "NEW"],
                           output: result)
        return result
    }

    public func embedding(for content: ExtractedContent, sender: String?, settings: AppSettings, config: PipelineConfig,
                          trace: TraceContext) async throws -> (vector: [Float], model: String)? {
        let cc = config.classification
        let resolved = try config.models(for: settings.models)
        let embedder = OllamaEmbedder(gate: gate, model: resolved.embed, keepAlive: resolved.keepAliveEmbed, numCtx: cc.embeddingNumCtx)
        let summary = content.embeddingSummary(correspondentHint: sender, maxChars: cc.embeddingSummaryChars)
        return try await embed(summary, embedder: embedder, trace: trace).map { ($0, embedder.modelId) }
    }

    private func embed(_ text: String, embedder: OllamaEmbedder, trace: TraceContext) async throws -> [Float]? {
        let started = Date()
        do {
            let v = try await embedder.embed([text]).first
            await trace.record(.embed, startedAt: started, input: ["model": embedder.modelId, "chars": String(text.count)],
                               output: ["dimension": String(v?.count ?? 0)])
            return v
        } catch let error as OllamaError where error.isTransient {
            throw error
        } catch {
            await trace.record(.embed, status: .warn, startedAt: started, input: ["model": embedder.modelId],
                               error: error.localizedDescription)
            Log.warning(.classify, "Embedding unavailable; continuing without similarity", ["error": error.localizedDescription])
            return nil
        }
    }

    /// Every file is named by the model, following the logic, including a document learned evidence placed without
    /// asking it where the document goes. Without a valid answer the document keeps its own name.
    private func named(_ decision: FilingDecision, folder: TaxonomyFolder, content: ExtractedContent, matches: [CorrespondentMatch],
                       taxonomy: TaxonomySnapshot, settings: AppSettings, config: PipelineConfig,
                       trace: TraceContext) async throws -> FilingDecision {
        guard settings.renameFiles else { return decision }
        let resolved = try config.models(for: settings.models)
        let tiers = [LLMClassifier.Tier(model: resolved.fast, numCtx: resolved.fastNumCtx, keepAlive: resolved.keepAliveChat),
                     LLMClassifier.Tier(model: resolved.chat, numCtx: resolved.numCtx, keepAlive: resolved.keepAliveChat)]
            .reduce(into: [LLMClassifier.Tier]()) { acc, t in if !acc.contains(where: { $0.model == t.model }) { acc.append(t) } }
        let system = try prompts.nameSystem(folderLanguage: settings.folderNamingLanguage, logic: try await logic.current())
        let user = try prompts.nameUser(content: content, decision: decision, folder: folder, taxonomy: taxonomy, correspondents: matches)
        let prompts = prompts
        let input = ["purpose": "file name", "tiers": tiers.map(\.model).joined(separator: ",")]
        let started = Date()
        var named = decision
        do {
            let answer = try await LLMClassifier(gate: gate, models: models, config: config.classification).ask(
                system: system, user: user, schema: ClassificationSchema.fileName(), tiers: tiers,
                repairPrompt: { try prompts.repair(errors: $0) }, validate: { try AnswerValidator.fileName($0) })
            await trace.record(.llm, status: answer.calls.count > 1 ? .warn : .ok, startedAt: started, input: input, output: answer.calls)
            named.fileName = answer.answer
            named.modelInfo = answer.model
        } catch let error as ModelAnswerError {
            if case let .exhausted(calls) = error {
                await trace.record(.llm, status: .error, startedAt: started, input: input, output: calls, error: error.localizedDescription)
            }
            Log.warning(.classify, "The model gave no file name; the document keeps its own", ["error": error.localizedDescription])
        }
        return named
    }

    /// Decision made from learned evidence alone, named afterwards by `named`.
    private func direct(folder: TaxonomyFolder, confidence: Double, decidedBy: DecidedBy, rationale: String, type: DocumentType?,
                        correspondentID: Int64?, content: ExtractedContent, matches: [CorrespondentMatch],
                        correspondents: [Correspondent], settings: AppSettings, ruleID: Int64?) -> FilingDecision {
        let correspondent = correspondentID.flatMap { id in correspondents.first { $0.id == id } } ?? matches.first?.correspondent
        let report = ConfidenceReport(ruleHit: ruleID, modifiers: [decidedBy.rawValue: confidence], final: confidence,
                                      band: settings.thresholds.band(for: confidence), thresholds: settings.thresholds)
        let date = content.entities.documentDate
        return FilingDecision(folderCode: folder.code, correspondent: correspondent?.canonicalName, correspondentID: correspondent?.id,
                              documentType: type ?? .other, documentDate: date?.date, dateSource: date?.source ?? .none,
                              title: content.source.stem, language: content.language.primary, confidence: report,
                              decidedBy: decidedBy, rationale: rationale)
    }

    /// No valid model answer: hold for review, noting the most likely folder from learned evidence.
    private func unanswered(content: ExtractedContent, settings: AppSettings, candidates: CandidateSet) -> FilingDecision {
        FilingDecision(folderCode: nil, alternatives: candidates.ranked.prefix(3).map { FolderAlternative(code: $0.code, score: $0.score) },
                       documentDate: content.entities.documentDate?.date, dateSource: content.entities.documentDate?.source ?? .none,
                       title: content.source.stem, language: content.language.primary,
                       confidence: ConfidenceReport(final: 0, band: .review, thresholds: settings.thresholds), decidedBy: .review,
                       rationale: "The model gave no valid answer", reviewReasons: ["no valid model answer"])
    }

    /// Learned context for the model: known correspondent habits, partially trusted rules, near-identical filings.
    /// - Parameter rulesPlaceDirectly: trusted rules already placed the document when they could, so only rules that
    ///   are not yet reliable are worth mentioning; otherwise every matching rule is advice.
    private func hints(matches: [CorrespondentMatch], ruleHit: RuleHit?, consensus: NeighborConsensus?, neighbors: [ScoredMemory],
                       taxonomy: TaxonomySnapshot, evidence: LearnedEvidence, rulesPlaceDirectly: Bool) -> [String] {
        var out: [String] = []
        for m in matches.prefix(2) {
            var line = "\(m.correspondent.canonicalName) is a known correspondent (recognised by \(m.matchedBy.rawValue) \(m.evidence))"
            if let code = m.correspondent.defaultFolderCode, let f = taxonomy.folder(code: code) {
                line += "; its documents usually go to \(f.code) \(f.name)"
            }
            out.append(line)
        }
        if let hit = ruleHit {
            if !evidence.trusts(hit.rule) {
                out.append("A learned rule “\(hit.rule.name)” matches but is not yet reliable (\(String(format: "%.2f", hit.rule.reliability)))")
            } else if !rulesPlaceDirectly {
                out.append("A learned rule “\(hit.rule.name)” matches (reliability \(String(format: "%.2f", hit.rule.reliability)))")
            }
        }
        if let consensus, let f = taxonomy.folder(id: consensus.folderID) {
            out.append("\(consensus.count) near-identical past filings went to \(f.code) \(f.name)")
        }
        return out
    }

    private func documentDate(_ answer: String?, content: ExtractedContent) -> (String?, DateSource) {
        if let d = answer {
            if let detected = content.entities.dates.first(where: { $0.date == d }) { return (d, detected.source) }
            return (d, .llm)
        }
        if let d = content.entities.documentDate { return (d.date, d.source) }
        return (nil, .none)
    }

    private func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: Trace payloads

struct RuleSummary: Codable {
    var id: Int64
    var name: String
    var folder: String
    var reliability: Double
    init(_ r: FilingRule) {
        id = r.id
        name = r.name
        folder = r.action.folderCode
        reliability = r.reliability
    }
}

struct EvidenceTrace: Codable {
    var rule: RuleSummary?
    var evaluations: [RuleEvaluation]
    var estimatedType: DocumentType?
    var consensus: NeighborConsensus?
}

struct CandidatesTraceOutput: Codable {
    var ranked: [FolderCandidate]
    var memories: [MemoryTrace]
    var knnShare: [String: Double]

    struct MemoryTrace: Codable {
        var id: Int64
        var folder: String
        var summary: String
        var similarity: Double
        var score: Double
        var weight: Double
    }

    init(_ c: CandidateSet) {
        ranked = c.ranked
        memories = c.memories.map { MemoryTrace(id: $0.memory.id, folder: $0.memory.folderCode, summary: $0.memory.summaryLine,
                                                similarity: $0.similarity, score: $0.score, weight: $0.memory.weight) }
        knnShare = c.knnShare
    }
}
