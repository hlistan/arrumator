import CryptoKit
import Foundation
import GRDB

/// Maintains the full-text (FTS5 via triggers) and vector index for documents.
public struct IndexStore: Sendable {
    public let database: AppDatabase
    public let time: any TimeSource

    public init(database: AppDatabase, time: any TimeSource) {
        self.database = database
        self.time = time
    }

    /// Indexes a document's text with its labels, replacing what was indexed for it.
    public func upsertText(docID: Int64, filename: String, body: String, summary: String?, metadata: [String: String],
                           extractorVersion: String, labels: [DocumentLabel]) async throws {
        let kinds = LabelKind.allCases.map(\.rawValue)
        let columns = ["doc_id", "filename", "body", "summary", "metadata_json", "extractor_version"] + kinds
        let values: [(any DatabaseValueConvertible)?] = [docID, filename, body, summary, try JSON.string(metadata), extractorVersion]
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
    /// index, in one transaction. `labelled` says whether they label it, as when the model read it; a document's tags
    /// alone do not (`DocumentLabel.stored`).
    public func saveLabels(_ labels: [DocumentLabel], docID: Int64, labelled: Bool) async throws {
        let now = time.now()
        try await database.writer.write { db in try Self.saveLabels(db, labels, docID: docID, labelled: labelled, at: now) }
    }

    /// Saves a document's labels inside an existing transaction, so a change to many documents commits as one.
    static func saveLabels(_ db: Database, _ labels: [DocumentLabel], docID: Int64, labelled: Bool, at now: Date) throws {
        let stored = DocumentLabel.stored(labels, labelled: labelled)
        let assignments = LabelKind.allCases.map { "\($0.rawValue) = ?" }.joined(separator: ", ")
        let values: [(any DatabaseValueConvertible)?] = LabelKind.allCases.map { DocumentLabel.searchText(labels, kind: $0) } + [docID]
        try db.execute(sql: "UPDATE documents SET labels_json = ?, tags_only = ?, updated_at = ? WHERE id = ?",
                       arguments: [try stored.labels.map { try JSON.string($0) }, stored.tagsOnly, now.unixSeconds, docID])
        try db.execute(sql: "UPDATE document_text SET \(assignments) WHERE doc_id = ?", arguments: StatementArguments(values))
    }

    /// Takes back everything a reading of a document gave it, as when its file changed after it was read and it is read
    /// again as a new arrival: the model's labels (its tags, the user's, stay), what the model said of it, its stored
    /// text and its entries in the full-text and meaning indexes, in one transaction. It is being processed again.
    public func forgetReading(docID: Int64) async throws {
        let now = time.now()
        try await database.writer.write { db in
            guard let document = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
            try Self.saveLabels(db, (document.labels ?? []).filter(\.kind.isUsersOwn), docID: docID, labelled: false, at: now)
            try db.execute(sql: """
                UPDATE documents SET analysis_json = NULL, content_json = NULL, page_count = NULL, extracted_at = NULL,
                embedded_at = NULL, status = ?, updated_at = ? WHERE id = ?
                """, arguments: [DocumentStatus.processing.rawValue, now.unixSeconds, docID])
            try db.execute(sql: "DELETE FROM document_text WHERE doc_id = ?", arguments: [docID])
            try db.execute(sql: "DELETE FROM embeddings WHERE doc_id = ?", arguments: [docID])
        }
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
        let now = time.now()
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM embeddings WHERE doc_id = ? AND model = ?", arguments: [docID, model])
            var e = EmbeddingRecord(id: nil, docId: docID, chunkIndex: 0, model: model, dim: vector.count,
                                    vector: VectorCodec.encode(vector), textHash: hash, createdAt: now)
            try e.insert(db)
            try db.execute(sql: "UPDATE documents SET embedded_at = ? WHERE id = ?", arguments: [now.unixSeconds, docID])
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
