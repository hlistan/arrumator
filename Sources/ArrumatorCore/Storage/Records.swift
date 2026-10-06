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
    case arrived, processing, filed, needsReview, failed
    /// A copy an earlier version filed beside the document it repeats (`duplicateOf`), as the archive's record files
    /// still hold it; or a file in Incoming that was a document of its own until it was found an exact copy of
    /// `duplicateOf` and went to the Trash. None is filed now: an exact copy has its original read again in its place
    /// (`IngestCoordinator`).
    case duplicate
    case undone, held, missing

    /// The document waits for the user: it could not be read or filed as it should, and waits to be confirmed, corrected
    /// or read again. What Needs You counts (AGENTS.md §4.7: a count only where something waits for the user).
    public var waitsForUser: Bool { [.needsReview, .failed].contains(self) }

    /// The user set the document aside: left it for later, or undid its filing back into Incoming. It waits for nothing
    /// the app could do: Needs You lists it apart from what waits for the user, and counts it not.
    public var isSetAside: Bool { [.held, .undone].contains(self) }

    /// Statuses of documents the pipeline has finished with, whatever the outcome.
    public static let processed: Set<DocumentStatus> = [.filed, .needsReview, .failed, .duplicate, .undone, .held]

    /// Statuses of documents kept in the archive as themselves: what a search task finds, and what an exact copy is a
    /// copy of. A duplicate is a copy of one of them, and a document undone or missing is not in the archive.
    public static let inArchive: Set<DocumentStatus> = [.filed, .needsReview, .failed, .held]

    /// Statuses of documents whose file is in the archive: those kept as themselves (`inArchive`) and the copies earlier
    /// versions filed beside them.
    static let withFileInArchive: Set<DocumentStatus> = inArchive.union([.duplicate])
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
    public var pageCount: Int?
    public var status: DocumentStatus
    /// What the model read the document as (`DocumentAnalysis`) as JSON, with the user's corrections; NULL before.
    public var analysisJson: String?
    public var contentJson: String?
    /// The document's labels as JSON; NULL while it has none and has not been labelled.
    public var labelsJson: String?
    /// Whether its labels are only its tags, the user's own (`LabelKind.tag`), because the model has not labelled it
    /// yet, as when it gave no valid answer for it: it counts as not labelled (`isLabelled`, `DocumentLabel.stored`).
    public var tagsOnly: Bool
    /// The document a `duplicate` repeats.
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
                               now: Date) -> DocumentRecord {
        DocumentRecord(id: nil, uid: UUID().uuidString, path: path, originalFilename: (path as NSString).lastPathComponent,
                       sha256: sha256, size: size, uttype: uttype, inode: inode, pageCount: nil, status: .processing, analysisJson: nil,
                       contentJson: nil, labelsJson: nil, tagsOnly: false, duplicateOf: nil, lastTraceId: nil, addedAt: now, filedAt: nil,
                       extractedAt: nil, embeddedAt: nil, fileMtime: modified, createdAt: now, updatedAt: now)
    }

    public var url: URL { URL(fileURLWithPath: path) }
    /// What its file was when it was last hashed, or nil when that was not recorded.
    public var fingerprint: FileFingerprint? { inode == nil && fileMtime == nil ? nil : FileFingerprint(size: size, modified: fileMtime, inode: inode) }
    /// Whether its file is still as it was last hashed, by size, modification time and identity on the volume; true when
    /// that was not recorded, as for a document taken in from a record file.
    public var isAsRecorded: Bool {
        guard let fingerprint else { return true }
        return (try? FileFingerprint.of(url))?.matches(fingerprint) ?? false
    }
    public var filename: String { (path as NSString).lastPathComponent }
    public var analysis: DocumentAnalysis? { JSON.decode(DocumentAnalysis.self, from: analysisJson) }
    /// Nil while the document has no labels and has not been labelled; empty when the model found nothing worth a label.
    /// Before the model has labelled it, it may have its tags (`tagsOnly`).
    public var labels: [DocumentLabel]? { JSON.decode([DocumentLabel].self, from: labelsJson) }
    /// Whether the document has been labelled: read by the model, or given a label of another kind than a tag by hand.
    /// One that is not is read by what reads documents without labels (`DocumentStore.unlabelled`).
    public var isLabelled: Bool { labelsJson != nil && !tagsOnly }
    /// The values of the document's labels of `kind`.
    public func labels(_ kind: LabelKind) -> [String] { labels?.values(kind) ?? [] }
    /// The document's own date, the day it was issued: its `date` label, `YYYY-MM-DD`, of which it has one at most; nil
    /// when it has none. Not when it was added, filed or processed.
    public var documentDate: String? { labels(.date).first }
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
    case arrived, extracted, analysed, filed, needsReview
    /// An exact copy of a document in the archive arrived, under that document: it is read again, and the copy went to
    /// the Trash (`CopyPayload`); in versions that filed copies, the copy was filed or left in Incoming.
    case duplicate
    case error, retry, failed
    /// The user changed a document's name or labels.
    case corrected
    case undone, markedCorrect, userMoved, userRenamed, missing, adopted
    case settingsChanged, ollamaState, appStarted, paused, resumed
    /// The index was rebuilt from the archive's record files.
    case rebuilt
    /// A document was found in more than one place of the archive, and nothing told which is a copy
    /// (`DocumentInTwoPlaces`).
    case foundInTwoPlaces
    /// The user merged a label into another, on every document and in every reading from then on.
    case labelsMerged
    /// The user took a label off every document and does not want it given again.
    case labelIgnored
    /// The user kept two alike labels apart.
    case labelsKeptApart
    /// The user forgot a rule about labels; readings from then on no longer follow it.
    case labelRuleForgotten
    /// The user asked for documents in their own words: a search task joined the queue.
    case taskCreated
    /// The model read a task's prompt, and the documents it asks for were found and arranged.
    case taskPrepared
    /// The model could not read a task's prompt.
    case taskFailed
    /// The user changed a task: its name, prompt or arrangement, or the documents in its set.
    case taskEdited
    /// A task's set was exported to a folder or a ZIP archive.
    case taskExported
    /// The user removed a task; what it exported stays where it was put.
    case taskRemoved
    /// A record file of the archive cannot be read, as one broken by hand: it is not written over, and what is filed or
    /// changed meanwhile is kept in the index until it can be read (`ArchiveRecords.recordUnreadable`).
    case recordFileUnreadable
    /// A record file that could not be read can be read again, and what was kept meanwhile is written into it.
    case recordFileReadable
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

/// Where a job is. `pending` has not begun. `hashing`, `extracting`, `analysing` and `filing` are the stage it is at,
/// the one it runs next, whether the worker has it in hand now or it was stopped part way and carries on there: only
/// the worker's live status (`IngestStatus.current`) says which. The rest are how it ended: `duplicate` for a file that
/// was an exact copy of a document in the archive, which is read again in its place.
public enum JobState: String, Sendable, Codable, CaseIterable {
    case pending, hashing, extracting, analysing, filing, done, duplicate, needsReview, failed, cancelled

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
    /// The claim of the worker that has the job in hand (`JobClaims`), and its process as `ProcessTag` writes it; nil
    /// for a job no worker has.
    public var claim: String?
    public var claimedBy: String?
    /// Whether the job waits until no other is due (`JobStore.nextDue`): reading documents again after a rebuild
    /// (`reindex`), and every document of the archive read again at once (`PipelineServices.queueReadingAllAgain`), so
    /// that neither holds up a file that arrives meanwhile.
    public var givesWay: Bool
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Whether the job spent an attempt on a failure, as every failure that leaves it queued does; one that waits, for
    /// Ollama, the archive's folder or its model, spends none, and keeps why it waits (`lastError`), which Incoming shows
    /// as it shows a failure's, with when it is tried again (`IngestStatus.progress(of:)`).
    public var failedAnAttempt: Bool { attempt > 0 }
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
    /// The stage as recorded: stages of earlier versions stay readable in old traces.
    public var stage: String
    public var status: TraceStatus
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
