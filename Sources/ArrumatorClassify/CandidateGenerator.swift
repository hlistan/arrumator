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
    public var memories: [ScoredMemory]
    /// Share of kNN vote mass per folder code.
    public var knnShare: [String: Double]
    public var usedMemories: Bool

    public func candidate(_ code: String) -> FolderCandidate? { ranked.first { $0.code == code } }
}

/// Orders existing folders by similarity to their descriptions and by where similar past filings went.
/// The model still sees every folder; the order and the prior filings are context, not a filter.
public struct CandidateGenerator: Sendable {
    public let config: ClassificationConfig

    public init(config: ClassificationConfig) { self.config = config }

    public func generate(documentVector: [Float]?, folderVectors: [String: [Float]], memories: [ScoredMemory],
                         taxonomy: TaxonomySnapshot) -> CandidateSet {
        let folders = taxonomy.fileableCategories
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
        let ranked = folders.map { f in
            FolderCandidate(code: f.code, similarity: sim[f.code] ?? 0, knnVote: vote[f.code] ?? 0,
                            score: weights.similarity * (nSim[f.code] ?? 0) + weights.knn * (nVote[f.code] ?? 0))
        }.sorted { $0.score > $1.score }
        var perFolder: [Int64: Int] = [:]
        var promptMemories: [ScoredMemory] = []
        for m in memories where promptMemories.count < config.promptMemories {
            let n = perFolder[m.memory.folderID, default: 0]
            guard n < config.promptMemoriesPerFolder else { continue }
            perFolder[m.memory.folderID] = n + 1
            promptMemories.append(m)
        }
        return CandidateSet(ranked: ranked, memories: promptMemories, knnShare: share, usedMemories: !memories.isEmpty)
    }

    static func minMax(_ values: [String: Double]) -> [String: Double] {
        guard let lo = values.values.min(), let hi = values.values.max(), hi > lo else { return values.mapValues { _ in 0 } }
        return values.mapValues { ($0 - lo) / (hi - lo) }
    }
}
