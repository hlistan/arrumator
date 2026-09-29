import Accelerate
import Foundation

/// In-memory brute-force cosine index over L2-normalised vectors (contiguous matrix, vDSP dot products).
/// Personal archives stay well within the range where exact search is faster than an ANN structure.
public actor VectorIndex {
    public private(set) var model: String?
    private var dimension = 0
    private var ids: [Int64] = []
    private var rowOf: [Int64: Int] = [:]
    private var matrix: [Float] = []

    public init() {}

    public func load(model: String, rows: [(docID: Int64, vector: [Float])]) {
        self.model = model
        ids = []
        rowOf = [:]
        matrix = []
        dimension = rows.first?.vector.count ?? 0
        matrix.reserveCapacity(rows.count * dimension)
        for row in rows where row.vector.count == dimension { append(row.docID, row.vector) }
        Log.info(.search, "Vector index loaded", ["model": model, "rows": String(ids.count), "dim": String(dimension)])
    }

    public func upsert(docID: Int64, vector: [Float], model: String) {
        if self.model != model {
            self.model = model
            ids = []
            rowOf = [:]
            matrix = []
            dimension = vector.count
        }
        if dimension == 0 { dimension = vector.count }
        guard vector.count == dimension else { return }
        if let row = rowOf[docID] {
            matrix.replaceSubrange(row * dimension..<(row + 1) * dimension, with: vector)
        } else {
            append(docID, vector)
        }
    }

    public func remove(docID: Int64) {
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

    /// Top-k document ids by cosine similarity, optionally restricted to `allowed`.
    public func topK(_ query: [Float], k: Int, allowed: Set<Int64>? = nil) -> [(docID: Int64, score: Float)] {
        guard query.count == dimension, !ids.isEmpty, k > 0 else { return [] }
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

    private func append(_ docID: Int64, _ vector: [Float]) {
        rowOf[docID] = ids.count
        ids.append(docID)
        matrix.append(contentsOf: vector)
    }
}
