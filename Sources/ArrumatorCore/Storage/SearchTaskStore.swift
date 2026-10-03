import Foundation
import GRDB

/// A search task as the index keeps it (`search_tasks`). Its set is in `search_task_documents` and its exports in
/// `search_task_exports`; `SearchTaskStore` puts the three together as a `SearchTask`.
public struct SearchTaskRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "search_tasks"
    public var id: Int64?
    public var prompt: String
    /// The name the user gave the task; nil for the model's.
    public var title: String?
    /// The kinds the user chose to arrange the set by, as JSON; nil for the plan's.
    public var groupingJson: String?
    /// How much the model thinks before it answers its prompt.
    public var effort: TaskEffort
    /// The id of the model profile the user gave it; nil to follow the one Settings uses.
    public var profile: String?
    public var state: SearchTaskState
    public var planJson: String?
    public var model: String?
    public var problem: String?
    public var lastTraceId: Int64?
    /// When a queued task is due: now, or later while Ollama cannot be reached.
    public var nextRunAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// The process reading its request (a `ProcessTag`), while it is `interpreting`; nil otherwise. The index's own.
    public var worker: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var plan: SearchPlan? { JSON.decode(SearchPlan.self, from: planJson) }
    public var userGrouping: [LabelKind]? { JSON.decode([LabelKind].self, from: groupingJson) }
}

/// An export of a task's set, as the index keeps it.
public struct SearchTaskExportRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "search_task_exports"
    public var id: Int64?
    public var taskId: Int64
    public var at: Date
    public var format: ExportFormat
    public var path: String
    public var manifestJson: String

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var export: SearchTaskExport? {
        guard let id, let manifest = JSON.decode(ExportManifest.self, from: manifestJson) else { return nil }
        return SearchTaskExport(id: id, at: at, format: format, path: path, files: manifest.files, skipped: manifest.skipped)
    }
}

/// One document's place in a task's set, as the index keeps it.
struct SetMember: Sendable, Hashable {
    var document: Int64
    var inclusion: SetInclusion
}

public enum SearchTaskError: Error, LocalizedError, Equatable {
    case taskNotFound(Int64)
    case documentNotFound(Int64)
    case emptyPrompt
    case groupingTooDeep(Int)
    case groupingRepeats(LabelKind)
    case nothingToExport(Int64)
    case destinationNotAFolder(String)
    case destinationInsideArchive(String)
    case exportFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case let .taskNotFound(id): "There is no search task \(id)"
        case let .documentNotFound(id): "There is no document \(id)"
        case .emptyPrompt: "Say which documents you are looking for"
        case let .groupingTooDeep(limit): "A set is arranged by at most \(limit) kinds of label (tasks.maxGroupingDepth)"
        case let .groupingRepeats(kind): "A set is arranged by \(kind.rawValue) once"
        case let .nothingToExport(id): "Search task \(id) has no documents to export"
        case let .destinationNotAFolder(path): "\(path) is a file, not a folder"
        case let .destinationInsideArchive(path):
            "\(path) is inside the archive or Incoming, where the copies would be filed as documents; choose a folder outside them"
        case let .exportFailed(path, why): "Could not export to \(path): \(why)"
        }
    }
}

/// Search tasks as the index keeps them: each put together as a `SearchTask` for the app and the command line, and the
/// queue the model reads their prompts in (`SearchTaskQueue`). What the user does to a task is `SearchTaskActions`.
public struct SearchTaskStore: Sendable {
    public let database: AppDatabase
    public let config: TasksConfig
    public let time: any TimeSource

    public init(database: AppDatabase, config: TasksConfig, time: any TimeSource) {
        self.database = database
        self.config = config
        self.time = time
    }

    // MARK: Reading

    public func task(id: Int64) async throws -> SearchTask? {
        try await database.reader.read { db in try Self.task(db, id: id, config: config) }
    }

    /// Every task, the most recently asked first.
    public func tasks() async throws -> [SearchTask] {
        try await database.reader.read { db in
            try SearchTaskRecord.order(Column("created_at").desc, Column("id").desc).fetchAll(db)
                .compactMap { try Self.task(db, record: $0, config: config) }
        }
    }

    /// A task with the documents of its set, arranged as it says.
    public func detail(id: Int64) async throws -> SearchTaskDetail? {
        try await database.reader.read { db in
            guard let task = try Self.task(db, id: id, config: config) else { return nil }
            let documents = try DocumentStore.documents(db, ids: task.documents)
            return SearchTaskDetail(task: task, tree: DocumentGrouping.tree(documents, by: task.grouping))
        }
    }

    static func task(_ db: Database, id: Int64, config: TasksConfig) throws -> SearchTask? {
        guard let record = try SearchTaskRecord.fetchOne(db, key: id) else { return nil }
        return try task(db, record: record, config: config)
    }

    static func task(_ db: Database, record: SearchTaskRecord, config: TasksConfig) throws -> SearchTask? {
        guard let id = record.id else { return nil }
        let members = try Self.members(db, task: id)
        let exports = try SearchTaskExportRecord.filter(Column("task_id") == id).order(Column("at"), Column("id")).fetchAll(db)
            .compactMap(\.export)
        let plan = record.plan
        let grouping = record.userGrouping ?? plan.flatMap { $0.grouping.isEmpty ? nil : $0.grouping } ?? config.defaultGrouping
        return SearchTask(id: id, name: name(record, config: config), prompt: record.prompt, title: record.title, state: record.state,
                          plan: plan, grouping: grouping, groupedByUser: record.userGrouping != nil, effort: record.effort,
                          profile: record.profile, model: record.model,
                          problem: record.problem, documents: members.filter { $0.inclusion != .removed }.map(\.document),
                          added: members.filter { $0.inclusion == .added }.map(\.document),
                          removed: members.filter { $0.inclusion == .removed }.map(\.document),
                          exports: exports, lastTrace: record.lastTraceId, createdAt: record.createdAt, updatedAt: record.updatedAt)
    }

    /// The name a task goes by: the user's, else the model's, else the start of its prompt.
    static func name(_ record: SearchTaskRecord, config: TasksConfig) -> String {
        if let title = record.title, !title.isEmpty { return title }
        if let title = record.plan?.title, !title.isEmpty { return title }
        return DocumentLabel.shortened(DocumentLabel.oneLine(record.prompt), to: config.maxTitleChars)
    }

    /// The documents a task's set knows of, in the order they joined it, those taken out among them.
    static func members(_ db: Database, task: Int64) throws -> [SetMember] {
        try Row.fetchAll(db, sql: "SELECT doc_id, inclusion FROM search_task_documents WHERE task_id = ? ORDER BY seq",
                         arguments: [task]).compactMap { row in
            SetInclusion(rawValue: row["inclusion"] ?? "").map { SetMember(document: row["doc_id"], inclusion: $0) }
        }
    }

    /// How many tasks read with the model profile `profile` names, rather than with the one Settings uses.
    static func count(_ db: Database, profile: String) throws -> Int {
        try SearchTaskRecord.filter(Column("profile") == profile).fetchCount(db)
    }

    // MARK: The queue

    /// The task to read next: of the queued tasks that are due, the one asked first (by `id`). `next_run_at` only says
    /// when a task is due: one waiting for Ollama is not read before its time, and holds up none behind it. A task
    /// whose prompt was being read when the app stopped keeps its place, so it is read first at the next start.
    func nextDue() async throws -> SearchTaskRecord? {
        let now = time.now()
        return try await database.reader.read { db in
            try SearchTaskRecord.filter(Column("state") == SearchTaskState.queued.rawValue)
                .filter(Column("next_run_at") == nil || Column("next_run_at") <= now.unixSeconds)
                .order(Column("id")).fetchOne(db)
        }
    }

    /// How many tasks wait in the queue, due or not: those being read are not among them.
    func queuedCount() async throws -> Int {
        try await database.reader.read { db in try SearchTaskRecord.filter(Column("state") == SearchTaskState.queued.rawValue).fetchCount(db) }
    }

    /// When the next queued task is due.
    func earliestDue() async throws -> Date? {
        try await database.reader.read { db in
            try SearchTaskRecord.filter(Column("state") == SearchTaskState.queued.rawValue)
                .select(min(Column("next_run_at")), as: Double.self).fetchOne(db).map(Date.init(unixSeconds:))
        }
    }

    /// Takes a queued task to have its prompt read by the process `worker` names (a `ProcessTag`); nil when it is no
    /// longer queued. No History event says so, as History keeps what a reading concluded: the queue's status says which
    /// task it reads (`SearchTaskQueue.statusUpdates()`).
    func begin(_ id: Int64, by worker: String) async throws -> SearchTaskRecord? {
        let now = time.now()
        return try await database.writer.write { db in
            guard var record = try SearchTaskRecord.fetchOne(db, key: id), record.state == .queued else { return nil }
            record.state = .interpreting
            record.worker = worker
            record.updatedAt = now
            try record.update(db)
            return record
        }
    }

    /// Tasks whose prompt was being read by no process that still reads them (`ProcessWatching.hasLeft`), as when the
    /// app stopped or a command was killed, go back into the queue, in their place: they were due when they were taken,
    /// so they are due still. How many.
    func recoverLeft(_ processes: any ProcessWatching) async throws -> Int {
        // Looked for first, so the worker's every look writes nothing when nothing was left, as is usual.
        let found = try await database.reader.read { db in
            try SearchTaskRecord.filter(Column("state") == SearchTaskState.interpreting.rawValue).fetchAll(db)
        }
        guard found.contains(where: { processes.hasLeft($0.worker) }) else { return 0 }
        return try await database.writer.write { db in
            let left = try SearchTaskRecord.filter(Column("state") == SearchTaskState.interpreting.rawValue).fetchAll(db)
                .filter { processes.hasLeft($0.worker) }.compactMap(\.id)
            guard !left.isEmpty else { return 0 }
            return try SearchTaskRecord.filter(keys: left)
                .updateAll(db, Column("state").set(to: SearchTaskState.queued.rawValue), Column("worker").set(to: nil))
        }
    }

    /// Whether `record` is still being read by `worker`: not changed, put back in the queue, or taken by another process
    /// since. What a reading keeps depends on it, as any change the user makes that asks for another reading puts the
    /// task back in the queue.
    static func held(_ record: SearchTaskRecord, by worker: String) -> Bool {
        record.state == .interpreting && record.worker == worker
    }

    /// Puts a task `worker` reads back in the queue until `date`, as while Ollama cannot be reached, keeping `trace`, which
    /// the next attempt takes up.
    func postpone(_ id: Int64, by worker: String, until date: Date, trace: Int64?) async throws {
        let now = time.now()
        try await database.writer.write { db in
            guard var record = try SearchTaskRecord.fetchOne(db, key: id), Self.held(record, by: worker) else { return }
            record.state = .queued
            record.worker = nil
            record.nextRunAt = date
            record.lastTraceId = trace ?? record.lastTraceId
            record.updatedAt = now
            try record.update(db)
        }
    }

    /// Keeps what the model read a task's prompt as and the documents that plan found: those it found before and not
    /// now leave the set, those the user took out stay out, and those the user added stay in. Nothing is kept, and
    /// false returned, when `worker` reads the task no more: it was removed, or changed in what decides its reading (its
    /// prompt, effort or profile), and is in the queue again.
    func prepare(_ id: Int64, by worker: String, interpretation: SearchInterpretation, plan: SearchPlan, found: [Int64],
                 trace: Int64?) async throws -> Bool {
        let now = time.now()
        let config = config
        return try await database.writer.write { db in
            guard var record = try SearchTaskRecord.fetchOne(db, key: id), Self.held(record, by: worker) else { return false }
            record.state = .ready
            record.worker = nil
            record.planJson = try JSON.string(plan)
            record.model = interpretation.model
            record.problem = nil
            record.lastTraceId = trace
            record.nextRunAt = nil
            record.updatedAt = now
            try record.update(db)
            let members = try Self.members(db, task: id)
            let settled = Set(members.filter { $0.inclusion != .matched }.map(\.document))
            let stillFound = Set(found)
            for member in members where member.inclusion == .matched && !stillFound.contains(member.document) {
                try db.execute(sql: "DELETE FROM search_task_documents WHERE task_id = ? AND doc_id = ?", arguments: [id, member.document])
            }
            // A document found before keeps its place in the set.
            for document in found where !settled.contains(document) {
                try Self.include(db, task: id, document: document, as: .matched)
            }
            let count = try Self.members(db, task: id).filter { $0.inclusion != .removed }.count
            try HistoryStore.insert(db, .taskPrepared, at: now, trace: trace,
                                    summary: "Found \(Format.count(found.count, "document")) for “\(Self.name(record, config: config))”",
                                    payload: TaskEventPayload(task: id, documents: count, plan: plan))
            return true
        }
    }

    /// Records that the model could not read a task's prompt, unless `worker` reads it no more (`prepare`).
    func fail(_ id: Int64, by worker: String, interpretation: SearchInterpretation, trace: Int64?) async throws {
        let now = time.now()
        let config = config
        try await database.writer.write { db in
            guard var record = try SearchTaskRecord.fetchOne(db, key: id), Self.held(record, by: worker) else { return }
            record.state = .failed
            record.worker = nil
            record.model = interpretation.model
            record.problem = interpretation.problem
            record.lastTraceId = trace
            record.nextRunAt = nil
            record.updatedAt = now
            try record.update(db)
            try HistoryStore.insert(db, .taskFailed, at: now, trace: trace,
                                    summary: "Could not read “\(Self.name(record, config: config))”: \(interpretation.problem ?? "")",
                                    payload: TaskEventPayload(task: id, documents: nil, plan: nil))
        }
    }

    /// Puts `document` in a task's set as `inclusion`, after the documents already there.
    static func include(_ db: Database, task: Int64, document: Int64, as inclusion: SetInclusion) throws {
        try db.execute(sql: """
            INSERT INTO search_task_documents (task_id, doc_id, inclusion, seq)
            VALUES (?, ?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM search_task_documents WHERE task_id = ?))
            ON CONFLICT(task_id, doc_id) DO UPDATE SET inclusion = excluded.inclusion
            """, arguments: [task, document, inclusion.rawValue, task])
    }
}

extension SearchTaskStore {
    // MARK: The archive's record

    /// Every task as `System/_tasks.md` records it, in the order they were asked.
    static func entries(_ db: Database) throws -> [SearchTaskEntry] {
        try SearchTaskRecord.order(Column("id")).fetchAll(db).compactMap { record in
            try record.id.flatMap { id in
                SearchTaskEntry(record, members: try members(db, task: id),
                                exports: try SearchTaskExportRecord.filter(Column("task_id") == id).order(Column("id")).fetchAll(db))
            }
        }
    }

    /// Adds or replaces a task from its entry, with its set and its exports, keeping what the index keeps of its own (its
    /// trace, and when a waiting task is next tried). A document the index does not have is left out of the set: its
    /// number points nowhere.
    static func restore(_ entry: SearchTaskEntry, db: Database) throws {
        var record = try entry.record
        if let existing = try SearchTaskRecord.fetchOne(db, key: entry.id) {
            record.lastTraceId = existing.lastTraceId
            record.nextRunAt = existing.state == record.state ? existing.nextRunAt : record.nextRunAt
        }
        try record.save(db)
        try db.execute(sql: "DELETE FROM search_task_documents WHERE task_id = ?", arguments: [entry.id])
        for member in entry.documents where try DocumentRecord.exists(db, key: member.document) {
            try include(db, task: entry.id, document: member.document, as: member.inclusion)
        }
        try db.execute(sql: "DELETE FROM search_task_exports WHERE task_id = ? AND id NOT IN (\(ArchiveRecords.ids(entry.exports.map(\.id))))",
                       arguments: [entry.id])
        for var export in try entry.exportRecords { try export.save(db) }
    }
}

/// What History keeps of an event about a search task.
public struct TaskEventPayload: Sendable, Codable, Hashable {
    public var task: Int64
    /// The documents in its set afterwards.
    public var documents: Int?
    public var plan: SearchPlan?
}
