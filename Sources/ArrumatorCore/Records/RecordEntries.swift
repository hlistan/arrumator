import Foundation

/// The version stamped at the top of every record file, so a future format can tell old files apart.
public enum RecordSchema {
    public static let version = 1
}

/// One document, as the `_documents.md` of its directory records it. The file is named, not located: the entry
/// sits next to the document, so renaming or moving a folder never touches it. Folders are known by their code
/// elsewhere in the records and by their place here; database folder numbers never appear.
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
    public var tags: [String]
    /// Absent until the model has labelled the document, as for one filed before documents were labelled.
    public var labels: [DocumentLabel]?
    public var duplicateOf: Int64?
    public var decidedBy: String?
    public var confidence: Double?
    public var band: String?
    public var rationale: String?
    public var decision: FilingDecision?
    public var added: Date
    public var filed: Date?

    /// In the order a person reads an entry, with the full decision last.
    enum CodingKeys: String, CodingKey {
        case id, uid, file
        case originalName = "original_name"
        case added, filed, status, sender
        case senderId = "sender_id"
        case documentType = "document_type"
        case date
        case periodYear = "period_year"
        case title, language, pages, tags, labels
        case duplicateOf = "duplicate_of"
        case decidedBy = "decided_by"
        case confidence, band, rationale
        case contentType = "content_type"
        case size, sha256, decision
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
        tags = record.tags
        labels = record.labels
        duplicateOf = record.duplicateOf
        decidedBy = record.decidedBy
        confidence = record.confidence
        band = record.band
        rationale = record.rationale
        decision = record.decision
        added = record.addedAt
        filed = record.filedAt
    }

    /// The index row for this entry in `directory`, in `folderID`. What the index caches about the file (its text,
    /// inode, times of extraction) starts empty and is filled in again when the document is read.
    public func record(directory: URL, folderID: Int64?, now: Date = Date()) -> DocumentRecord {
        DocumentRecord(id: id, uid: uid, path: directory.appendingPathComponent(file).path, originalFilename: originalName,
                       sha256: sha256, size: size, uttype: contentType, inode: nil, folderId: folderID, correspondentId: senderId,
                       correspondent: sender, docType: documentType, docDate: date, periodYear: periodYear, title: title,
                       language: language, pageCount: pages, status: status, band: band, confidence: confidence,
                       decidedBy: decidedBy, rationale: rationale, decisionJson: decision.map { JSON.string($0) },
                       contentJson: nil, tagsJson: JSON.string(tags), labelsJson: labels.map { JSON.string($0) }, duplicateOf: duplicateOf,
                       lastTraceId: nil, addedAt: added,
                       filedAt: filed, extractedAt: nil, embeddedAt: nil, fileMtime: nil, createdAt: added, updatedAt: now)
    }
}

/// A correction as `_corrections.md` records it: folders by code, because folder numbers are the index's own.
public struct CorrectionEntry: Codable, Sendable, Hashable {
    public var id: Int64
    public var document: Int64
    public var at: Date
    public var source: String
    public var fromFolder: String?
    public var toFolder: String?
    public var fromName: String?
    public var toName: String?
    public var proposed: FilingDecision?
    public var edited: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, document, at, source, proposed, edited
        case fromFolder = "from_folder", toFolder = "to_folder", fromName = "from_name", toName = "to_name"
    }

    public init?(_ record: CorrectionRecord, folderCodes: [Int64: String]) {
        guard let id = record.id else { return nil }
        self.id = id
        document = record.docId
        at = record.at
        source = record.source
        fromFolder = record.fromFolderId.flatMap { folderCodes[$0] }
        toFolder = record.toFolderId.flatMap { folderCodes[$0] }
        fromName = record.fromFilename
        toName = record.toFilename
        proposed = JSON.decode(FilingDecision.self, from: record.proposedJson)
        edited = JSON.decode([String: String].self, from: record.editedFieldsJson)
    }

    public func record(folderIDs: [String: Int64]) -> CorrectionRecord {
        CorrectionRecord(id: id, docId: document, at: at, source: source, fromFolderId: fromFolder.flatMap { folderIDs[$0] },
                         toFolderId: toFolder.flatMap { folderIDs[$0] }, fromFilename: fromName, toFilename: toName,
                         proposedJson: proposed.map { JSON.string($0) }, editedFieldsJson: edited.map { JSON.string($0) },
                         traceId: nil)
    }
}

/// A filing memory without its vector, which is computed again from the document.
public struct MemoryEntry: Codable, Sendable, Hashable {
    public var id: Int64
    public var document: Int64
    public var folder: String
    public var summary: String
    public var senderId: Int64?
    public var documentType: String
    public var language: String
    public var identifiers: [String]
    public var weight: Double
    public var source: String
    public var orphaned: Bool
    public var created: Date

    enum CodingKeys: String, CodingKey {
        case id, document, folder, summary, language, identifiers, weight, source, orphaned, created
        case senderId = "sender_id", documentType = "document_type"
    }

    public init?(_ record: MemoryRecord) {
        guard let id = record.id else { return nil }
        self.id = id
        document = record.docId
        folder = record.folderCode
        summary = record.summaryLine
        senderId = record.correspondentId
        documentType = record.docType
        language = record.language
        identifiers = JSON.decode([String].self, from: record.stableKeysJson) ?? []
        weight = record.weight
        source = record.source
        orphaned = record.orphaned
        created = record.createdAt
    }

    /// The index row, with no vector yet: it is filled in when the document is read again, and until then the
    /// memory is not offered as a similar past filing.
    public func record(folderID: Int64) -> MemoryRecord {
        MemoryRecord(id: id, docId: document, folderId: folderID, folderCode: folder, embedding: Data(), model: "",
                     summaryLine: summary, correspondentId: senderId, docType: documentType, language: language,
                     stableKeysJson: JSON.string(identifiers), weight: weight, source: source, orphaned: orphaned, createdAt: created)
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

/// The front matter of the archive's logic file; the prompt itself is the file's body. A file written by hand may be
/// the prompt alone, which is logic the user wrote.
public struct LogicEntry: Codable, Sendable, Hashable {
    public var arrumator: Int
    /// `LogicRecord.builtinHash`.
    public var builtin: String?

    public init(_ record: LogicRecord) {
        arrumator = RecordSchema.version
        builtin = record.builtinHash
    }

    public func record(body: String) -> LogicRecord { LogicRecord(body: body, builtinHash: builtin) }
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
