import ArrumatorCore
import Foundation

/// Turns every placement and correction into memories, correspondent knowledge and rules, and keeps each
/// folder's learned context (recent files, usual correspondents) up to date. This is how rules form from usage.
public actor Learner: LearningSink {
    private let store: any LearningStore
    private let memories: MemoryIndex
    private let settings: SettingsStore
    private let config: PipelineConfig
    private let taxonomy: TaxonomyStore
    private let refresher: DescriptionRefresher
    private let absorber: FolderAbsorber
    private let history: HistoryStore
    /// Most recent correction per document, used to weight the memory written when it is (re)filed.
    private var lastCorrection: [Int64: CorrectionEvent] = [:]
    private var background: Task<Void, Never>?

    public init(store: any LearningStore, memories: MemoryIndex, settings: SettingsStore, config: PipelineConfig,
                taxonomy: TaxonomyStore, refresher: DescriptionRefresher, absorber: FolderAbsorber, history: HistoryStore) {
        self.store = store
        self.memories = memories
        self.settings = settings
        self.config = config
        self.taxonomy = taxonomy
        self.refresher = refresher
        self.absorber = absorber
        self.history = history
    }

    // MARK: LearningSink

    public func documentFiled(documentID: Int64, folderID: Int64, outcome: ClassificationOutcome, content: ExtractedContent,
                              confirmedByUser: Bool, trace: TraceContext) async {
        let started = Date()
        do {
            let current = await settings.current
            let snapshot = try await taxonomy.snapshot(root: current.archiveURL)
            guard let folder = snapshot.folder(id: folderID) else { return }
            let decision = outcome.decision
            let correction = lastCorrection.removeValue(forKey: documentID)
            let weights = config.learning.memoryWeights
            let weight: Double
            let source: String
            let evidence: FilingEvidence
            if let correction, correction.fromFolderID != correction.toFolderID {
                weight = weights.corrected
                source = correction.source.rawValue
                evidence = .corrected
            } else if confirmedByUser {
                weight = weights.approved
                source = "approved"
                evidence = .approved
            } else if decision.decidedBy == .llm && decision.band == .auto {
                weight = weights.auto
                source = decision.decidedBy.rawValue
                evidence = .confident
            } else {
                // Uncertain decisions and placements derived from existing rules or filings add no new evidence.
                weight = weights.unconfirmed
                source = decision.decidedBy.rawValue
                evidence = .unconfirmed
            }
            let correspondent = try await learnCorrespondent(decision: decision, content: content, documentID: documentID)
            var memoryID: Int64?
            var pruned: [Int64] = []
            if let embedding = outcome.embedding, let model = outcome.embeddingModel {
                let removed = try await store.deleteMemories(documentID: documentID)
                await memories.remove(ids: removed)
                let summary = "\(URL(fileURLWithPath: content.source.path).lastPathComponent) | \(correspondent?.canonicalName ?? decision.correspondent ?? "—") | \(decision.documentType.rawValue)"
                let memory = try await store.insertMemory(FilingMemory(
                    id: 0, documentID: documentID, folderID: folderID, folderCode: folder.code, embedding: embedding,
                    embeddingModel: model, summaryLine: summary, correspondentID: correspondent?.id,
                    documentType: decision.documentType, language: decision.language,
                    stableKeys: content.entities.stableKeys.map(\.token), weight: weight, source: source, createdAt: Date()))
                await memories.insert(memory)
                memoryID = memory.id
                pruned = try await store.pruneMemories(folderID: folderID, keep: config.learning.maxMemoriesPerFolder)
                await memories.remove(ids: pruned)
            }
            var induced: RuleInducer.Result?
            if let correspondent {
                try await learnCorrespondentFacts(correspondent)
                induced = try await RuleInducer(store: store, config: config.learning).evaluate(
                    correspondentID: correspondent.id, correspondentName: correspondent.canonicalName, taxonomy: snapshot,
                    policy: current.inducedRulePolicy)
                if let induced { try await recordRuleChanges(induced, documentID: documentID) }
            }
            let profile = try await store.folderProfile(folderID: folderID, examples: config.taxonomy.learnedExamplesLimit,
                                                        correspondents: config.taxonomy.learnedCorrespondentsLimit)
            try await taxonomy.updateLearned(folderID: folderID, root: current.archiveURL, learned: profile)
            let due = try await refresher.noteFiling(folderID: folderID)
            let learned = LearnTrace(memoryID: memoryID, weight: weight, pruned: pruned.count,
                                     correspondent: correspondent?.canonicalName,
                                     rulesCreated: induced?.created.map(\.name) ?? [],
                                     rulesUpdated: induced?.updated.map(\.name) ?? [],
                                     rulesProposed: induced?.proposed.map(\.name) ?? [],
                                     descriptionRefreshDue: due)
            await trace.record(.learn, startedAt: started, input: ["folder": folder.code, "source": source], output: learned)
            if memoryID != nil, let reason = evidence.reason {
                try await history.record(.learned, doc: documentID, trace: trace.traceID,
                                         summary: "Remembered as an example of \(snapshot.path(of: folder)) (\(reason))",
                                         payload: LearnedFact.example(documentID: documentID))
            }
            if due { scheduleRefresh(folder: folder, snapshot: snapshot, settings: current) }
        } catch {
            await trace.record(.learn, status: .error, startedAt: started, error: error.localizedDescription)
            Log.error(.learn, "Learning from filing failed", ["doc": String(documentID), "error": error.localizedDescription])
        }
    }

    public func correctionRecorded(_ correction: CorrectionEvent, trace: TraceContext) async {
        lastCorrection[correction.documentID] = correction
        if correction.source == .markCorrect { await confirm(correction.documentID) }
        if let renamed = correction.editedFields["correspondent"], let previous = correction.proposed?.correspondent {
            await learnAlias(canonical: renamed, alias: previous, documentID: correction.documentID)
        }
        guard let proposed = correction.proposed else { return }
        do {
            let rules = try await store.rules()
            // Approving a proposal moves the document out of Needs review, which is not a disagreement: a rule is
            // contradicted only when the user put the document somewhere other than where the rule points.
            func disagrees(_ rule: FilingRule) -> Bool { rule.action.folderID != correction.toFolderID }
            var contradicted = rules.filter { !$0.forgotten && $0.id == proposed.confidence.ruleHit && disagrees($0) }
            if let cid = proposed.correspondentID {
                contradicted += rules.filter { rule in
                    !rule.forgotten && rule.origin == .induced && disagrees(rule) && rule.action.folderCode == proposed.folderCode
                        && rule.predicates.contains(.correspondent(id: cid)) && !contradicted.contains(where: { $0.id == rule.id })
                }
            }
            let limit = config.learning.ruleDisableAfterContradictions
            for var rule in contradicted {
                rule.contradictions += 1
                if rule.enabled && rule.contradictions >= limit {
                    rule.enabled = false
                    try await store.createProposal(kind: .ruleDisabled, title: "Rule “\(rule.name)” was disabled", folderID: rule.action.folderID,
                                                   payload: JSON.string(RuleProposal(rule: rule, support: rule.support,
                                                                                     contradictions: rule.contradictions)))
                    try await history.record(.ruleDisabled, doc: correction.documentID, trace: trace.traceID, summary: rule.name,
                                             payload: RuleSummary(rule))
                    Log.info(.learn, "Disabled contradicted rule", ["rule": rule.name])
                } else if rule.enabled {
                    try await history.record(.learned, doc: correction.documentID, trace: trace.traceID,
                                             summary: "Rule “\(rule.name)” was wrong here (\(rule.contradictions) of \(limit) before it switches off)",
                                             payload: LearnedFact.rule(id: rule.id))
                }
                try await store.saveRule(rule)
            }
        } catch {
            Log.error(.learn, "Could not apply correction to rules", ["error": error.localizedDescription])
        }
    }

    public func documentForgotten(documentID: Int64) async {
        do {
            let removed = try await store.deleteMemories(documentID: documentID)
            await memories.remove(ids: removed)
            lastCorrection[documentID] = nil
            if !removed.isEmpty {
                try await history.record(.forgot, doc: documentID, summary: "Forgot where this was filed")
            }
        } catch {
            Log.error(.learn, "Could not forget document", ["doc": String(documentID), "error": error.localizedDescription])
        }
    }

    public func taxonomyChanged(_ changes: [TaxonomyChange], taxonomy snapshot: TaxonomySnapshot) async {
        let current = await settings.current
        for change in changes where change.kind == .inferred {
            guard let folder = snapshot.folder(code: change.code), folder.holdsUserDocuments else { continue }
            enqueueBackground { [absorber, config] in
                let models = try config.models(for: current.models)
                try await absorber.propose(folder: folder, taxonomy: snapshot, model: models.chat, keepAlive: models.keepAliveChat,
                                           numCtx: models.numCtx, language: current.folderNamingLanguage)
            }
        }
        for change in changes where change.kind == .removed {
            if let id = snapshot.folder(code: change.code)?.id { try? await store.setMemoriesOrphaned(folderID: id, orphaned: true) }
        }
    }

    /// The user confirmed a placement: its memories become trusted evidence, which can promote identifiers and form rules.
    private func confirm(_ documentID: Int64) async {
        lastCorrection[documentID] = nil
        do {
            let updated = try await store.confirmMemories(documentID: documentID, weight: config.learning.memoryWeights.approved,
                                                          source: CorrectionSource.markCorrect.rawValue)
            let snapshot = try await taxonomy.snapshot(root: await settings.current.archiveURL)
            for code in Set(updated.map(\.folderCode)).sorted() {
                let folder = snapshot.folder(code: code).map { snapshot.path(of: $0) } ?? code
                try await history.record(.learned, doc: documentID,
                                         summary: "Remembered as an example of \(folder) (\(FilingEvidence.approved.reason ?? ""))",
                                         payload: LearnedFact.example(documentID: documentID))
            }
            try await relearn(from: updated, documentID: documentID)
        } catch {
            Log.error(.learn, "Could not apply confirmation", ["doc": String(documentID), "error": error.localizedDescription])
        }
    }

    public func documentReembedded(documentID: Int64, vector: [Float], model: String) async {
        do {
            for memory in try await store.setMemoryEmbeddings(documentID: documentID, vector: vector, model: model) {
                await memories.insert(memory)
            }
        } catch {
            Log.error(.learn, "Could not give memories their new embedding", ["doc": String(documentID), "error": error.localizedDescription])
        }
    }

    /// A filing the user has left alone for long enough is evidence too, so the app keeps learning from ordinary use
    /// rather than only from explicit approvals.
    public func settleUntouchedFilings() async {
        let days = config.learning.settleUnconfirmedAfterDays
        guard days > 0 else { return }
        do {
            let settled = try await store.settleMemories(before: Date().addingTimeInterval(-Double(days) * 86_400),
                                                         weight: config.learning.memoryWeights.auto, source: "settled")
            guard !settled.isEmpty else { return }
            Log.info(.learn, "Filings left untouched now count as evidence", ["memories": String(settled.count),
                                                                              "days": String(days)])
            try await relearn(from: settled, documentID: nil)
        } catch {
            Log.error(.learn, "Could not settle untouched filings", ["error": error.localizedDescription])
        }
    }

    /// Re-runs correspondent learning and rule induction for whoever these memories belong to. `documentID` is the
    /// document that caused it, when there is one.
    private func relearn(from updated: [FilingMemory], documentID: Int64?) async throws {
        for memory in updated { await memories.insert(memory) }
        let current = await settings.current
        let snapshot = try await taxonomy.snapshot(root: current.archiveURL)
        let all = try await store.correspondents()
        for id in Set(updated.compactMap(\.correspondentID)) {
            guard let correspondent = all.first(where: { $0.id == id }) else { continue }
            try await learnCorrespondentFacts(correspondent)
            let induced = try await RuleInducer(store: store, config: config.learning).evaluate(
                correspondentID: id, correspondentName: correspondent.canonicalName, taxonomy: snapshot,
                policy: current.inducedRulePolicy)
            try await recordRuleChanges(induced, documentID: documentID)
        }
    }

    /// Records rules that formed or gained support, against the document that caused it when there is one.
    private func recordRuleChanges(_ induced: RuleInducer.Result, documentID: Int64?) async throws {
        for rule in induced.created {
            try await history.record(.ruleInduced, doc: documentID, summary: rule.name, payload: RuleSummary(rule))
        }
        for rule in induced.updated {
            try await history.record(.ruleChanged, doc: documentID, summary: "\(rule.name) · now \(rule.support) filings agree",
                                     payload: RuleSummary(rule))
        }
    }

    /// Rules follow their documents. A rule whose documents a rethink moved together to another folder now points
    /// there; a rule whose folder was removed while its documents scattered is switched off.
    public func placementsRearranged(_ moves: [PlacementMove], removedFolderIDs: Set<Int64>) async {
        guard !moves.isEmpty || !removedFolderIDs.isEmpty else { return }
        do {
            let snapshot = try await taxonomy.snapshot(root: await settings.current.archiveURL)
            for var rule in try await store.rules() where !rule.forgotten {
                let from = rule.action.folderID
                let removed = removedFolderIDs.contains(from)
                let correspondent = rule.senderID
                let type = rule.predicates.lazy.compactMap { p -> DocumentType? in
                    if case let .documentType(t) = p { t } else { nil }
                }.first
                let moved = moves.filter {
                    $0.fromFolderID == from && (correspondent == nil || $0.correspondentID == correspondent)
                        && (type == nil || $0.documentType == type)
                }
                guard !moved.isEmpty || removed else { continue }
                let stayed = removed ? 0 : try await store.documentCount(folderID: from, correspondentID: correspondent, documentType: type)
                let destinations = Dictionary(grouping: moved, by: \.toFolderID).mapValues(\.count)
                if let (to, count) = destinations.max(by: { $0.value < $1.value }),
                   Double(count) / Double(moved.count + stayed) >= config.rethink.followShare, let folder = snapshot.folder(id: to) {
                    rule.action.folderID = folder.id
                    rule.action.folderCode = folder.code
                    if let arrow = rule.name.range(of: " → ", options: .backwards) {
                        rule.name = rule.name[..<arrow.upperBound] + "\(snapshot.path(of: folder))"
                    }
                    try await store.saveRule(rule)
                    try await history.record(.ruleChanged, summary: "“\(rule.name)” followed its documents to \(snapshot.path(of: folder))",
                                             payload: RuleSummary(rule))
                } else if removed, rule.enabled {
                    rule.enabled = false
                    try await store.saveRule(rule)
                    try await history.record(.ruleDisabled, summary: rule.name, payload: RuleSummary(rule))
                }
            }
        } catch {
            Log.error(.learn, "Could not update rules after rethinking placement", ["error": error.localizedDescription])
        }
    }

    // MARK: Forgetting

    /// Makes the app forget something it learned, and records that it did. Forgetting what is already forgotten
    /// does nothing.
    public func forget(_ fact: LearnedFact) async throws {
        let summary: String
        var documentID: Int64?
        switch fact {
        case let .example(id):
            let removed = try await store.deleteMemories(documentID: id)
            guard !removed.isEmpty else { return }
            await memories.remove(ids: removed)
            lastCorrection[id] = nil
            documentID = id
            summary = "Forgot this document as an example of where documents like it go"
        case let .rule(id):
            guard var rule = try await store.rules().first(where: { $0.id == id }), !rule.forgotten else { return }
            forgetRule(&rule)
            try await store.saveRule(rule)
            summary = "Forgot rule “\(rule.name)”"
        case let .alias(correspondentID, alias):
            guard var sender = try await store.correspondents().first(where: { $0.id == correspondentID }),
                  sender.aliases.contains(alias) else { return }
            sender.aliases.removeAll { $0 == alias }
            try await store.saveCorrespondent(sender)
            summary = "Forgot that “\(alias)” is another name for \(sender.canonicalName)"
        case let .sender(correspondentID):
            guard let sender = try await store.correspondents().first(where: { $0.id == correspondentID }) else { return }
            for var rule in try await store.rules() where !rule.forgotten && rule.predicates.contains(.correspondent(id: correspondentID)) {
                forgetRule(&rule)
                try await store.saveRule(rule)
            }
            try await store.deleteCorrespondent(id: correspondentID)
            summary = "Forgot what it knew about \(sender.canonicalName)"
        }
        try await history.record(.forgot, actor: .user, doc: documentID, summary: summary, payload: fact)
        Log.info(.learn, "Forgot", ["what": summary])
    }

    /// A forgotten rule stays in place, switched off for good, so the evidence that formed it cannot form it again.
    private func forgetRule(_ rule: inout FilingRule) {
        rule.enabled = false
        rule.confirmed = true
        rule.forgotten = true
    }

    // MARK: Correspondents

    /// The user renamed a correspondent: remember the old spelling as an alias of the new canonical name.
    private func learnAlias(canonical: String, alias: String, documentID: Int64) async {
        do {
            let all = try await store.correspondents()
            let norm = TextNormalizer.normalize
            guard norm(canonical) != norm(alias) else { return }
            var target = all.first { norm($0.canonicalName) == norm(canonical) }
                ?? Correspondent(canonicalName: canonical, origin: .user)
            guard !target.aliases.contains(where: { norm($0) == norm(alias) }) else { return }
            target.aliases.append(alias)
            try await store.saveCorrespondent(target)
            try await history.record(.learned, doc: documentID,
                                     summary: "Remembered “\(alias)” as another name for \(target.canonicalName)",
                                     payload: LearnedFact.alias(correspondentID: target.id, alias: alias))
        } catch {
            Log.error(.learn, "Could not learn correspondent alias", ["error": error.localizedDescription])
        }
    }

    private func learnCorrespondent(decision: FilingDecision, content: ExtractedContent, documentID: Int64) async throws -> Correspondent? {
        let all = try await store.correspondents()
        if let id = decision.correspondentID, let known = all.first(where: { $0.id == id }) {
            try await store.linkCorrespondent(documentID: documentID, correspondentID: known.id, name: decision.correspondent ?? known.canonicalName)
            return known
        }
        guard let name = decision.correspondent?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let normalized = TextNormalizer.normalize(name)
        if let existing = all.first(where: { c in ([c.canonicalName] + c.aliases).contains { TextNormalizer.normalize($0) == normalized } }) {
            try await store.linkCorrespondent(documentID: documentID, correspondentID: existing.id, name: existing.canonicalName)
            return existing
        }
        let emailDomain = content.metadata["email:from"].flatMap(CorrespondentResolver.domain(ofEmail:))
        let created = try await store.saveCorrespondent(Correspondent(
            canonicalName: name, emailDomains: emailDomain.map { [$0] } ?? [], origin: .learned))
        try await store.linkCorrespondent(documentID: documentID, correspondentID: created.id, name: created.canonicalName)
        Log.info(.learn, "Learned new correspondent", ["name": name])
        return created
    }

    /// Promotes identifiers seen in several trusted filings — and only with this correspondent — to stable keys, and
    /// records the correspondent's usual folder. Identifiers shared across correspondents (the user's own tax number
    /// or IBAN printed on every bill) never identify a correspondent and are dropped.
    private func learnCorrespondentFacts(_ correspondent: Correspondent) async throws {
        let trusted = config.learning.trustedMemoryMinWeight
        let filings = try await store.memories(correspondentID: correspondent.id).filter { $0.weight >= trusted }
        let owners = try await store.stableKeyOwners(minWeight: trusted)
        var c = correspondent
        c.filedCount = filings.count
        let keyCounts = filings.flatMap { Set($0.stableKeys) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let exclusive = Set(owners.filter { $0.value == [correspondent.id] }.keys)
        let promoted = keyCounts.filter { $0.value >= config.learning.stableKeyMinFilings && exclusive.contains($0.key) }.map(\.key)
        c.stableKeys = Array(Set(c.stableKeys.filter(exclusive.contains) + promoted)).sorted()
        let folderCounts = Dictionary(grouping: filings, by: \.folderCode).mapValues(\.count)
        if let (code, wins) = folderCounts.max(by: { $0.value < $1.value }), wins >= config.learning.defaultFolderMinWins {
            c.defaultFolderCode = code
        }
        if c != correspondent { try await store.saveCorrespondent(c) }
    }

    // MARK: Background proposals

    private func scheduleRefresh(folder: TaxonomyFolder, snapshot: TaxonomySnapshot, settings current: AppSettings) {
        enqueueBackground { [refresher, config] in
            let models = try config.models(for: current.models)
            try await refresher.propose(folder: folder, taxonomy: snapshot, model: models.chat, keepAlive: models.keepAliveChat,
                                        numCtx: models.numCtx, language: current.folderNamingLanguage)
        }
    }

    /// Runs proposal work one after another, after any previous background work.
    private func enqueueBackground(_ work: @escaping @Sendable () async throws -> Void) {
        let previous = background
        background = Task(priority: .background) {
            await previous?.value
            do { try await work() } catch {
                Log.warning(.learn, "Background proposal failed", ["error": error.localizedDescription])
            }
        }
    }
}

/// How much a filing says about where documents like it belong.
enum FilingEvidence {
    case corrected, approved, confident, unconfirmed

    /// Why the filing counts as evidence, in the words shown next to the document; nil when it does not count.
    var reason: String? {
        switch self {
        case .corrected: "you corrected it"
        case .approved: "you confirmed it"
        case .confident: "filed with high confidence"
        case .unconfirmed: nil
        }
    }
}

struct LearnTrace: Codable {
    var memoryID: Int64?
    var weight: Double
    var pruned: Int
    var correspondent: String?
    var rulesCreated: [String]
    var rulesUpdated: [String]
    var rulesProposed: [String]
    var descriptionRefreshDue: Bool
}
