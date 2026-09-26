import ArrumatorCore
import Foundation

public struct ScoredMemory: Sendable, Codable, Hashable {
    public var memory: FilingMemory
    public var similarity: Double
    public var score: Double
}

/// In-memory kNN over past filings for the active embedding model.
public actor MemoryIndex {
    private let store: any LearningStore
    private var model: String?
    private var memories: [Int64: FilingMemory] = [:]

    public init(store: any LearningStore) { self.store = store }

    public func load(model: String) async throws {
        guard self.model != model else { return }
        let all = try await store.memories(model: model)
        memories = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        self.model = model
        Log.info(.learn, "Memory index loaded", ["model": model, "memories": String(all.count)])
    }

    public var count: Int { memories.count }

    /// Adds or replaces a memory (e.g. after its weight changed).
    public func insert(_ memory: FilingMemory) {
        guard memory.embeddingModel == model else { return }
        memories[memory.id] = memory
    }

    public func remove(ids: [Int64]) {
        for id in ids { memories[id] = nil }
    }

    /// Top memories by `cosine × weight × recency`, at most `maxPerFolder` per folder.
    public func nearest(_ vector: [Float], config: ClassificationConfig.KNN, now: Date) -> [ScoredMemory] {
        let halfLifeSeconds = config.halfLifeDays * 86_400
        let scored = memories.values.map { m -> ScoredMemory in
            let sim = Double(VectorCodec.dot(vector, m.embedding))
            let age = max(0, now.timeIntervalSince(m.createdAt))
            let recency = config.recencyFloor + (1 - config.recencyFloor) * pow(0.5, age / halfLifeSeconds)
            return ScoredMemory(memory: m, similarity: sim, score: sim * m.weight * recency)
        }.sorted { $0.score > $1.score }
        var perFolder: [Int64: Int] = [:]
        var out: [ScoredMemory] = []
        for s in scored where out.count < config.k {
            let n = perFolder[s.memory.folderID, default: 0]
            guard n < config.maxPerFolder else { continue }
            perFolder[s.memory.folderID] = n + 1
            out.append(s)
        }
        return out
    }
}

/// Embeds folder descriptions once per description version and caches them in the database.
public struct FolderEmbeddingCache: Sendable {
    public let store: any LearningStore
    public let embedder: any Embedder
    public let taxonomy: TaxonomyConfig

    public init(store: any LearningStore, embedder: any Embedder, taxonomy: TaxonomyConfig) {
        self.store = store
        self.embedder = embedder
        self.taxonomy = taxonomy
    }

    public func vectors(for folders: [TaxonomyFolder], in snapshot: TaxonomySnapshot) async throws -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        var missing: [TaxonomyFolder] = []
        for f in folders {
            // A folder a rethink plan intends to create has no row to cache its vector against yet.
            if f.isPlanned {
                missing.append(f)
                continue
            }
            if let v = try await store.folderEmbedding(folderID: f.id, model: embedder.modelId, descriptionHash: f.descriptionHash) {
                out[f.code] = v
            } else {
                missing.append(f)
            }
        }
        guard !missing.isEmpty else { return out }
        let texts = missing.map {
            $0.embeddingText(path: snapshot.path(of: $0), bodyChars: taxonomy.embeddingBodyChars, exampleLimit: taxonomy.embeddingExampleLimit)
        }
        let vectors = try await embedder.embed(texts)
        for (f, v) in zip(missing, vectors) {
            out[f.code] = v
            guard !f.isPlanned else { continue }
            try await store.saveFolderEmbedding(folderID: f.id, model: embedder.modelId, descriptionHash: f.descriptionHash, vector: v)
        }
        Log.info(.classify, "Embedded folder descriptions", ["count": String(missing.count), "model": embedder.modelId])
        return out
    }
}
