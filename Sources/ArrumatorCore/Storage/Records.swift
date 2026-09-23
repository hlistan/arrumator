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

public struct FolderRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "folders"
    public var id: Int64?
    public var uid: String
    public var parentId: Int64?
    public var code: String
    public var name: String
    public var relPath: String
    public var kind: String
    public var role: String?
    public var autoFile: Bool
    public var yearSubfolders: Bool
    public var yearRule: String
    public var origin: String
    public var description: String
    public var aboutJson: String
    public var descriptionHash: String
    public var generatedHash: String?
    public var userEdited: Bool
    public var inode: Int64?
    public var sort: Int
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
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
    public var folderId: Int64?
    public var correspondentId: Int64?
    public var correspondent: String?
    public var docType: String?
    public var docDate: String?
    public var periodYear: Int?
    public var title: String?
    public var language: String?
    public var pageCount: Int?
    public var status: DocumentStatus
    public var band: String?
    public var confidence: Double?
    public var decidedBy: String?
    public var rationale: String?
    public var decisionJson: String?
    public var contentJson: String?
    public var tagsJson: String?
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
                       sha256: sha256, size: size, uttype: uttype, inode: inode, folderId: nil, correspondentId: nil,
                       correspondent: nil, docType: nil, docDate: nil, periodYear: nil, title: nil, language: nil, pageCount: nil,
                       status: .processing, band: nil, confidence: nil, decidedBy: nil, rationale: nil, decisionJson: nil,
                       contentJson: nil, tagsJson: nil, duplicateOf: nil, lastTraceId: nil, addedAt: now, filedAt: nil,
                       extractedAt: nil, embeddedAt: nil, fileMtime: modified, createdAt: now, updatedAt: now)
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var filename: String { (path as NSString).lastPathComponent }
    public var decision: FilingDecision? { JSON.decode(FilingDecision.self, from: decisionJson) }
    public var tags: [String] { JSON.decode([String].self, from: tagsJson) ?? [] }
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

public struct FolderEmbeddingRecord: ArrumatorRecord, PersistableRecord {
    public static let databaseTableName = "folder_embeddings"
    public var folderId: Int64
    public var model: String
    public var descriptionHash: String
    public var vector: Data
    public var createdAt: Date
}

public enum EventKind: String, Sendable, Codable, CaseIterable {
    case arrived, extracted, classified, filed, needsReview, duplicate, error, retry, failed
    case corrected, undone, refiled, markedCorrect, userMoved, userRenamed, missing, adopted
    case folderCreated, folderRenamed, folderRemoved, descriptionChanged
    case learned, ruleInduced, ruleDisabled, ruleChanged, proposalCreated, proposalResolved
    case logicChanged, rethink, rethought, forgot
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

public struct CorrectionRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "corrections"
    public var id: Int64?
    public var docId: Int64
    public var at: Date
    public var source: String
    public var fromFolderId: Int64?
    public var toFolderId: Int64?
    public var fromFilename: String?
    public var toFilename: String?
    public var proposedJson: String?
    public var editedFieldsJson: String?
    public var traceId: Int64?
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct MemoryRecord: ArrumatorRecord, Identifiable {
    public static let databaseTableName = "memories"
    public var id: Int64?
    public var docId: Int64
    public var folderId: Int64
    public var folderCode: String
    public var embedding: Data
    public var model: String
    public var summaryLine: String
    public var correspondentId: Int64?
    public var docType: String
    public var language: String
    public var stableKeysJson: String
    public var weight: Double
    public var source: String
    public var orphaned: Bool
    public var createdAt: Date
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var memory: FilingMemory {
        FilingMemory(id: id ?? 0, documentID: docId, folderID: folderId, folderCode: folderCode,
                     embedding: VectorCodec.decode(embedding), embeddingModel: model, summaryLine: summaryLine,
                     correspondentID: correspondentId, documentType: DocumentType(lenient: docType), language: language,
                     stableKeys: JSON.decode([String].self, from: stableKeysJson) ?? [], weight: weight, source: source,
                     createdAt: createdAt)
    }
}

public struct RuleRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "rules"
    public var id: Int64?
    public var name: String
    public var enabled: Bool
    public var priority: Int
    public var origin: String
    public var confirmed: Bool
    public var predicatesJson: String
    public var actionJson: String
    public var support: Int
    public var hits: Int
    public var contradictions: Int
    public var lastHitAt: Date?
    public var explanation: String
    public var forgotten: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var rule: FilingRule? {
        guard let predicates = JSON.decode([RulePredicate].self, from: predicatesJson),
              let action = JSON.decode(RuleAction.self, from: actionJson) else { return nil }
        return FilingRule(id: id ?? 0, name: name, enabled: enabled, priority: priority,
                          origin: RuleOrigin(rawValue: origin) ?? .user, confirmed: confirmed, predicates: predicates,
                          action: action, support: support, hits: hits, contradictions: contradictions, lastHitAt: lastHitAt,
                          explanation: explanation, forgotten: forgotten, createdAt: createdAt)
    }

    public init(_ rule: FilingRule, now: Date = Date()) {
        id = rule.id == 0 ? nil : rule.id
        name = rule.name
        enabled = rule.enabled
        priority = rule.priority
        origin = rule.origin.rawValue
        confirmed = rule.confirmed
        predicatesJson = JSON.string(rule.predicates)
        actionJson = JSON.string(rule.action)
        support = rule.support
        hits = rule.hits
        contradictions = rule.contradictions
        lastHitAt = rule.lastHitAt
        explanation = rule.explanation
        forgotten = rule.forgotten
        createdAt = rule.createdAt
        updatedAt = now
    }
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
    public var defaultFolderCode: String?
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
                      defaultFolderCode: defaultFolderCode, filedCount: filedCount,
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
        defaultFolderCode = c.defaultFolderCode
        filedCount = c.filedCount
        origin = c.origin.rawValue
        createdAt = now
        updatedAt = now
    }
}

public struct ProposalRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "proposals"
    public var id: Int64?
    public var kind: String
    public var status: String
    public var title: String
    public var folderId: Int64?
    public var payloadJson: String
    public var createdAt: Date
    public var resolvedAt: Date?
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum JobState: String, Sendable, Codable, CaseIterable {
    case pending, hashing, extracting, classifying, filing, done, duplicate, needsReview, failed, held, cancelled

    public var isActive: Bool { [.pending, .hashing, .extracting, .classifying, .filing].contains(self) }
}

public enum JobKind: String, Sendable, Codable {
    case ingest, reclassify, adopt
    /// Read a filed document's text and compute its embedding again, without deciding or moving anything: what a
    /// rebuilt index needs for search.
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
    public var logicVersion: String?
    public var taxonomyVersion: Int
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

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }
}
