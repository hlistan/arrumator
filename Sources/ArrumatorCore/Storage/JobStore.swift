import Foundation
import GRDB

/// Stage outputs persisted between job steps so an interrupted job resumes without redoing expensive work.
public struct JobPayload: Sendable, Codable, Hashable {
    public var sha256: String?
    public var size: Int64?
    public var mtime: Date?
    public var inode: Int64?
    public var content: ExtractedContent?
    public var outcome: AnalysisOutcome?
    public var targetPath: String?
    public var traceID: Int64?
    /// The tags the file is given, decided when it was queued (`GivenTag`); nil for none.
    public var tags: [GivenTag]?
    /// The document in the archive the file is an exact copy of, which is read again in its place
    /// (`IngestCoordinator`); nil for a file that is no copy, and in every job queued before copies were.
    public var copyOf: Int64?

    public init() {}

    /// What the file was when it was hashed, from `size`, `mtime` and `inode`; nil when it was not hashed in this job,
    /// as a document read again is not.
    var fingerprint: FileFingerprint? {
        size.map { FileFingerprint(size: $0, modified: mtime, inode: inode) }
    }
}

extension ExtractedContent: Hashable {
    public static func == (lhs: ExtractedContent, rhs: ExtractedContent) -> Bool {
        lhs.source == rhs.source && lhs.text == rhs.text && lhs.kind == rhs.kind
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(text.count)
    }
}

extension AnalysisOutcome: Hashable {
    public static func == (lhs: AnalysisOutcome, rhs: AnalysisOutcome) -> Bool {
        lhs.analysis == rhs.analysis && lhs.labels == rhs.labels && lhs.embeddingModel == rhs.embeddingModel
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(analysis) }
}

public struct JobStore: Sendable {
    public let database: AppDatabase
    public let time: any TimeSource

    public init(database: AppDatabase, time: any TimeSource) {
        self.database = database
        self.time = time
    }

    /// The states of a job the pipeline is still working on, as stored.
    private static var activeStates: [String] { JobState.allCases.filter(\.isActive).map(\.rawValue) }

    /// Enqueues a job, not begun (`pending`), unless one is already active for the path, which does what it would: returns
    /// the job id. A job that reads the file with the model also reads its text and computes its embedding, so it takes
    /// the place of a `reindex` job for the path, which only does that, rather than waiting behind it unread. A job for
    /// a document read again carries in `payload` what earlier stages found of it.
    @discardableResult
    public func enqueue(path: String, kind: JobKind, docID: Int64? = nil, payload: JobPayload = JobPayload()) async throws -> Int64? {
        let now = time.now()
        return try await database.writer.write { db in
            if var active = try Self.active(db, path: path) {
                guard active.kind == .reindex, kind != .reindex else { return active.id }
                active.state = .cancelled
                active.updatedAt = now
                try active.update(db)
            }
            var job = JobRecord(id: nil, kind: kind, docId: docID, sourcePath: path, state: .pending, attempt: 0, nextRunAt: now,
                                lastError: nil, payloadJson: try JSON.string(payload), createdAt: now, updatedAt: now)
            try job.insert(db)
            return job.id
        }
    }

    /// The job the pipeline is still working on for the file at `path`, if there is one: one at most, by a unique index.
    func active(path: String) async throws -> JobRecord? {
        try await database.reader.read { db in try Self.active(db, path: path) }
    }

    private static func active(_ db: Database, path: String) throws -> JobRecord? {
        try JobRecord.filter(Column("source_path") == path).filter(activeStates.contains(Column("state"))).fetchOne(db)
    }

    public func job(id: Int64) async throws -> JobRecord? {
        try await database.reader.read { db in try JobRecord.fetchOne(db, key: id) }
    }

    /// The job to work on next: of the active jobs that are due, the one queued first (by `id`, the order the jobs were
    /// queued in). This is the queue's one order, and `next_run_at` only says when a job is due: one waiting to be tried
    /// again, after a failure or for Ollama, is not taken before its time and holds up none behind it, and once due it
    /// takes its place by when it was queued. A job stopped part way, as when the app quit or crashed, keeps its stage
    /// and its place, so it carries on first at the next start, before anything queued after it. Reading documents
    /// again after a rebuild (`reindex`) always gives way to the others, so a rebuild never holds up filing.
    public func nextDue() async throws -> JobRecord? {
        let now = time.now()
        return try await database.reader.read { db in
            try JobRecord.filter(Self.activeStates.contains(Column("state")))
                .filter(Column("next_run_at") == nil || Column("next_run_at") <= now.unixSeconds)
                .order(SQL("CASE kind WHEN \(JobKind.reindex.rawValue) THEN 1 ELSE 0 END"), Column("id"))
                .fetchOne(db)
        }
    }

    /// When the next active job is due, whatever stage it waits in: what the worker waits until when none is due now.
    public func earliestDue() async throws -> Date? {
        try await database.reader.read { db in
            try JobRecord.filter(Self.activeStates.contains(Column("state")))
                .select(min(Column("next_run_at")), as: Double.self).fetchOne(db).map(Date.init(unixSeconds:))
        }
    }

    /// Cancels every active job of these kinds; returns how many there were.
    @discardableResult
    public func cancelActive(kinds: Set<JobKind>) async throws -> Int {
        let now = time.now()
        return try await database.writer.write { db in
            try JobRecord.filter(Self.activeStates.contains(Column("state")))
                .filter(kinds.map(\.rawValue).contains(Column("kind")))
                .updateAll(db, Column("state").set(to: JobState.cancelled.rawValue), Column("updated_at").set(to: now.unixSeconds))
        }
    }

    /// Active jobs, optionally of some kinds only, in the order they were queued.
    public func active(kinds: Set<JobKind>? = nil) async throws -> [JobRecord] {
        try await database.reader.read { db in
            var request = JobRecord.filter(Self.activeStates.contains(Column("state")))
            if let kinds { request = request.filter(kinds.map(\.rawValue).contains(Column("kind"))) }
            return try request.order(Column("id")).fetchAll(db)
        }
    }

    public func update(_ job: JobRecord) async throws {
        let now = time.now()
        try await database.writer.write { db in
            var j = job
            j.updatedAt = now
            try j.update(db)
        }
    }
}

extension JobRecord {
    public var payload: JobPayload { JSON.decode(JobPayload.self, from: payloadJson) ?? JobPayload() }
    public mutating func setPayload(_ p: JobPayload) throws { payloadJson = try JSON.string(p) }

    /// The tags the file is given when it is filed, or keeps when it is read again: the user's own labels, beside those
    /// the model will give it. What its row in the queue shows beneath its name, from when it is queued.
    public var tags: [DocumentLabel] { payload.tags?.map(\.label) ?? [] }
}
