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
    /// Where filing was about to move the file, kept before it moved it, so the move is found should its record be cut
    /// off (`IngestCoordinator`); nil before filing, and in every job queued before it was kept.
    public var plannedPath: String?
    public var traceID: Int64?
    /// The tags the file is given, decided when it was queued (`GivenTag`); nil for none.
    public var tags: [GivenTag]?
    /// The document in the archive the file is an exact copy of, which is read again in its place
    /// (`IngestCoordinator`); nil for a file that is no copy, and in every job queued before copies were.
    public var copyOf: Int64?
    /// The model the job waits to be installed, which it looks for among the server's before it is taken up again
    /// (`IngestCoordinator`); nil for a job that waits for none, and in every job queued before jobs waited for one.
    public var waitingForModel: String?

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

    /// What queueing a file did (`enqueue`): the job that does what was asked, whether it was queued now, and the tags
    /// the request gave a job that was already queued.
    public struct Queued: Sendable, Hashable {
        public let id: Int64
        public let isNew: Bool
        public let tagsAdded: [GivenTag]
    }

    /// Enqueues a job, not begun (`pending`), unless one is already active for the path that does all this one asks: a
    /// queue drops no request. One that does as much but for the tags `payload` gives is given those it lacks, in the
    /// write that finds it, which its worker, if one has it in hand, takes up at its next save (`update`). One that does
    /// less gives way, cancelled, its worker losing its claim (`IngestError.claimLost`): a `reindex` job, which only reads
    /// the text and computes the embedding, to one that reads the file with the model too; and one whose payload cannot
    /// be read, which could not be worked on. A job for a document read again carries in `payload` what earlier stages
    /// found of it.
    @discardableResult
    public func enqueue(path: String, kind: JobKind, docID: Int64? = nil, payload: JobPayload = JobPayload()) async throws -> Queued {
        let now = time.now()
        return try await database.writer.write { db in
            if var active = try Self.active(db, path: path), let id = active.id {
                let readable = Self.tags(ofPayload: active.payloadJson, in: db)
                if let had = readable, active.kind != .reindex || kind == .reindex {
                    let added = Self.lacking(payload.tags ?? [], in: had)
                    if !added.isEmpty { try Self.setTags(had + added, job: id, in: db) }
                    return Queued(id: id, isNew: false, tagsAdded: added)
                }
                active.state = .cancelled
                (active.claim, active.claimedBy) = (nil, nil)
                active.updatedAt = now
                try active.update(db)
            }
            var job = JobRecord(id: nil, kind: kind, docId: docID, sourcePath: path, state: .pending, attempt: 0, nextRunAt: now,
                                lastError: nil, payloadJson: try JSON.string(payload), createdAt: now, updatedAt: now)
            try job.insert(db)
            return Queued(id: job.id ?? db.lastInsertedRowID, isNew: true, tagsAdded: [])
        }
    }

    /// The tags a stored payload holds, read by the database, as the payload can hold a document's whole text; nil when
    /// the payload cannot be read.
    private static func tags(ofPayload json: String, in db: Database) -> [GivenTag]? {
        guard let row = try? Row.fetchOne(db, sql: "SELECT json_valid(?) AS valid, json_extract(?, '$.tags') AS tags",
                                          arguments: [json, json]), row["valid"] == true else { return nil }
        let tags: DatabaseValue = row["tags"]
        if tags.isNull { return [] }
        // An array is extracted as its JSON text; anything else is no list of tags.
        return String.fromDatabaseValue(tags).flatMap { JSON.decode([GivenTag].self, from: $0) }
    }

    /// The tags of `wanted` whose label none of `had` has.
    private static func lacking(_ wanted: [GivenTag], in had: [GivenTag]) -> [GivenTag] {
        wanted.filter { tag in !had.contains { $0.label == tag.label } }
    }

    private static func setTags(_ tags: [GivenTag], job id: Int64, in db: Database) throws {
        try db.execute(sql: "UPDATE jobs SET payload_json = json_set(payload_json, '$.tags', json(?)) WHERE id = ?",
                       arguments: [try JSON.string(tags), id])
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

    /// The active jobs that are due at `now`, in the queue's one order: by `id`, the order the jobs were queued in.
    /// `next_run_at` only says when a job is due: one waiting to be tried again, after a failure or for Ollama, is not
    /// taken before its time and holds up none behind it, and once due it takes its place by when it was queued. A job
    /// stopped part way, as when the app quit or crashed, keeps its stage and its place, so it carries on first at the
    /// next start, before anything queued after it. Reading documents again after a rebuild (`reindex`) always gives way
    /// to the others, so a rebuild never holds up filing.
    private static func due(at now: Date) -> QueryInterfaceRequest<JobRecord> {
        JobRecord.filter(activeStates.contains(Column("state")))
            .filter(Column("next_run_at") == nil || Column("next_run_at") <= now.unixSeconds)
            .order(SQL("CASE kind WHEN \(JobKind.reindex.rawValue) THEN 1 ELSE 0 END"), Column("id"))
    }

    /// Takes the job to work on next for a worker of `claims`' process: of the jobs due (`due`), the first that no
    /// worker holds (`JobClaims.holds`), marked with a claim of its own in the write that finds it, so that no other
    /// worker, of this process or of another, as `arrumatorcli` beside the app, takes it until it ends or is let go
    /// (`release`). A job a process that has ended held is taken again. `excluding` are jobs this process may not start
    /// yet (`IngestCoordinator`).
    public func nextDue(claiming claims: JobClaims, excluding: Set<Int64> = []) async throws -> JobRecord? {
        let now = time.now()
        let claim = claims.make()
        do {
            let taken: JobRecord? = try await database.writer.write { db in
                let candidates = try Row.fetchAll(db, Self.due(at: now).select(Column("id"), Column("claim"), Column("claimed_by")))
                let free = candidates.first { row in
                    let id: Int64 = row["id"]
                    return !excluding.contains(id) && !claims.holds(row["claim"], by: row["claimed_by"])
                }
                guard let id = free?["id"] as Int64?, var job = try JobRecord.fetchOne(db, key: id) else { return nil }
                (job.claim, job.claimedBy) = (claim, claims.process)
                job.updatedAt = now
                try job.update(db)
                return job
            }
            if taken == nil { claims.letGo(claim) }
            return taken
        } catch {
            claims.letGo(claim)
            throw error
        }
    }

    /// Lets go of the claim `job` was taken with, when it still holds the job: a job that has not ended waits in the
    /// queue, in its place, for the next worker. The claim is out of this process's hands even when the write fails, so
    /// the job is taken again all the same.
    public func release(_ job: JobRecord, claims: JobClaims) async throws {
        guard let id = job.id, let claim = job.claim else { return }
        defer { claims.letGo(claim) }
        try await database.writer.write { db in
            _ = try JobRecord.filter(key: id).filter(Column("claim") == claim)
                .updateAll(db, Column("claim").set(to: nil), Column("claimed_by").set(to: nil))
        }
    }

    /// Whether the claim `job` was taken with still holds it; a job taken with none is held by whoever has it. A queue
    /// that cannot be read says it does not, so nothing is done on a claim that cannot be shown.
    public func holds(_ job: JobRecord) async -> Bool {
        guard let id = job.id, let claim = job.claim else { return true }
        let stored = try? await database.reader.read { db in try String.fetchOne(db, sql: "SELECT claim FROM jobs WHERE id = ?", arguments: [id]) }
        return stored == claim
    }

    /// When the next active job that no worker holds is due, whatever stage it waits in: what the worker waits until
    /// when none is due now. A job a worker holds (`JobClaims.holds`, as `nextDue` asks) is not waited for; one whose
    /// claim holds no more, as that of a process that has ended, is, as `nextDue` takes it. `excluding` are jobs this
    /// process may not start yet.
    public func earliestDue(claiming claims: JobClaims, excluding: Set<Int64> = []) async throws -> Date? {
        try await database.reader.read { db in
            let active = JobRecord.filter(Self.activeStates.contains(Column("state"))).filter(!excluding.contains(Column("id")))
            let free = try active.filter(Column("claim") == nil)
                .select(min(Column("next_run_at")), as: Double.self).fetchOne(db).map(Date.init(unixSeconds:))
            // Claimed jobs are few: one per worker in hand, and those a process that has ended left.
            let left = try Row.fetchAll(db, active.filter(Column("claim") != nil)
                .select(Column("next_run_at"), Column("claim"), Column("claimed_by")))
                .filter { !claims.holds($0["claim"], by: $0["claimed_by"]) }
                .map { ($0["next_run_at"] as Double?).map(Date.init(unixSeconds:)) ?? .distantPast }
            return (left + [free].compactMap { $0 }).min()
        }
    }

    /// Whether a worker of another process that still runs holds an active job (`ProcessWatching.hasLeft`).
    public func heldElsewhere(claiming claims: JobClaims) async throws -> Bool {
        try await database.reader.read { db in
            try String.fetchAll(db, JobRecord.filter(Self.activeStates.contains(Column("state"))).filter(Column("claim") != nil)
                .select(Column("claimed_by"))).contains { !claims.processes.hasLeft($0) }
        }
    }

    /// How many jobs are active: those that file and read files, and those that read filed documents again for search
    /// (`reindex`). Counted by the database: a job's payload can hold a document's whole text.
    public func counts() async throws -> (queued: Int, reindexing: Int) {
        try await database.reader.read { db in
            let active = JobRecord.filter(Self.activeStates.contains(Column("state")))
            let reindexing = try active.filter(Column("kind") == JobKind.reindex.rawValue).fetchCount(db)
            return (try active.fetchCount(db) - reindexing, reindexing)
        }
    }

    /// Cancels every active job of these kinds; returns how many there were. A worker that has one in hand loses its claim.
    @discardableResult
    public func cancelActive(kinds: Set<JobKind>) async throws -> Int {
        let now = time.now()
        return try await database.writer.write { db in
            try JobRecord.filter(Self.activeStates.contains(Column("state")))
                .filter(kinds.map(\.rawValue).contains(Column("kind")))
                .updateAll(db, Column("state").set(to: JobState.cancelled.rawValue), Column("updated_at").set(to: now.unixSeconds),
                           Column("claim").set(to: nil), Column("claimed_by").set(to: nil))
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

    /// What saving a job did (`update`): the job as saved, and the tags requests gave it since its worker last saved it,
    /// which are saved with it.
    public struct Saved: Sendable {
        public let job: JobRecord
        public let tagsAdded: [GivenTag]
    }

    /// Saves `job` as it is now, with the tags requests gave it meanwhile (`enqueue`). A job taken with a claim is saved
    /// only while the claim still holds it, or `IngestError.claimLost` is thrown and nothing is saved, so a worker that
    /// lost it, as to a request that does more than it does, changes nothing of it. A job that has ended keeps no claim.
    @discardableResult
    public func update(_ job: JobRecord) async throws -> Saved {
        let now = time.now()
        return try await database.writer.write { db in try Self.save(job, at: now, in: db) }
    }

    /// `update`, in a transaction of the caller's, as the one that records a document filed (`DocumentFiler`).
    /// A job that has ended keeps neither its document's text nor its embedding: the document's row and the index keep
    /// what is kept of them, and the trace what the job did.
    @discardableResult
    static func save(_ job: JobRecord, at now: Date, in db: Database) throws -> Saved {
        var saved = job
        saved.updatedAt = now
        if !saved.state.isActive { (saved.claim, saved.claimedBy) = (nil, nil) }
        guard let id = job.id else {
            try saved.save(db)
            return Saved(job: saved, tagsAdded: [])
        }
        let stored = try Row.fetchOne(db, sql: "SELECT claim, payload_json FROM jobs WHERE id = ?", arguments: [id])
        if let claim = job.claim, stored?["claim"] != claim { throw IngestError.claimLost(id) }
        let had = Self.tags(ofPayload: job.payloadJson, in: db) ?? []
        let added = Self.lacking(stored.flatMap { Self.tags(ofPayload: $0["payload_json"], in: db) } ?? [], in: had)
        try saved.update(db)
        if !added.isEmpty { try Self.setTags(had + added, job: id, in: db) }
        if !saved.state.isActive { try db.execute(sql: "UPDATE jobs SET payload_json = \(Self.withoutText) WHERE id = ?", arguments: [id]) }
        guard !added.isEmpty || !saved.state.isActive else { return Saved(job: saved, tagsAdded: []) }
        saved = try JobRecord.fetchOne(db, key: id) ?? saved
        return Saved(job: saved, tagsAdded: added)
    }

    /// A job's payload without its document's text and embedding, as SQL over `payload_json`: what an ended job keeps.
    /// A payload that is no JSON is kept as it is, to say why its job failed.
    static let withoutText = "CASE WHEN json_valid(payload_json) THEN json_remove(payload_json, '$.content', '$.outcome.embedding') ELSE payload_json END"
}

extension JobRecord {
    /// What the job's finished stages found, and what it was queued with. One that cannot be read is never taken for
    /// an empty one, which would lose its tags and the original of a copy: `IngestError.unreadablePayload` says why.
    public var payload: JobPayload {
        get throws {
            do { return try JSON.decoder.decode(JobPayload.self, from: Data(payloadJson.utf8)) } catch {
                throw IngestError.unreadablePayload(id ?? 0, reason: error.localizedDescription)
            }
        }
    }
    public mutating func setPayload(_ p: JobPayload) throws { payloadJson = try JSON.string(p) }

    /// The tags the file is given when it is filed, or keeps when it is read again: the user's own labels, beside those
    /// the model will give it. What its row in the queue shows beneath its name, from when it is queued; none for a job
    /// whose payload cannot be read, which fails, saying why, when it is taken.
    public var tags: [DocumentLabel] { (try? payload)?.tags?.map(\.label) ?? [] }
}
