import CryptoKit
import Foundation
import GRDB

/// Maintains the full-text (FTS5 via triggers) and vector index for documents.
public struct IndexStore: Sendable {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    /// Indexes a document's text with its labels, replacing what was indexed for it.
    public func upsertText(docID: Int64, filename: String, body: String, summary: String?, metadata: [String: String],
                           extractorVersion: String, labels: [DocumentLabel]) async throws {
        let kinds = LabelKind.allCases.map(\.rawValue)
        let columns = ["doc_id", "filename", "body", "summary", "metadata_json", "extractor_version"] + kinds
        let values: [(any DatabaseValueConvertible)?] = [docID, filename, body, summary, JSON.string(metadata), extractorVersion]
            + LabelKind.allCases.map { DocumentLabel.searchText(labels, kind: $0) }
        let arguments = StatementArguments(values)
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO document_text (\(columns.joined(separator: ", "))) VALUES (\(databaseQuestionMarks(count: columns.count)))
                ON CONFLICT(doc_id) DO UPDATE SET \(columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
                """, arguments: arguments)
        }
    }

    /// Makes a document's labels its own: on its row, which writes them into its record file, and in the full-text
    /// index, in one transaction.
    public func saveLabels(_ labels: [DocumentLabel], docID: Int64) async throws {
        try await database.writer.write { db in try Self.saveLabels(db, labels, docID: docID) }
    }

    /// Saves a document's labels inside an existing transaction, so a change to many documents commits as one.
    static func saveLabels(_ db: Database, _ labels: [DocumentLabel], docID: Int64) throws {
        let assignments = LabelKind.allCases.map { "\($0.rawValue) = ?" }.joined(separator: ", ")
        let values: [(any DatabaseValueConvertible)?] = LabelKind.allCases.map { DocumentLabel.searchText(labels, kind: $0) } + [docID]
        try db.execute(sql: "UPDATE documents SET labels_json = ?, updated_at = ? WHERE id = ?",
                       arguments: [JSON.string(labels), Date().unixSeconds, docID])
        try db.execute(sql: "UPDATE document_text SET \(assignments) WHERE doc_id = ?", arguments: StatementArguments(values))
    }

    /// Updates the searchable file name after a rename, keeping the rest.
    public func updateFilename(docID: Int64, filename: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE document_text SET filename = ? WHERE doc_id = ?", arguments: [filename, docID])
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
