import Foundation
import GRDB

/// Shared GRDB conventions: snake_case columns, dates as Unix seconds (REAL).
public protocol ArrumatorRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {}

extension ArrumatorRecord {
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
}

extension Date {
    /// The representation every date column uses, as declared by ``ArrumatorRecord``. SQL comparisons and raw
    /// statement arguments must bind this: GRDB encodes a bare `Date` as text, which never compares correctly
    /// against a REAL column.
    public var unixSeconds: Double { timeIntervalSince1970 }

    public init(unixSeconds: Double) { self.init(timeIntervalSince1970: unixSeconds) }
}

public enum DocumentStatus: String, Sendable, Codable, CaseIterable {
    case arrived, processing, filed, needsReview, failed, duplicate, undone, held, missing

    public var isReviewable: Bool { [.needsReview, .failed, .held, .undone].contains(self) }

    /// Statuses of documents the pipeline has finished with, whatever the outcome.
    public static let processed: Set<DocumentStatus> = [.filed, .needsReview, .failed, .duplicate, .undone, .held]
}

public struct DocumentRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "documents"
    public var id: Int64?
    public var uid: String
    public var path: String
    public var originalFilename: String
    public var sha256: String
    public var size: Int64
    public var uttype: String
    public var inode: Int64?
    public var correspondentId: Int64?
    public var correspondent: String?
    public var docType: String?
    public var docDate: String?
    public var periodYear: Int?
    public var title: String?
    public var language: String?
    public var pageCount: Int?
    public var status: DocumentStatus
    /// What the model read the document as (`DocumentAnalysis`) as JSON, with the user's corrections; NULL before.
    public var analysisJson: String?
    public var contentJson: String?
    /// The document's labels as JSON; NULL until the model has labelled it.
    public var labelsJson: String?
    public var duplicateOf: Int64?
    public var lastTraceId: Int64?
    public var addedAt: Date
    public var filedAt: Date?
    public var extractedAt: Date?
    public var embeddedAt: Date?
    public var fileMtime: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// A newly arrived file, before extraction and classification.
    public static func arrived(path: String, sha256: String, size: Int64, uttype: String, inode: Int64?, modified: Date?,
                               now: Date = Date()) -> DocumentRecord {
        DocumentRecord(id: nil, uid: UUID().uuidString, path: path, originalFilename: (path as NSString).lastPathComponent,
                       sha256: sha256, size: size, uttype: uttype, inode: inode, correspondentId: nil,
                       correspondent: nil, docType: nil, docDate: nil, periodYear: nil, title: nil, language: nil, pageCount: nil,
                       status: .processing, analysisJson: nil, contentJson: nil, labelsJson: nil, duplicateOf: nil, lastTraceId: nil,
                       addedAt: now, filedAt: nil,
                       extractedAt: nil, embeddedAt: nil, fileMtime: modified, createdAt: now, updatedAt: now)
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var filename: String { (path as NSString).lastPathComponent }
    public var analysis: DocumentAnalysis? { JSON.decode(DocumentAnalysis.self, from: analysisJson) }
    /// Nil until the model has labelled the document; empty when it found nothing worth a label.
    public var labels: [DocumentLabel]? { JSON.decode([DocumentLabel].self, from: labelsJson) }
}

public struct DocumentTextRecord: ArrumatorRecord, PersistableRecord, Hashable {
    public static let databaseTableName = "document_text"
    public var docId: Int64
    public var title: String
    public var correspondent: String
    public var filename: String
    public var body: String
    public var summary: String?
    public var metadataJson: String?
    public var extractorVersion: String?
    /// The document's labels of each `LabelKind`, as `DocumentLabel.searchText` writes them.
    public var subject: String
    public var object: String
    public var jurisdiction: String
    public var language: String
}

public struct EmbeddingRecord: ArrumatorRecord {
    public static let databaseTableName = "embeddings"
    public var id: Int64?
    public var docId: Int64
    public var chunkIndex: Int
    public var model: String
    public var dim: Int
    public var vector: Data
    public var textHash: String
    public var createdAt: Date
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum EventKind: String, Sendable, Codable, CaseIterable {
    case arrived, extracted, analysed, filed, needsReview, duplicate, error, retry, failed
    /// The user changed a document's name, sender, date or type.
    case corrected
    case undone, markedCorrect, userMoved, userRenamed, missing, adopted
    case learned, forgot
    case settingsChanged, ollamaState, appStarted, paused, resumed
    /// The index was rebuilt from the archive's record files.
    case rebuilt
}

public enum EventActor: String, Sendable, Codable {
    case system, user
}

public struct EventRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "events"
    public var id: Int64?
    public var at: Date
    public var docId: Int64?
    public var jobId: Int64?
    public var traceId: Int64?
    public var kind: EventKind
    public var actor: EventActor
    public var summary: String
    public var payloadJson: String
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct CorrespondentRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "correspondents"
    public var id: Int64?
    public var canonicalName: String
    public var country: String?
    public var aliasesJson: String
    public var stableKeysJson: String
    public var emailDomainsJson: String
    public var webDomainsJson: String
    public var filedCount: Int
    public var origin: String
    public var createdAt: Date
    public var updatedAt: Date
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var correspondent: Correspondent {
        Correspondent(id: id ?? 0, canonicalName: canonicalName, country: country,
                      aliases: JSON.decode([String].self, from: aliasesJson) ?? [],
                      stableKeys: JSON.decode([String].self, from: stableKeysJson) ?? [],
                      emailDomains: JSON.decode([String].self, from: emailDomainsJson) ?? [],
                      webDomains: JSON.decode([String].self, from: webDomainsJson) ?? [],
                      filedCount: filedCount,
                      origin: CorrespondentOrigin(rawValue: origin) ?? .learned)
    }

    public init(_ c: Correspondent, now: Date = Date()) {
        id = c.id == 0 ? nil : c.id
        canonicalName = c.canonicalName
        country = c.country
        aliasesJson = JSON.string(c.aliases)
        stableKeysJson = JSON.string(c.stableKeys)
        emailDomainsJson = JSON.string(c.emailDomains)
        webDomainsJson = JSON.string(c.webDomains)
        filedCount = c.filedCount
        origin = c.origin.rawValue
        createdAt = now
        updatedAt = now
    }
}

public enum JobState: String, Sendable, Codable, CaseIterable {
    case pending, hashing, extracting, analysing, filing, done, duplicate, needsReview, failed, held, cancelled

    public var isActive: Bool { [.pending, .hashing, .extracting, .analysing, .filing].contains(self) }
}

public enum JobKind: String, Sendable, Codable {
    case ingest, adopt
    /// Read a stored document again with the model and file it under the name it gives, where it is.
    case reanalyse
    /// Read a filed document's text and compute its embedding again, without asking the model or moving anything:
    /// what a rebuilt index needs for search.
    case reindex
}

public struct JobRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "jobs"
    public var id: Int64?
    public var kind: JobKind
    public var docId: Int64?
    public var sourcePath: String
    public var state: JobState
    public var attempt: Int
    public var nextRunAt: Date?
    public var lastError: String?
    public var payloadJson: String
    public var createdAt: Date
    public var updatedAt: Date
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct TraceRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "traces"
    public var id: Int64?
    public var docId: Int64?
    public var jobId: Int64?
    public var attempt: Int
    public var source: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: String?
    public var appVersion: String
    public var promptVersion: Int
    public var modelChat: String?
    public var modelVision: String?
    public var modelEmbed: String?
    public var settingsJson: String
    public var totalMs: Double?
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct TraceStepRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "trace_steps"
    public var id: Int64?
    public var traceId: Int64
    public var seq: Int
    public var stage: String
    public var status: String
    public var startedAt: Date
    public var durationMs: Double
    public var inputJson: String?
    public var outputJson: String?
    public var error: String?
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum VectorCodec {
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}
