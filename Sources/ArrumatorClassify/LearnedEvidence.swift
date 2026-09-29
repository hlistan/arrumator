import ArrumatorCore
import Foundation

/// Agreement among near-identical past filings.
public struct NeighborConsensus: Sendable, Codable, Hashable {
    public var folderID: Int64
    public var folderCode: String
    public var count: Int
    public var meanSimilarity: Double
    public var documentType: DocumentType?
    public var correspondentID: Int64?
}

/// Decides from what the app has learned alone — past filings and induced rules — whether a document can be
/// placed without asking the model.
public struct LearnedEvidence: Sendable {
    public let config: LearningConfig.DirectPlacement
    public let trustedMinWeight: Double

    public init(config: LearningConfig) {
        self.config = config.directPlacement
        trustedMinWeight = config.trustedMemoryMinWeight
    }

    /// Near-identical past filings that count as evidence (confirmed or confident, not derived placements).
    private func near(_ neighbors: [ScoredMemory]) -> [ScoredMemory] {
        neighbors.filter { $0.similarity >= config.knnMinSimilarity && $0.memory.weight >= trustedMinWeight }
    }

    /// Document type that near-identical past filings agree on (used to evaluate type conditions of rules).
    public func estimatedType(_ neighbors: [ScoredMemory]) -> DocumentType? {
        let close = near(neighbors)
        guard close.count >= config.typeEstimateMinNeighbors, let first = close.first?.memory.documentType,
              first != .other, close.allSatisfy({ $0.memory.documentType == first }) else { return nil }
        return first
    }

    /// All near-identical past filings went to the same, still fileable folder.
    public func consensus(_ neighbors: [ScoredMemory], taxonomy: TaxonomySnapshot) -> NeighborConsensus? {
        let close = near(neighbors)
        guard close.count >= config.knnMinNeighbors, let folderID = close.first?.memory.folderID,
              close.allSatisfy({ $0.memory.folderID == folderID }),
              let folder = taxonomy.folder(id: folderID), folder.acceptsFiles else { return nil }
        let types = Set(close.map(\.memory.documentType))
        let correspondents = Set(close.map(\.memory.correspondentID))
        return NeighborConsensus(folderID: folderID, folderCode: folder.code, count: close.count,
                                 meanSimilarity: close.map(\.similarity).reduce(0, +) / Double(close.count),
                                 documentType: types.count == 1 ? types.first : nil,
                                 correspondentID: correspondents.count == 1 ? correspondents.first ?? nil : nil)
    }

    /// A matched rule is trusted for direct placement only when its evidence is strong enough.
    public func trusts(_ rule: FilingRule) -> Bool { rule.reliability >= config.ruleMinReliability }
}
