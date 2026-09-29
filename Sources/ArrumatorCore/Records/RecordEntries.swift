import Foundation

/// The version stamped at the top of every record file, so a future format can tell old files apart.
public enum RecordSchema {
    public static let version = 1
}

/// One document, as the `_documents.md` of its directory records it. The file is named, not located: the entry
/// sits next to the document, so moving or renaming the directory never touches it.
public struct DocumentEntry: Codable, Sendable, Hashable {
    public var id: Int64
    public var uid: String
    public var file: String
    public var originalName: String
    public var sha256: String
    public var size: Int64
    public var contentType: String
    public var status: DocumentStatus
    public var sender: String?
    public var senderId: Int64?
    public var documentType: String?
    public var date: String?
    public var periodYear: Int?
    public var title: String?
    public var language: String?
    public var pages: Int?
    /// Absent until the model has labelled the document.
    public var labels: [DocumentLabel]?
    public var duplicateOf: Int64?
    /// What the model read the document as, with the user's corrections.
    public var analysis: DocumentAnalysis?
    public var added: Date
    public var filed: Date?

    /// In the order a person reads an entry, with the full analysis last.
    enum CodingKeys: String, CodingKey {
        case id, uid, file
        case originalName = "original_name"
        case added, filed, status, sender
        case senderId = "sender_id"
        case documentType = "document_type"
        case date
        case periodYear = "period_year"
        case title, language, pages, labels
        case duplicateOf = "duplicate_of"
        case contentType = "content_type"
        case size, sha256, analysis
    }

    public init?(_ record: DocumentRecord) {
        guard let id = record.id else { return nil }
        self.id = id
        uid = record.uid
        file = record.filename
        originalName = record.originalFilename
        sha256 = record.sha256
        size = record.size
        contentType = record.uttype
        status = record.status
        sender = record.correspondent
        senderId = record.correspondentId
        documentType = record.docType
        date = record.docDate
        periodYear = record.periodYear
        title = record.title
        language = record.language
        pages = record.pageCount
        labels = record.labels
        duplicateOf = record.duplicateOf
        analysis = record.analysis
        added = record.addedAt
        filed = record.filedAt
    }

    /// The index row for this entry in `directory`. What the index caches about the file (its text, inode, times of
    /// extraction) starts empty and is filled in again when the document is read.
    public func record(directory: URL, now: Date = Date()) -> DocumentRecord {
        DocumentRecord(id: id, uid: uid, path: directory.appendingPathComponent(file).path, originalFilename: originalName,
                       sha256: sha256, size: size, uttype: contentType, inode: nil, correspondentId: senderId,
                       correspondent: sender, docType: documentType, docDate: date, periodYear: periodYear, title: title,
                       language: language, pageCount: pages, status: status, analysisJson: analysis.map { JSON.string($0) },
                       contentJson: nil, labelsJson: labels.map { JSON.string($0) }, duplicateOf: duplicateOf, lastTraceId: nil,
                       addedAt: added, filedAt: filed, extractedAt: nil, embeddedAt: nil, fileMtime: nil, createdAt: added, updatedAt: now)
    }
}

/// One event as a history file records it. The job and trace it pointed at are the index's own and are not kept.
public struct EventEntry: Codable, Sendable, Hashable {
    public var id: Int64
    public var at: Date
    public var kind: EventKind
    public var actor: EventActor
    public var document: Int64?
    public var summary: String
    public var payload: String

    public init?(_ record: EventRecord) {
        guard let id = record.id else { return nil }
        self.id = id
        at = record.at
        kind = record.kind
        actor = record.actor
        document = record.docId
        summary = record.summary
        payload = record.payloadJson
    }

    public var record: EventRecord {
        EventRecord(id: id, at: at, docId: document, jobId: nil, traceId: nil, kind: kind, actor: actor, summary: summary,
                    payloadJson: payload)
    }
}

/// The front matter of a file holding a list.
struct RecordList<Entry: Codable & Sendable>: Codable, Sendable {
    var arrumator: Int
    var entries: [Entry]

    init(_ entries: [Entry]) {
        arrumator = RecordSchema.version
        self.entries = entries
    }
}
