import Foundation
import GRDB

public struct DocumentFilter: Sendable, Hashable {
    public var statuses: Set<DocumentStatus>?

    public init(statuses: Set<DocumentStatus>? = nil) {
        self.statuses = statuses
    }

    func apply(_ request: QueryInterfaceRequest<DocumentRecord>) -> QueryInterfaceRequest<DocumentRecord> {
        guard let statuses else { return request }
        return request.filter(statuses.map(\.rawValue).contains(Column("status")))
    }
}

public enum DocumentOrder: String, Sendable, CaseIterable {
    case recentlyAdded, recentlyFiled, recentlyProcessed

    var terms: [any SQLOrderingTerm] {
        switch self {
        case .recentlyAdded: [Column("added_at").desc]
        /// When the pipeline finished with it: filed documents by filing time, the rest by arrival.
        case .recentlyProcessed: [(Column("filed_at") ?? Column("added_at")).desc]
        case .recentlyFiled: [Column("filed_at").desc]
        }
    }
}

public struct DocumentStore: Sendable {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func document(id: Int64) async throws -> DocumentRecord? {
        try await database.reader.read { db in try DocumentRecord.fetchOne(db, key: id) }
    }

    public func documents(ids: [Int64]) async throws -> [Int64: DocumentRecord] {
        try await database.reader.read { db in
            Dictionary(uniqueKeysWithValues: try DocumentRecord.fetchAll(db, keys: ids).compactMap { d in d.id.map { ($0, d) } })
        }
    }

    public func document(path: String) async throws -> DocumentRecord? {
        try await database.reader.read { db in
            try DocumentRecord.filter(Column("path") == path).order(Column("id").desc).fetchOne(db)
        }
    }

    public func document(uid: String) async throws -> DocumentRecord? {
        try await database.reader.read { db in try DocumentRecord.filter(Column("uid") == uid).fetchOne(db) }
    }

    /// An existing, still-present document with the same content hash.
    public func existing(sha256: String, excluding id: Int64?) async throws -> DocumentRecord? {
        try await database.reader.read { db in
            var r = DocumentRecord.filter(Column("sha256") == sha256)
                .filter([DocumentStatus.filed, .needsReview, .held].map(\.rawValue).contains(Column("status")))
            if let id { r = r.filter(Column("id") != id) }
            return try r.order(Column("id")).fetchOne(db)
        }
    }

    public func list(_ filter: DocumentFilter, order: DocumentOrder = .recentlyAdded, limit: Int) async throws -> [DocumentRecord] {
        try await database.reader.read { db in
            try filter.apply(DocumentRecord.all()).order(order.terms).limit(limit).fetchAll(db)
        }
    }

    public func reviewQueue() async throws -> [DocumentRecord] {
        try await list(DocumentFilter(statuses: Set(DocumentStatus.allCases.filter(\.isReviewable))), limit: 10_000)
    }

    /// Documents the model has not labelled yet whose text was read, oldest first: those filed before documents were
    /// labelled, and those it gave no valid answer for.
    public func unlabelled() async throws -> [Int64] {
        try await database.reader.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM documents WHERE labels_json IS NULL AND content_json IS NOT NULL ORDER BY id")
        }
    }

    @discardableResult
    public func save(_ document: DocumentRecord) async throws -> DocumentRecord {
        try await database.writer.write { db in
            var d = document
            d.updatedAt = Date()
            try d.save(db)
            return d
        }
    }
}

extension DocumentStore {
    /// Rebuilds the extracted content of a stored document (content JSON without text + indexed body).
    public func content(docID: Int64) async throws -> ExtractedContent? {
        try await database.reader.read { db in
            guard let doc = try DocumentRecord.fetchOne(db, key: docID),
                  var content = JSON.decode(ExtractedContent.self, from: doc.contentJson) else { return nil }
            content.text = try String.fetchOne(db, sql: "SELECT body FROM document_text WHERE doc_id = ?", arguments: [docID]) ?? ""
            content.source.path = doc.path
            return content
        }
    }

    /// Content JSON stored on the document row; the text lives in `document_text`.
    public static func storedContentJSON(_ content: ExtractedContent) -> String {
        var c = content
        c.text = ""
        return JSON.string(c)
    }
}
