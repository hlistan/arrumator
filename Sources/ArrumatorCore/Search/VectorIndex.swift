import Accelerate
import Foundation

/// Why a query cannot be compared with the vectors the index holds.
public enum VectorIndexError: Error, LocalizedError, Equatable {
    /// The index holds the vectors of another embedding model, or of none yet.
    case otherModel(held: String?, asked: String)
    /// The query's vector has another number of dimensions than the model's vectors the index holds.
    case otherDimension(model: String, held: Int, asked: Int)

    public var errorDescription: String? {
        switch self {
        case let .otherModel(held?, asked): "The search index holds the vectors of \(held), not of \(asked)"
        case let .otherModel(nil, asked): "The search index holds no vectors yet, not those of \(asked)"
        case let .otherDimension(model, held, asked):
            "The search index holds vectors of \(held) dimensions for \(model), but the query's has \(asked)"
        }
    }
}

/// In-memory brute-force cosine index over L2-normalised vectors (contiguous matrix, vDSP dot products).
/// Personal archives stay well within the range where exact search is faster than an ANN structure.
///
/// It holds the vectors of one embedding model, all of one dimension: the model it was last loaded for, and the
/// dimension most of them have, or the first added to it while it held none. A vector of another model or dimension,
/// or an empty one, is refused, logged, and never takes the place of what the index holds, so a reading that ends after
/// the profile changed, with the model it began with, leaves the index as it is.
///
/// Loading takes two steps around the read of the vectors the index keeps (`beginLoad(model:)`, then `load`), so that a
/// vector filed or a document removed after the read began is kept and applied over what was read, never lost to the
/// snapshot.
public actor VectorIndex {
    public private(set) var model: String?
    private var dimension = 0
    private var ids: [Int64] = []
    private var rowOf: [Int64: Int] = [:]
    private var matrix: [Float] = []
    /// The model a load has begun for, and what has changed since it began, to be applied over what it read.
    private var loading: String?
    private var sinceLoadBegan: [Int64: Change] = [:]

    /// A vector filed, or a document taken out, while a load reads.
    private enum Change {
        case put([Float])
        case removed
    }

    public init() {}

    /// Begins a load of `model`'s vectors, before they are read: from now on, what is filed of `model` and every removal
    /// is kept, and `load` applies it over the rows it is given.
    public func beginLoad(model: String) {
        loading = model
        sinceLoadBegan = [:]
    }

    /// Gives up the load begun for `model`, as when its vectors could not be read: what was kept for it is dropped.
    public func abandonLoad(model: String) {
        guard loading == model else { return }
        loading = nil
        sinceLoadBegan = [:]
    }

    /// Holds the vectors of `model`, `rows`, in place of what it held. Their dimension is the one most of them have, the
    /// first of those as many; empty vectors and vectors of another dimension are left out, and logged. When a load of
    /// `model` began before `rows` were read (`beginLoad(model:)`), what was filed or removed since is applied over them.
    public func load(model: String, rows: [(docID: Int64, vector: [Float])]) {
        self.model = model
        ids = []
        rowOf = [:]
        matrix = []
        let usable = rows.filter { !$0.vector.isEmpty }
        var counts: [Int: Int] = [:]
        for row in usable { counts[row.vector.count, default: 0] += 1 }
        let most = counts.values.max()
        dimension = usable.first { counts[$0.vector.count] == most }?.vector.count ?? 0
        matrix.reserveCapacity(usable.count * dimension)
        for row in usable where row.vector.count == dimension { put(row.docID, row.vector) }
        if ids.count < rows.count {
            Log.warning(.search, "Vectors of another dimension or empty left out of the index",
                        ["model": model, "rows": String(rows.count - ids.count), "dim": String(dimension)])
        }
        if loading == model {
            let changes = sinceLoadBegan
            (loading, sinceLoadBegan) = (nil, [:])
            for (docID, change) in changes {
                switch change {
                case let .put(vector): take(docID, vector, model: model)
                case .removed: remove(docID: docID)
                }
            }
        }
        Log.info(.search, "Vector index loaded", ["model": model, "rows": String(ids.count), "dim": String(dimension)])
    }

    /// Adds `docID`'s vector, or replaces the one it had, when it is of the model the index holds and of its dimension,
    /// which the first vector sets while the index holds none. Anything else is refused and logged: the index keeps
    /// what it holds. While a load of `model` reads, the vector is also kept for it; an index not loaded, and not
    /// loading, takes nothing: it reads every vector the index keeps when it is loaded.
    public func upsert(docID: Int64, vector: [Float], model: String) {
        if loading == model { sinceLoadBegan[docID] = .put(vector) }
        guard let held = self.model else {
            Log.debug(.search, "Vector left for the index to load", ["doc": String(docID), "model": model])
            return
        }
        guard held == model else {
            if loading != model {
                Log.warning(.search, "Vector of another model refused", ["doc": String(docID), "model": model, "held": held])
            }
            return
        }
        take(docID, vector, model: model)
    }

    /// Puts `docID`'s vector of the model the index holds, when it is of its dimension, which it sets while the index
    /// holds none; refuses and logs anything else.
    private func take(_ docID: Int64, _ vector: [Float], model: String) {
        guard !vector.isEmpty, ids.isEmpty || vector.count == dimension else {
            Log.warning(.search, "Vector of another dimension refused",
                        ["doc": String(docID), "model": model, "dim": String(vector.count), "held": String(dimension)])
            return
        }
        if ids.isEmpty { dimension = vector.count }
        put(docID, vector)
    }

    /// Takes `docID`'s vector out, and, while a load reads, out of what it read too.
    public func remove(docID: Int64) {
        if loading != nil { sinceLoadBegan[docID] = .removed }
        guard let row = rowOf[docID] else { return }
        let last = ids.count - 1
        if row != last {
            let lastID = ids[last]
            matrix.replaceSubrange(row * dimension..<(row + 1) * dimension,
                                   with: matrix[last * dimension..<(last + 1) * dimension])
            ids[row] = lastID
            rowOf[lastID] = row
        }
        ids.removeLast()
        matrix.removeLast(dimension)
        rowOf[docID] = nil
    }

    /// Top-k document ids by cosine similarity to `query`, a vector of `model`, optionally restricted to `allowed`.
    /// Nothing when the index holds no vectors of `model`'s yet; a query of another model, or of another dimension than
    /// the vectors held, cannot be compared with them, and throws.
    public func topK(_ query: [Float], model: String, k: Int, allowed: Set<Int64>? = nil) throws -> [(docID: Int64, score: Float)] {
        guard self.model == model else { throw VectorIndexError.otherModel(held: self.model, asked: model) }
        guard !ids.isEmpty, k > 0 else { return [] }
        guard query.count == dimension else { throw VectorIndexError.otherDimension(model: model, held: dimension, asked: query.count) }
        var scores = [Float](repeating: 0, count: ids.count)
        matrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                guard let rows = m.baseAddress, let vector = q.baseAddress else { return }
                for row in 0..<ids.count {
                    vDSP_dotpr(rows + row * dimension, 1, vector, 1, &scores[row], vDSP_Length(dimension))
                }
            }
        }
        var ranked: [(Int64, Float)] = []
        ranked.reserveCapacity(ids.count)
        for (row, id) in ids.enumerated() where allowed?.contains(id) ?? true { ranked.append((id, scores[row])) }
        ranked.sort { $0.1 > $1.1 }
        return ranked.prefix(k).map { (docID: $0.0, score: $0.1) }
    }

    /// Adds or replaces a vector of the index's dimension.
    private func put(_ docID: Int64, _ vector: [Float]) {
        if let row = rowOf[docID] {
            matrix.replaceSubrange(row * dimension..<(row + 1) * dimension, with: vector)
        } else {
            rowOf[docID] = ids.count
            ids.append(docID)
            matrix.append(contentsOf: vector)
        }
    }
}
