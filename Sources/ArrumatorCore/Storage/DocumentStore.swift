import Foundation
import GRDB

public struct DocumentFilter: Sendable, Hashable {
    public var folderIDs: Set<Int64>?
    public var statuses: Set<DocumentStatus>?
    public var docTypes: Set<String>?
    public var correspondents: Set<String>?
    public var languages: Set<String>?
    public var dateFrom: String?
    public var dateTo: String?

    public init(folderIDs: Set<Int64>? = nil, statuses: Set<DocumentStatus>? = nil, docTypes: Set<String>? = nil,
                correspondents: Set<String>? = nil, languages: Set<String>? = nil, dateFrom: String? = nil, dateTo: String? = nil) {
        self.folderIDs = folderIDs
        self.statuses = statuses
        self.docTypes = docTypes
        self.correspondents = correspondents
        self.languages = languages
        self.dateFrom = dateFrom
        self.dateTo = dateTo
    }

    func apply(_ request: QueryInterfaceRequest<DocumentRecord>) -> QueryInterfaceRequest<DocumentRecord> {
        var r = request
        if let folderIDs { r = r.filter(folderIDs.contains(Column("folder_id"))) }
        if let statuses { r = r.filter(statuses.map(\.rawValue).contains(Column("status"))) }
        if let docTypes { r = r.filter(docTypes.contains(Column("doc_type"))) }
        if let correspondents { r = r.filter(correspondents.contains(Column("correspondent"))) }
        if let languages { r = r.filter(languages.contains(Column("language"))) }
        if let dateFrom { r = r.filter(Column("doc_date") >= dateFrom) }
        if let dateTo { r = r.filter(Column("doc_date") <= dateTo) }
        return r
    }
}

public enum DocumentOrder: String, Sendable, CaseIterable {
    case recentlyAdded, recentlyFiled, recentlyProcessed, documentDate, title, correspondent

    var terms: [any SQLOrderingTerm] {
        switch self {
        case .recentlyAdded: [Column("added_at").desc]
        /// When the pipeline finished with it: filed documents by filing time, the rest by arrival.
        case .recentlyProcessed: [(Column("filed_at") ?? Column("added_at")).desc]
        case .recentlyFiled: [Column("filed_at").desc]
        case .documentDate: [Column("doc_date").desc, Column("added_at").desc]
        case .title: [Column("title").collating(.localizedCaseInsensitiveCompare)]
        case .correspondent: [Column("correspondent").collating(.localizedCaseInsensitiveCompare), Column("doc_date").desc]
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

    public func countsByFolder() async throws -> [Int64: Int] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT folder_id, COUNT(*) AS n FROM documents
                WHERE folder_id IS NOT NULL AND status IN ('filed','needsReview','duplicate') GROUP BY folder_id
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["folder_id"] as Int64, $0["n"] as Int) })
        }
    }

    /// The senders of the documents filed in each folder, by the folder's id.
    public func sendersByFolder() async throws -> [Int64: Set<Int64>] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT folder_id, correspondent_id FROM documents
                WHERE folder_id IS NOT NULL AND correspondent_id IS NOT NULL AND status = ?
                """, arguments: [DocumentStatus.filed.rawValue])
            return rows.reduce(into: [Int64: Set<Int64>]()) { $0[$1["folder_id"], default: []].insert($1["correspondent_id"]) }
        }
    }

    /// The types of the documents filed in each folder, by the folder's id.
    public func typesByFolder() async throws -> [Int64: Set<DocumentType>] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT folder_id, doc_type FROM documents
                WHERE folder_id IS NOT NULL AND doc_type IS NOT NULL AND status = ?
                """, arguments: [DocumentStatus.filed.rawValue])
            return rows.reduce(into: [Int64: Set<DocumentType>]()) { out, row in
                if let type = DocumentType(rawValue: row["doc_type"]) { out[row["folder_id"], default: []].insert(type) }
            }
        }
    }

    public func recentTitles(perFolder limit: Int) async throws -> [Int64: [String]] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT folder_id, path FROM (
                  SELECT folder_id, path, ROW_NUMBER() OVER (PARTITION BY folder_id ORDER BY filed_at DESC) AS rn
                  FROM documents WHERE status = 'filed' AND folder_id IS NOT NULL)
                WHERE rn <= ?
                """, arguments: [limit])
            var out: [Int64: [String]] = [:]
            for row in rows {
                out[row["folder_id"], default: []].append(((row["path"] as String) as NSString).lastPathComponent)
            }
            return out
        }
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
