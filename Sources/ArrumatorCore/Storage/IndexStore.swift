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
        try await database.writer.write { db in
            try Self.writeText(db, docID: docID, filename: filename, body: body, summary: summary, metadata: metadata,
                               extractorVersion: extractorVersion, labels: labels)
        }
    }

    /// `upsertText`, in a transaction of the caller's. What the model read the document as is what its row holds as the
    /// transaction writes this (`DocumentAnalysis.interpretation`), which a trigger keeps it equal to from then on
    /// (`AppDatabase.sidecarsMigration`).
    static func writeText(_ db: Database, docID: Int64, filename: String, body: String, summary: String?, metadata: [String: String],
                          extractorVersion: String, labels: [DocumentLabel]) throws {
        let kinds = LabelKind.allCases.map(\.rawValue)
        let columns = ["doc_id", "filename", "body", "summary", "metadata_json", "extractor_version"] + kinds
        let values: [(any DatabaseValueConvertible)?] = [docID, filename, body, summary, try JSON.string(metadata), extractorVersion]
            + LabelKind.allCases.map { DocumentLabel.searchText(labels, kind: $0) } + [docID]
        let interpretation = SearchService.interpretationColumn
        try db.execute(sql: """
            INSERT INTO document_text (\(columns.joined(separator: ", ")), \(interpretation))
            VALUES (\(databaseQuestionMarks(count: columns.count)), \(Self.interpretationOfDocument))
            ON CONFLICT(doc_id) DO UPDATE SET \((columns.dropFirst() + [interpretation]).map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
            """, arguments: StatementArguments(values))
    }

    /// What the model read the document whose number is the statement's argument as, from its analysis; empty when it
    /// has none.
    static let interpretationOfDocument = """
        COALESCE((SELECT CASE WHEN json_valid(analysis_json) THEN json_extract(analysis_json, '$.interpretation') END
                  FROM documents WHERE id = ?), '')
        """

    /// Saves what the model read of a document, `read`, where the user has not changed it since the reading began: the
    /// labels the document had then, `before`, are compared kind by kind with those it has when it is saved, read in the
    /// same transaction, and a kind the user changed meanwhile, as a sender corrected or a tag given or taken away, stays
    /// as the user left it. The user's own labels (tags) are always as the document has them. The reading fills in the
    /// rest. The labels saved.
    @discardableResult
    public func saveReading(_ read: [DocumentLabel], before: [DocumentLabel], docID: Int64) async throws -> [DocumentLabel] {
        let now = time.now()
        return try await database.writer.write { db in
            guard let document = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
            let labels = Self.kept(read, before: before, current: document.labels ?? [])
            try Self.saveLabels(db, labels, docID: docID, labelled: true, at: now)
            return labels
        }
    }

    /// The labels a reading leaves a document: those it read, `read`, but of the kinds the user changed since it began,
    /// the labels it had then, `before`, compared kind by kind with those it has now, `current`, and of the user's own
    /// (tags), which stay as the document has them now.
    static func kept(_ read: [DocumentLabel], before: [DocumentLabel], current: [DocumentLabel]) -> [DocumentLabel] {
        let ofKind = { (labels: [DocumentLabel], kind: LabelKind) in Set(labels.filter { $0.kind == kind }) }
        let users = Set(LabelKind.allCases.filter { $0.isUsersOwn || ofKind(before, $0) != ofKind(current, $0) })
        return (read.filter { !users.contains($0.kind) } + current.filter { users.contains($0.kind) }).distinct()
    }

    /// Puts what reading a document again gave it in the place of everything an earlier reading had, in the transaction
    /// of `db` that records its filing (`IngestCoordinator`), so the index holds one reading of it or the other, never
    /// parts of both, and a document read again is found as it was until then. Its labels are those the reading gave,
    /// `read`, but of the kinds the user changed since it was asked for and of the user's own (`kept`); a reading that
    /// gave none, as when the model gave no valid answer, made none to put in their place, and the document keeps those
    /// it had, as it keeps its embeddings when none was made. Its text
    /// and what it was read from are `content`; its row of the full-text index is deleted and written again, under
    /// `filename`; and every embedding it had, of whatever model, is deleted, `embedding` taking their place. A reading
    /// that made no embedding, as when the embedding model failed, leaves it those it had: search by meaning finds it as
    /// before rather than not at all. The labels saved.
    static func replaceReading(_ db: Database, docID: Int64, filename: String, content: ExtractedContent, read: [DocumentLabel]?,
                               before: [DocumentLabel], embedding: TextEmbedding?, at now: Date) throws -> [DocumentLabel] {
        guard let document = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
        let current = document.labels ?? []
        let labels = read.map { kept($0, before: before, current: current) } ?? current
        try db.execute(sql: "DELETE FROM document_text WHERE doc_id = ?", arguments: [docID])
        try writeText(db, docID: docID, filename: filename, body: content.text, summary: content.visual?.description,
                      metadata: content.metadata, extractorVersion: content.extractedBy, labels: labels)
        try saveLabels(db, labels, docID: docID, labelled: read != nil || document.isLabelled, at: now)
        try db.execute(sql: "UPDATE documents SET content_json = ?, page_count = ?, extracted_at = ? WHERE id = ?",
                       arguments: [try DocumentStore.storedContentJSON(content), content.pageCount, now.unixSeconds, docID])
        if let embedding {
            try db.execute(sql: "DELETE FROM embeddings WHERE doc_id = ?", arguments: [docID])
            try writeEmbedding(db, docID: docID, embedding, at: now)
        }
        return labels
    }

    /// Adds `added` to a document's labels, those it has not already, as they are when the transaction reads them, so
    /// a change made meanwhile is kept.
    public func addLabels(_ added: [DocumentLabel], docID: Int64) async throws {
        let now = time.now()
        try await database.writer.write { db in
            guard let document = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
            let current = document.labels ?? []
            let new = added.filter { !current.contains($0) }
            guard !new.isEmpty else { return }
            try Self.saveLabels(db, current + new, docID: docID, labelled: document.isLabelled, at: now)
        }
    }

    /// Makes a document's labels its own, inside a transaction of the caller's that reads what it changes: on its row,
    /// which writes them into its record file, and in the full-text index. `labelled` says whether they label it, as when
    /// the model read it; a document's tags alone do not (`DocumentLabel.stored`).
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
            try Self.forgetReading(db, of: document, at: now)
        }
    }

    /// `forgetReading`, of `document` as the caller's transaction read it.
    static func forgetReading(_ db: Database, of document: DocumentRecord, at now: Date) throws {
        guard let docID = document.id else { throw IngestError.documentNotPersisted }
        try saveLabels(db, (document.labels ?? []).filter(\.kind.isUsersOwn), docID: docID, labelled: false, at: now)
        try db.execute(sql: """
            UPDATE documents SET analysis_json = NULL, content_json = NULL, page_count = NULL, extracted_at = NULL,
            embedded_at = NULL, status = ?, updated_at = ? WHERE id = ?
            """, arguments: [DocumentStatus.processing.rawValue, now.unixSeconds, docID])
        try db.execute(sql: "DELETE FROM document_text WHERE doc_id = ?", arguments: [docID])
        try db.execute(sql: "DELETE FROM embeddings WHERE doc_id = ?", arguments: [docID])
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
        let now = time.now()
        try await database.writer.write { db in
            try Self.writeEmbedding(db, docID: docID, TextEmbedding(model: model, vector: vector, sourceText: sourceText), at: now)
        }
    }

    /// `upsertEmbedding`, in a transaction of the caller's: the document's embedding of `embedding.model` takes the place
    /// of the one it had of that model.
    static func writeEmbedding(_ db: Database, docID: Int64, _ embedding: TextEmbedding, at now: Date) throws {
        let hash = SHA256.hash(data: Data(embedding.sourceText.utf8)).map { String(format: "%02x", $0) }.joined()
        try db.execute(sql: "DELETE FROM embeddings WHERE doc_id = ? AND model = ?", arguments: [docID, embedding.model])
        var e = EmbeddingRecord(id: nil, docId: docID, chunkIndex: 0, model: embedding.model, dim: embedding.vector.count,
                                vector: VectorCodec.encode(embedding.vector), textHash: hash, createdAt: now)
        try e.insert(db)
        try db.execute(sql: "UPDATE documents SET embedded_at = ? WHERE id = ?", arguments: [now.unixSeconds, docID])
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

/// A document's meaning as an embedding model gives it: the model, its vector, and the text it was made of.
public struct TextEmbedding: Sendable, Hashable {
    public var model: String
    public var vector: [Float]
    public var sourceText: String

    public init(model: String, vector: [Float], sourceText: String) {
        self.model = model
        self.vector = vector
        self.sourceText = sourceText
    }
}

extension ExtractedContent {
    /// What read the text, as the full-text index keeps it: the extractor and its version.
    var extractedBy: String { "\(extractorName)/\(extractorVersion)" }
}
