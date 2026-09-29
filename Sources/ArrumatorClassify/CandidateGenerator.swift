import ArrumatorCore
import Foundation

public struct FolderCandidate: Sendable, Codable, Hashable {
    public var code: String
    public var similarity: Double
    public var knnVote: Double
    public var score: Double
}

public struct CandidateSet: Sendable, Codable, Hashable {
    /// Every fileable folder, most likely first.
    public var ranked: [FolderCandidate]
    /// The past filings that voted, most similar first.
    public var neighbors: [ScoredMemory]
    /// Share of kNN vote mass per folder code.
    public var knnShare: [String: Double]
    public var usedMemories: Bool

    public func candidate(_ code: String) -> FolderCandidate? { ranked.first { $0.code == code } }
}

/// Orders existing folders by similarity to their descriptions and by where similar past filings went. The order
/// calibrates the model's decision and gives it alternatives; the model itself never sees it.
public struct CandidateGenerator: Sendable {
    public let config: ClassificationConfig

    public init(config: ClassificationConfig) { self.config = config }

    public func generate(documentVector: [Float]?, folderVectors: [String: [Float]], memories: [ScoredMemory],
                         taxonomy: TaxonomySnapshot) -> CandidateSet {
        let folders = taxonomy.fileable
        let codeByID = Dictionary(uniqueKeysWithValues: taxonomy.folders.map { ($0.id, $0.code) })
        var sim: [String: Double] = [:]
        if let documentVector {
            for f in folders { sim[f.code] = folderVectors[f.code].map { Double(VectorCodec.dot(documentVector, $0)) } ?? 0 }
        }
        var vote: [String: Double] = [:]
        for m in memories {
            guard let code = codeByID[m.memory.folderID] else { continue }
            vote[code, default: 0] += max(0, m.score)
        }
        let totalVote = vote.values.reduce(0, +)
        let share = totalVote > 0 ? vote.mapValues { $0 / totalVote } : [:]
        let weights = memories.isEmpty ? config.candidateWeightsNoMemory : config.candidateWeights
        let nSim = Self.minMax(sim)
        let nVote = Self.minMax(vote)
        let ranked = folders.map { f -> FolderCandidate in
            let score = weights.similarity * (nSim[f.code] ?? 0) + weights.knn * (nVote[f.code] ?? 0)
            return FolderCandidate(code: f.code, similarity: sim[f.code] ?? 0, knnVote: vote[f.code] ?? 0, score: score)
        }.sorted { $0.score > $1.score }
        return CandidateSet(ranked: ranked, neighbors: memories, knnShare: share, usedMemories: !memories.isEmpty)
    }

    static func minMax(_ values: [String: Double]) -> [String: Double] {
        guard let lo = values.values.min(), let hi = values.values.max(), hi > lo else { return values.mapValues { _ in 0 } }
        return values.mapValues { ($0 - lo) / (hi - lo) }
    }
}
