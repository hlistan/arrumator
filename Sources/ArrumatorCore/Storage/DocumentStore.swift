import Foundation
import GRDB

public struct DocumentFilter: Sendable, Hashable {
    public var statuses: Set<DocumentStatus>?
    /// Documents that have every one of these labels, each written however the archive writes it
    /// (`LabelSimilarity.sameWriting`): the scope the sidebar's labels narrow down to.
    public var labels: [DocumentLabel]
    /// Documents whose file is in this folder, at any depth: in the archive, given its root, as the index records the
    /// paths of its documents (`PipelineServices.archive`). A document left in Incoming has a status of one in the archive
    /// (failed, held) but is none.
    public var within: URL?

    public init(statuses: Set<DocumentStatus>? = nil, labels: [DocumentLabel] = [], within: URL? = nil) {
        self.statuses = statuses
        self.labels = labels
        self.within = within
    }

    /// The condition that a document's path, `d.path`, is below `folder` as any of its spellings writes it
    /// (`URL.spellings`): a range of the paths that begin with a spelling and a separator for each, the separator
    /// followed by `0` in UTF-8, the order SQLite compares text in. Narrows a query to what `URL.holds` then decides.
    static func pathCondition(within folder: URL) -> (String, StatementArguments) {
        let spellings = folder.spellings
        var args = StatementArguments()
        for root in spellings { args += [root + "/", root + Self.afterSeparator] }
        return (" AND (" + Array(repeating: "(d.path >= ? AND d.path < ?)", count: spellings.count).joined(separator: " OR ") + ")", args)
    }

    /// The character that follows the path separator, `/`, in UTF-8.
    static let afterSeparator = "0"

    /// The filter as conditions on `documents d`, each opening with AND, for every query that lists documents: the
    /// document store's, the label store's and search's. A label is matched against the archive's writings of it, so
    /// `sender=edp` finds the documents labelled `EDP`, and a label no document has matches none.
    func sql(_ db: Database) throws -> (String, StatementArguments) {
        var sql = ""
        var args = StatementArguments()
        if let statuses {
            sql += " AND d.status IN (\(Self.placeholders(statuses.count)))"
            args += StatementArguments(statuses.map(\.rawValue).sorted())
        }
        if let within {
            let (condition, values) = Self.pathCondition(within: within)
            sql += condition
            args += values
        }
        for label in labels {
            let writings = try String.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(l.value, '$.value') FROM documents d, json_each(d.labels_json) l
                WHERE d.labels_json IS NOT NULL AND json_extract(l.value, '$.kind') = ?
                """, arguments: [label.kind.rawValue]).filter { LabelSimilarity.sameWriting($0, label.value) }
            guard !writings.isEmpty else { return (" AND 0", []) }
            sql += """
                 AND EXISTS (SELECT 1 FROM json_each(d.labels_json) s WHERE json_extract(s.value, '$.kind') = ? \
                AND json_extract(s.value, '$.value') IN (\(Self.placeholders(writings.count))))
                """
            args += [label.kind.rawValue]
            args += StatementArguments(writings)
        }
        return (sql, args)
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

/// The orders documents are listed in. The logs (Incoming, Needs You, Processed) follow when something happened to a
/// document, the latest first; the documents a person looks for, those the sidebar's labels choose and a search task's,
/// follow their own date (`documentDate`).
public enum DocumentOrder: String, Sendable, CaseIterable {
    case recentlyAdded, recentlyFiled, recentlyProcessed
    /// By the document's own date (`DocumentRecord.documentDate`, the day it was issued), the newest first and the
    /// undated last; documents of one date by file name as Finder sorts names, then by number. Every document has a
    /// place of its own in it, so a longer list in this order starts as a shorter one does: loading a page more never
    /// skips or repeats a document. `byDocumentDate` is the same order over documents in memory.
    case documentDate

    /// The order over `documents d`.
    var sql: String {
        switch self {
        case .recentlyAdded: "d.added_at DESC"
        /// When the pipeline finished with it: filed documents by filing time, the rest by arrival.
        case .recentlyProcessed: "COALESCE(d.filed_at, d.added_at) DESC"
        case .recentlyFiled: "d.filed_at DESC"
        case .documentDate: "\(Self.dateSQL) DESC NULLS LAST, \(Self.fileNameSQL) COLLATE \(DatabaseCollation.localizedStandardCompare.name), d.id"
        }
    }

    /// A document's `date` label, as `DocumentFilter` reads a label of a kind out of `labels_json`; NULL without one.
    private static let dateSQL = """
        (SELECT json_extract(l.value, '$.value') FROM json_each(d.labels_json) l \
        WHERE json_extract(l.value, '$.kind') = '\(LabelKind.date.rawValue)' LIMIT 1)
        """

    /// A document's file name (`DocumentRecord.filename`): its path after the last `/`. Trimming every character other
    /// than `/` off the end of the path leaves its folder, and the name starts right after that.
    private static let fileNameSQL = "substr(d.path, length(rtrim(d.path, replace(d.path, '/', ''))) + 1)"

    /// `documentDate` over documents already in memory, such as a search task's set: the order the index gives them in.
    /// Names compare as the index's collation compares them (`localizedStandardCompare`).
    static func byDocumentDate(_ documents: [DocumentRecord]) -> [DocumentRecord] {
        documents.map { (document: $0, date: $0.documentDate) }.sorted { a, b in
            if a.date != b.date {
                guard let x = a.date else { return false }
                guard let y = b.date else { return true }
                return x > y
            }
            switch a.document.filename.localizedStandardCompare(b.document.filename) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return (a.document.id ?? 0) < (b.document.id ?? 0)
            }
        }.map(\.document)
    }
}

public struct DocumentStore: Sendable {
    public let database: AppDatabase
    public let time: any TimeSource

    public init(database: AppDatabase, time: any TimeSource) {
        self.database = database
        self.time = time
    }

    public func document(id: Int64) async throws -> DocumentRecord? {
        try await database.reader.read { db in try DocumentRecord.fetchOne(db, key: id) }
    }

    /// The documents with these numbers that the index has, in this order.
    public func documents(ids: [Int64]) async throws -> [DocumentRecord] {
        try await database.reader.read { db in try Self.documents(db, ids: ids) }
    }

    static func documents(_ db: Database, ids: [Int64]) throws -> [DocumentRecord] {
        let byID = Dictionary(try DocumentRecord.fetchAll(db, keys: ids).compactMap { d in d.id.map { ($0, d) } }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    public func document(path: String) async throws -> DocumentRecord? {
        try await database.reader.read { db in
            try DocumentRecord.filter(Column("path") == path).order(Column("id").desc).fetchOne(db)
        }
    }

    public func document(uid: String) async throws -> DocumentRecord? {
        try await database.reader.read { db in try DocumentRecord.filter(Column("uid") == uid).fetchOne(db) }
    }

    /// The oldest document in the archive at `archive` as itself (`DocumentStatus.inArchive`: filed, waiting for the
    /// user, parked after failing or left for later, and its file in the archive) recorded with this content hash, other
    /// than `id`: what an exact copy of it is a copy of. A copy an earlier version filed (`duplicate`) is none, and so is a
    /// document left in Incoming, as one the Trash would not take.
    public func existing(sha256: String, excluding id: Int64?, archive: URL) async throws -> DocumentRecord? {
        try await database.reader.read { db in
            let (within, args) = DocumentFilter.pathCondition(within: archive)
            let statuses = DocumentStatus.inArchive.map(\.rawValue).sorted()
            var sql = "SELECT d.* FROM documents d WHERE d.sha256 = ? AND d.status IN (\(databaseQuestionMarks(count: statuses.count)))\(within)"
            var arguments: StatementArguments = [sha256]
            arguments += StatementArguments(statuses)
            arguments += args
            if let id {
                sql += " AND d.id != ?"
                arguments += [id]
            }
            return try DocumentRecord.fetchAll(db, sql: sql + " ORDER BY d.id", arguments: arguments).first { archive.holds($0.path) }
        }
    }

    public func list(_ filter: DocumentFilter, order: DocumentOrder = .recentlyAdded, limit: Int) async throws -> [DocumentRecord] {
        try await database.reader.read { db in
            let (conditions, args) = try filter.sql(db)
            return try DocumentRecord.fetchAll(db, sql: "SELECT d.* FROM documents d WHERE 1=1\(conditions) ORDER BY \(order.sql) LIMIT ?",
                                               arguments: args + [limit])
        }
    }

    /// The statuses of a document that waits for the user.
    private static var reviewable: Set<DocumentStatus> { Set(DocumentStatus.allCases.filter(\.isReviewable)) }

    /// Every document waiting for the user, newest first.
    public func reviewQueue() async throws -> [DocumentRecord] {
        try await database.reader.read { db in
            let (conditions, args) = try DocumentFilter(statuses: Self.reviewable).sql(db)
            return try DocumentRecord.fetchAll(db, sql: "SELECT d.* FROM documents d WHERE 1=1\(conditions) ORDER BY \(DocumentOrder.recentlyAdded.sql)",
                                               arguments: args)
        }
    }

    /// How many documents wait for the user: what the sidebar counts.
    public func reviewCount() async throws -> Int {
        try await database.reader.read { db in
            try DocumentRecord.filter(Self.reviewable.map(\.rawValue).contains(Column("status"))).fetchCount(db)
        }
    }

    /// Documents the model has not labelled yet whose text was read, oldest first: those filed before documents were
    /// labelled, and those it gave no valid answer for, with no labels or with only their tags (`isLabelled`).
    public func unlabelled() async throws -> [Int64] {
        try await database.reader.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM documents WHERE \(Self.notLabelledSQL) AND content_json IS NOT NULL ORDER BY id")
        }
    }

    /// A document of `documents` the model has not labelled yet (`DocumentRecord.isLabelled`), as a condition.
    static let notLabelledSQL = "(labels_json IS NULL OR tags_only)"

    @discardableResult
    public func save(_ document: DocumentRecord) async throws -> DocumentRecord {
        let now = time.now()
        return try await database.writer.write { db in
            var d = document
            d.updatedAt = now
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
