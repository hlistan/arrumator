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

    public init() {}
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
    public init(database: AppDatabase) { self.database = database }

    /// Enqueues an ingest job unless one is already active for the path. Returns the job id.
    @discardableResult
    public func enqueue(path: String, kind: JobKind, docID: Int64? = nil, payload: JobPayload = JobPayload(),
                        state: JobState = .pending) async throws -> Int64? {
        try await database.writer.write { db in
            if let active = try JobRecord.filter(Column("source_path") == path)
                .filter(JobState.allCases.filter(\.isActive).map(\.rawValue).contains(Column("state"))).fetchOne(db) {
                return active.id
            }
            let now = Date()
            var job = JobRecord(id: nil, kind: kind, docId: docID, sourcePath: path, state: state, attempt: 0, nextRunAt: now,
                                lastError: nil, payloadJson: JSON.string(payload), createdAt: now, updatedAt: now)
            try job.insert(db)
            return job.id
        }
    }

    public func job(id: Int64) async throws -> JobRecord? {
        try await database.reader.read { db in try JobRecord.fetchOne(db, key: id) }
    }

    /// The next due active job, oldest first. Reading documents again after a rebuild always gives way to files
    /// arriving, so a rebuild never holds up filing.
    public func nextDue(now: Date) async throws -> JobRecord? {
        try await database.reader.read { db in
            try JobRecord.filter(JobState.allCases.filter(\.isActive).map(\.rawValue).contains(Column("state")))
                .filter(Column("next_run_at") == nil || Column("next_run_at") <= now.unixSeconds)
                .order(SQL("CASE kind WHEN \(JobKind.reindex.rawValue) THEN 1 ELSE 0 END"), Column("next_run_at"), Column("id"))
                .fetchOne(db)
        }
    }

    public func earliestPending() async throws -> Date? {
        try await database.reader.read { db in
            try Double.fetchOne(db, sql: """
                SELECT MIN(next_run_at) FROM jobs WHERE state IN ('pending','hashing','extracting','classifying','filing')
                """).map(Date.init(unixSeconds:))
        }
    }

    /// Cancels every active job of these kinds; returns how many there were.
    @discardableResult
    public func cancelActive(kinds: Set<JobKind>) async throws -> Int {
        try await database.writer.write { db in
            try JobRecord.filter(JobState.allCases.filter(\.isActive).map(\.rawValue).contains(Column("state")))
                .filter(kinds.map(\.rawValue).contains(Column("kind")))
                .updateAll(db, Column("state").set(to: JobState.cancelled.rawValue), Column("updated_at").set(to: Date().unixSeconds))
        }
    }

    /// Active jobs, optionally of some kinds only.
    public func active(kinds: Set<JobKind>? = nil) async throws -> [JobRecord] {
        try await database.reader.read { db in
            var request = JobRecord.filter(JobState.allCases.filter(\.isActive).map(\.rawValue).contains(Column("state")))
            if let kinds { request = request.filter(kinds.map(\.rawValue).contains(Column("kind"))) }
            return try request.order(Column("id")).fetchAll(db)
        }
    }

    public func update(_ job: JobRecord) async throws {
        try await database.writer.write { db in
            var j = job
            j.updatedAt = Date()
            try j.update(db)
        }
    }

    /// Jobs whose state has not changed for longer than `olderThan` seconds (watchdog).
    public func stale(olderThan seconds: Double, now: Date) async throws -> [JobRecord] {
        try await database.reader.read { db in
            try JobRecord.filter(JobState.allCases.filter(\.isActive).map(\.rawValue).contains(Column("state")))
                .filter(Column("state") != JobState.pending.rawValue)
                .filter(Column("updated_at") < now.addingTimeInterval(-seconds).unixSeconds).fetchAll(db)
        }
    }
}

extension JobRecord {
    public var payload: JobPayload { JSON.decode(JobPayload.self, from: payloadJson) ?? JobPayload() }
    public mutating func setPayload(_ p: JobPayload) { payloadJson = JSON.string(p) }
}
