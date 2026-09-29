import CryptoKit
import Foundation
import GRDB

/// Maintains the full-text (FTS5 via triggers) and vector index for documents.
public struct IndexStore: Sendable {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func upsertText(docID: Int64, title: String, correspondent: String, filename: String, body: String,
                           summary: String?, metadata: [String: String], extractorVersion: String,
                           labels: [DocumentLabel]) async throws {
        try await database.writer.write { db in
            let text = { (kind: LabelKind) in DocumentLabel.searchText(labels, kind: kind) }
            let record = DocumentTextRecord(docId: docID, title: title, correspondent: correspondent, filename: filename,
                                            body: body, summary: summary, metadataJson: JSON.string(metadata),
                                            extractorVersion: extractorVersion, subject: text(.subject), object: text(.object),
                                            jurisdiction: text(.jurisdiction), language: text(.language))
            try record.upsert(db)
        }
    }

    /// Makes a document's labels its own: on its row, which writes them into its record file, and in the full-text
    /// index, in one transaction.
    public func saveLabels(_ labels: [DocumentLabel], docID: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET labels_json = ?, updated_at = ? WHERE id = ?",
                           arguments: [JSON.string(labels), Date().unixSeconds, docID])
            try db.execute(sql: "UPDATE document_text SET subject = ?, object = ?, jurisdiction = ?, language = ? WHERE doc_id = ?",
                           arguments: [DocumentLabel.searchText(labels, kind: .subject), DocumentLabel.searchText(labels, kind: .object),
                                       DocumentLabel.searchText(labels, kind: .jurisdiction),
                                       DocumentLabel.searchText(labels, kind: .language), docID])
        }
    }

    /// Updates the searchable header fields after a rename or user edit, keeping the body.
    public func updateHeader(docID: Int64, title: String, correspondent: String, filename: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE document_text SET title = ?, correspondent = ?, filename = ? WHERE doc_id = ?",
                           arguments: [title, correspondent, filename, docID])
        }
    }

    public func body(docID: Int64) async throws -> String? {
        try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM document_text WHERE doc_id = ?", arguments: [docID])
        }
    }

    public func upsertEmbedding(docID: Int64, model: String, vector: [Float], sourceText: String) async throws {
        let hash = SHA256.hash(data: Data(sourceText.utf8)).map { String(format: "%02x", $0) }.joined()
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM embeddings WHERE doc_id = ? AND model = ?", arguments: [docID, model])
            var e = EmbeddingRecord(id: nil, docId: docID, chunkIndex: 0, model: model, dim: vector.count,
                                    vector: VectorCodec.encode(vector), textHash: hash, createdAt: Date())
            try e.insert(db)
            try db.execute(sql: "UPDATE documents SET embedded_at = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, docID])
        }
    }

    public func embedding(docID: Int64, model: String) async throws -> [Float]? {
        try await database.reader.read { db in
            try Data.fetchOne(db, sql: "SELECT vector FROM embeddings WHERE doc_id = ? AND model = ? AND chunk_index = 0",
                              arguments: [docID, model]).map(VectorCodec.decode)
        }
    }

    public func embeddings(model: String) async throws -> [(docID: Int64, vector: [Float])] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT doc_id, vector FROM embeddings WHERE model = ? AND chunk_index = 0", arguments: [model])
                .map { ($0["doc_id"], VectorCodec.decode($0["vector"])) }
        }
    }
}
