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
    /// What reading a document of the archive again keeps, from when it is asked for, as its labels and its place were
    /// then, and, once it is read, with `outcome`, until it is filed, when it takes the place of everything the document
    /// had (`IndexStore.replaceReading`); nil for a file read the first time.
    public var rereading: Rereading?

    public init() {}

    /// What the file was when it was hashed, from `size`, `mtime` and `inode`; nil when it was not hashed in this job,
    /// as a document read again is not.
    var fingerprint: FileFingerprint? {
        size.map { FileFingerprint(size: $0, modified: mtime, inode: inode) }
    }
}

/// What reading a document of the archive again keeps, beside its outcome, until it is filed: the document's labels and
/// where it was when it was asked for, so a kind of label the user changes, or a name the user gives it, after that
/// stays as the user left it; and, once it is read, what the user's rules changed of the model's labels and what gave
/// each of its tags, as History says them once it is filed.
public struct Rereading: Sendable, Codable, Hashable {
    public var before: [DocumentLabel]
    public var path: String
    public var changes: [LabelChange]
    /// Absent for a document without tags.
    public var tags: [GivenTag]?

    public init(before: [DocumentLabel], path: String, changes: [LabelChange], tags: [GivenTag]?) {
        self.before = before
        self.path = path
        self.changes = changes
        self.tags = tags
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

/// How many jobs are active, by how they come: those that file and read files in their turn, the one in hand among them;
/// and, giving way to those, documents read again for search after a rebuild (`reindex`), and documents read again with
/// the rest of the archive (`PipelineServices.queueReadingAllAgain`).
public struct JobCounts: Sendable, Hashable {
    public var queued: Int
    public var reindexing: Int
    public var readingAgain: Int

    public init(queued: Int, reindexing: Int, readingAgain: Int) {
        self.queued = queued
        self.reindexing = reindexing
        self.readingAgain = readingAgain
    }
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
    /// queue drops no request. A job reading a document of the archive again is at the document's path, which follows it
    /// as it moves (`jobs_follow_document`), or else found by its document. One that does as much but for the tags `payload` gives is given those it lacks, in the
    /// write that finds it, which its worker, if one has it in hand, takes up at its next save (`update`). One that does
    /// less gives way, cancelled, its worker losing its claim (`IngestError.claimLost`): a `reindex` job, which only reads
    /// the text and computes the embedding, to one that reads the file with the model too; one that gives way to every
    /// other (`givesWay`, as a `reindex` job always does), to one asked for in its turn, as a document read again with the rest of the archive to the
    /// user's **Read Again** of it; and one whose payload cannot be read, which could not be worked on. A job for a
    /// document read again carries in `payload` what earlier stages found of it.
    @discardableResult
    public func enqueue(path: String, kind: JobKind, docID: Int64? = nil, payload: JobPayload = JobPayload(),
                        givesWay: Bool = false) async throws -> Queued {
        let now = time.now()
        return try await database.writer.write { db in
            try Self.enqueue(db, path: path, kind: kind, docID: docID, payload: payload, givesWay: givesWay, at: now)
        }
    }

    /// `enqueue`, in a transaction of the caller's, as the one that queues every document of the archive to be read again
    /// with the event that records it (`PipelineServices.queueReadingAllAgain`).
    @discardableResult
    static func enqueue(_ db: Database, path: String, kind: JobKind, docID: Int64?, payload: JobPayload, givesWay: Bool,
                        at now: Date) throws -> Queued {
        // Reading a document again for search, after a rebuild, never holds up filing, whoever queues it.
        let givesWay = givesWay || kind == .reindex
        if var active = try Self.active(db, path: path, docID: docID, kind: kind), let id = active.id {
            let readable = Self.tags(ofPayload: active.payloadJson, in: db)
            if let had = readable, active.kind != .reindex || kind == .reindex, !active.givesWay || givesWay {
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
                            lastError: nil, payloadJson: try JSON.string(payload), createdAt: now, updatedAt: now, givesWay: givesWay)
        try job.insert(db)
        return Queued(id: job.id ?? db.lastInsertedRowID, isNew: true, tagsAdded: [])
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

    /// The job the pipeline is still working on for the file at `path`, or, for a request to read document `docID` of
    /// the archive again, its active job doing that wherever it was left, as one an earlier version queued where the
    /// document was before it moved (`jobs_follow_document` keeps the others at the document's path).
    private static func active(_ db: Database, path: String, docID: Int64?, kind: JobKind) throws -> JobRecord? {
        if let job = try active(db, path: path) { return job }
        let rereading = [JobKind.reanalyse, .reindex]
        guard let docID, rereading.contains(kind) else { return nil }
        return try JobRecord.filter(Column("doc_id") == docID).filter(rereading.map(\.rawValue).contains(Column("kind")))
            .filter(activeStates.contains(Column("state"))).fetchOne(db)
    }

    /// Whether document `docID` is still being read in, as its file has just come: an active job takes it in (`ingest`),
    /// or one put into the archive (`adopt`), in a transaction of the caller's.
    static func isReadIn(_ db: Database, docID: Int64) throws -> Bool {
        try readingIn(docID).fetchCount(db) > 0
    }

    /// Whether document `docID`'s reading in is under way at `path`, so a request for that path is taken by its job
    /// (`enqueue`), as for a file put into the archive, filed where it is, in a transaction of the caller's.
    static func isReadIn(_ db: Database, docID: Int64, at path: String) throws -> Bool {
        try readingIn(docID).filter(Column("source_path") == path).fetchCount(db) > 0
    }

    /// The active jobs reading document `docID` in (`isReadIn`).
    private static func readingIn(_ docID: Int64) -> QueryInterfaceRequest<JobRecord> {
        JobRecord.filter(Column("doc_id") == docID).filter(readingInKinds.map(\.rawValue).contains(Column("kind")))
            .filter(activeStates.contains(Column("state")))
    }

    /// The jobs that read a document in, as its file came: into Incoming (`ingest`), or put into the archive (`adopt`).
    private static let readingInKinds: [JobKind] = [.ingest, .adopt]

    /// Cancels the active job reading document `docID` again (`reanalyse`), in a transaction of the caller's that sets
    /// the document aside, as leaving it for later or undoing it: its worker loses its claim, and its reading changes
    /// nothing of the document (`IngestError.claimLost`).
    static func cancelReadingAgain(_ db: Database, docID: Int64, at now: Date) throws {
        try JobRecord.filter(Column("doc_id") == docID).filter(Column("kind") == JobKind.reanalyse.rawValue)
            .filter(activeStates.contains(Column("state")))
            .updateAll(db, Column("state").set(to: JobState.cancelled.rawValue), Column("updated_at").set(to: now.unixSeconds),
                       Column("claim").set(to: nil), Column("claimed_by").set(to: nil))
    }

    public func job(id: Int64) async throws -> JobRecord? {
        try await database.reader.read { db in try JobRecord.fetchOne(db, key: id) }
    }

    /// The active jobs that are due at `now`, in the queue's one order: by `id`, the order the jobs were queued in.
    /// `next_run_at` only says when a job is due: one waiting to be tried again, after a failure or for Ollama, is not
    /// taken before its time and holds up none behind it, and once due it takes its place by when it was queued. A job
    /// stopped part way, as when the app quit or crashed, keeps its stage and its place, so it carries on first at the
    /// next start, before anything queued after it. A job that gives way (`JobRecord.givesWay`: reading documents again
    /// after a rebuild, or the whole archive at once) waits until no other is due, so neither ever holds up filing.
    /// `beforeTheModel` keeps only the jobs whose next stage needs no model (`beforeTheModel`).
    private static func due(at now: Date, givingWay: Bool, beforeTheModel: Bool = false) -> QueryInterfaceRequest<JobRecord> {
        var due = JobRecord.filter(activeStates.contains(Column("state"))).filter(!waitsForItsReadingIn)
            .filter(Column("next_run_at") == nil || Column("next_run_at") <= now.unixSeconds)
            .order(Column("gives_way"), Column("id"))
        if beforeTheModel {
            due = due.filter(Self.beforeTheModel.kinds.map(\.rawValue).contains(Column("kind")))
                .filter(Self.beforeTheModel.states.map(\.rawValue).contains(Column("state")))
        }
        return givingWay ? due : due.filter(Column("gives_way") == false)
    }

    /// A job reading a document again whose reading in has not ended, which waits for it, neither taken nor waited for
    /// until then: taken before, it would be undone by what that reading does after its filing, its text and meaning
    /// indexed, as when it waits to be tried again after a failure that came after its filing. Reading it for search
    /// (`reindex`) indexes what that reading read, and need not wait.
    private static var waitsForItsReadingIn: SQLExpression {
        let (states, kinds) = (activeStates.map { "'\($0)'" }.joined(separator: ", "), readingInKinds.map { "'\($0.rawValue)'" }.joined(separator: ", "))
        return SQL(sql: """
            kind = '\(JobKind.reanalyse.rawValue)' AND EXISTS (SELECT 1 FROM jobs AS readingIn
              WHERE readingIn.doc_id = jobs.doc_id AND readingIn.kind IN (\(kinds)) AND readingIn.state IN (\(states)))
            """).sqlExpression
    }

    /// The jobs whose next stage needs no model, taken while Ollama is away (`IngestCoordinator.ollamaRetryAt`): a file
    /// that came, in Incoming or put into the archive, and is not hashed yet, which may be a copy to hand over to its
    /// original or a file gone to record as such; a document read again or indexed again needs the model next.
    static let beforeTheModel: (kinds: [JobKind], states: [JobState]) = ([.ingest, .adopt], [.pending, .hashing])

    /// Takes the job to work on next for a worker of `claims`' process: of the jobs due (`due`), the first that no
    /// worker holds (`JobClaims.holds`), marked with a claim of its own in the write that finds it, so that no other
    /// worker, of this process or of another, as `arrumatorcli` beside the app, takes it until it ends or is let go
    /// (`release`). A job a process that has ended held is taken again. `excluding` are jobs this process may not start
    /// yet (`IngestCoordinator`); without `givingWay`, none that gives way is taken (`IngestCoordinator.Draining`); with
    /// `beforeTheModel`, only one whose next stage needs no model (`beforeTheModel`).
    public func nextDue(claiming claims: JobClaims, excluding: Set<Int64> = [], givingWay: Bool = true,
                        beforeTheModel: Bool = false) async throws -> JobRecord? {
        let now = time.now()
        let claim = claims.make()
        do {
            let taken: JobRecord? = try await database.writer.write { db in
                let candidates = try Row.fetchAll(db, Self.due(at: now, givingWay: givingWay, beforeTheModel: beforeTheModel)
                    .select(Column("id"), Column("claim"), Column("claimed_by")))
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

    /// When the next active job that no worker holds is due, whatever stage it waits in: what the worker waits until
    /// when none is due now. A job a worker holds (`JobClaims.holds`, as `nextDue` asks) is not waited for; one whose
    /// claim holds no more, as that of a process that has ended, is, as `nextDue` takes it. `excluding` are jobs this
    /// process may not start yet.
    public func earliestDue(claiming claims: JobClaims, excluding: Set<Int64> = []) async throws -> Date? {
        try await database.reader.read { db in
            let active = JobRecord.filter(Self.activeStates.contains(Column("state"))).filter(!excluding.contains(Column("id")))
                .filter(!Self.waitsForItsReadingIn)
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

    /// How many jobs are active (`JobCounts`). Counted by the database: a job's payload can hold a document's whole text.
    public func counts() async throws -> JobCounts {
        try await database.reader.read { db in
            let active = JobRecord.filter(Self.activeStates.contains(Column("state")))
            let givingWay = active.filter(Column("gives_way") == true)
            let reindexing = try givingWay.filter(Column("kind") == JobKind.reindex.rawValue).fetchCount(db)
            return JobCounts(queued: try active.filter(Column("gives_way") == false).fetchCount(db), reindexing: reindexing,
                             readingAgain: try givingWay.fetchCount(db) - reindexing)
        }
    }

    /// The jobs the Incoming page lists, in the order they were queued: those that file and read files, and of those that
    /// give way, which are counted instead (`counts`), only the one in hand, `inHand`, if any.
    public func listed(inHand: Int64?) async throws -> [JobRecord] {
        try await database.reader.read { db in
            try JobRecord.filter(Self.activeStates.contains(Column("state")))
                .filter([JobKind.ingest, .adopt, .reanalyse].map(\.rawValue).contains(Column("kind")))
                .filter(Column("gives_way") == false || Column("id") == inHand)
                .order(Column("id")).fetchAll(db)
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
        let stored = try Row.fetchOne(db, sql: "SELECT claim, payload_json, source_path FROM jobs WHERE id = ?", arguments: [id])
        if let claim = job.claim, stored?["claim"] != claim { throw IngestError.claimLost(id) }
        // Where its document is now, which may have moved since the worker took it (`jobs_follow_document`).
        if let path: String = stored?["source_path"] { saved.sourcePath = path }
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
