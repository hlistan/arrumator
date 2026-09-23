import ArrumatorCore
import Foundation

/// Forms rules from usage once filings agree often enough:
/// `(correspondent, document type) → folder`, and `correspondent → folder` when every type agrees.
public struct RuleInducer: Sendable {
    public let store: any LearningStore
    public let config: LearningConfig

    public init(store: any LearningStore, config: LearningConfig) {
        self.store = store
        self.config = config
    }

    public struct Result: Sendable, Codable, Hashable {
        public var created: [FilingRule]
        public var updated: [FilingRule]
        public var proposed: [FilingRule]
        public var evaluated: [String]
    }

    public func evaluate(correspondentID: Int64, correspondentName: String, taxonomy: TaxonomySnapshot,
                         policy: InducedRulePolicy) async throws -> Result {
        let memories = try await store.memories(correspondentID: correspondentID).filter { $0.weight >= config.trustedMemoryMinWeight }
        let existing = try await store.rules()
        var result = Result(created: [], updated: [], proposed: [], evaluated: [])
        let byType = Dictionary(grouping: memories, by: \.documentType)
        for (type, group) in byType where type != .other {
            guard let candidate = consensus(group) else {
                result.evaluated.append("\(type.rawValue): no consensus in \(group.count)")
                continue
            }
            let predicates: [RulePredicate] = [.correspondent(id: correspondentID), .documentType(type)]
            guard let folder = taxonomy.folder(id: candidate.folderID) else { continue }
            if let known = existing.first(where: { Set($0.predicates) == Set(predicates) }) {
                try await refresh(known, with: candidate, folder: folder, into: &result)
                continue
            }
            let rule = FilingRule(name: "\(correspondentName) · \(type.rawValue) → \(folder.code) \(folder.name)",
                                  enabled: policy == .autoEnableAndNotify, priority: config.ruleInducedPriority, origin: .induced,
                                  predicates: predicates,
                                  action: RuleAction(folderID: folder.id, folderCode: folder.code, documentType: type,
                                                     correspondentID: correspondentID),
                                  support: candidate.support, contradictions: candidate.contradictions,
                                  explanation: "Learned from \(candidate.support) filings (\(candidate.contradictions) elsewhere)")
            try await persist(rule, support: candidate.support, contradictions: candidate.contradictions, policy: policy, into: &result)
        }
        if memories.count >= config.correspondentRuleMinSupport, let candidate = consensus(memories),
           candidate.contradictions == 0, let folder = taxonomy.folder(id: candidate.folderID) {
            let predicates: [RulePredicate] = [.correspondent(id: correspondentID)]
            if let known = existing.first(where: { Set($0.predicates) == Set(predicates) }) {
                try await refresh(known, with: candidate, folder: folder, into: &result)
            } else {
                let rule = FilingRule(name: "\(correspondentName) → \(folder.code) \(folder.name)", enabled: policy == .autoEnableAndNotify,
                                      priority: config.correspondentRulePriority, origin: .induced, predicates: predicates,
                                      action: RuleAction(folderID: folder.id, folderCode: folder.code, correspondentID: correspondentID),
                                      support: candidate.support,
                                      explanation: "All \(candidate.support) filings from this correspondent went here")
                try await persist(rule, support: candidate.support, contradictions: 0, policy: policy, into: &result)
            }
        }
        return result
    }

    /// Fresh evidence for a rule that already exists. Without this a rule's support is frozen at the moment it was
    /// created, so it can never become more trusted and can never recover from contradictions.
    private func refresh(_ known: FilingRule, with candidate: Consensus, folder: TaxonomyFolder,
                         into result: inout Result) async throws {
        // A forgotten rule stays as it is, so the same evidence cannot bring it back.
        guard !known.forgotten else { return }
        var rule = known
        rule.support = candidate.support
        rule.contradictions = max(rule.contradictions, candidate.contradictions)
        rule.action.folderID = folder.id
        rule.action.folderCode = folder.code
        rule.explanation = "Learned from \(candidate.support) filings (\(rule.contradictions) elsewhere)"
        // A rule the user switched off by hand stays off; one the app disabled comes back when the evidence recovers.
        let recovered = !rule.enabled && !rule.confirmed && rule.reliability >= config.ruleReenableReliability
        if recovered { rule.enabled = true }
        guard rule != known else { return }
        let saved = try await store.saveRule(rule)
        result.updated.append(saved)
        Log.info(.learn, recovered ? "Re-enabled rule after fresh evidence" : "Updated rule from new filings",
                 ["rule": saved.name, "support": String(saved.support), "contradictions": String(saved.contradictions)])
    }

    private struct Consensus {
        var folderID: Int64
        var support: Int
        var contradictions: Int
    }

    private func consensus(_ memories: [FilingMemory]) -> Consensus? {
        let counts = Dictionary(grouping: memories, by: \.folderID).mapValues(\.count)
        guard let (folderID, support) = counts.max(by: { $0.value < $1.value }), support >= config.ruleMinSupport else { return nil }
        let contradictions = memories.count - support
        let total = memories.count
        let allowed = total < config.ruleStrictBelowSupport ? 0 : Int(Double(total) * config.ruleMaxContradictionShare)
        guard contradictions <= allowed else { return nil }
        return Consensus(folderID: folderID, support: support, contradictions: contradictions)
    }

    private func persist(_ rule: FilingRule, support: Int, contradictions: Int, policy: InducedRulePolicy,
                         into result: inout Result) async throws {
        switch policy {
        case .autoEnableAndNotify:
            let saved = try await store.saveRule(rule)
            result.created.append(saved)
            Log.info(.learn, "Induced rule", ["rule": saved.name, "support": String(support)])
        case .proposeOnly:
            if try await store.hasPendingProposal(kind: .rule, folderID: rule.action.folderID, title: rule.name) { return }
            try await store.createProposal(kind: .rule, title: rule.name, folderID: rule.action.folderID,
                                           payload: JSON.string(RuleProposal(rule: rule, support: support, contradictions: contradictions)))
            result.proposed.append(rule)
        }
    }
}
