import Foundation
import GRDB

/// A question about a search task's documents and its answer, as the index keeps it (`search_task_turns`).
public struct TaskTurnRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "search_task_turns"
    public var id: Int64?
    public var taskId: Int64
    public var question: String
    public var state: TurnState
    public var answer: String?
    public var sourcesJson: String?
    public var findingJson: String?
    public var model: String?
    public var problem: String?
    public var lastTraceId: Int64?
    /// When a queued question is due: when it was asked, or later while Ollama cannot be reached.
    public var nextRunAt: Date?
    public var askedAt: Date
    public var answeredAt: Date?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var sources: [Int64] { JSON.decode([Int64].self, from: sourcesJson) ?? [] }
    public var finding: TurnFinding? { JSON.decode(TurnFinding.self, from: findingJson) }

    var turn: TaskTurn? {
        id.map { TaskTurn(id: $0, task: taskId, question: question, state: state, answer: answer, sources: sources, finding: finding,
                          model: model, problem: problem, lastTrace: lastTraceId, asked: askedAt, answered: answeredAt) }
    }

    /// Sent back into the queue to be answered from the start, as it was asked.
    mutating func requeue(at now: Date) {
        state = .queued
        answer = nil
        sourcesJson = nil
        findingJson = nil
        problem = nil
        nextRunAt = now
        answeredAt = nil
    }
}

public enum ConversationError: Error, LocalizedError, Equatable {
    case turnNotFound(Int64)
    case emptyQuestion
    case questionTooLong(Int)
    /// The question is still in the queue, so it is not asked again.
    case stillAnswering(Int64)

    public var errorDescription: String? {
        switch self {
        case let .turnNotFound(id): "There is no question \(id)"
        case .emptyQuestion: "Say what you want to know about the documents"
        case let .questionTooLong(limit): "A question is at most \(limit) characters (conversation.maxQuestionChars)"
        case let .stillAnswering(id): "Question \(id) is still waiting to be answered"
        }
    }
}

/// Conversations about search tasks' documents as the index keeps them: each task's questions and answers, in the order
/// they were asked, read as the app and the command line show them, and the queue the model answers them in
/// (`TaskConversationQueue`). What the user does with them is `TaskConversationActions`.
public struct TaskConversationStore: Sendable {
    public let database: AppDatabase
    public let time: any TimeSource

    public init(database: AppDatabase, time: any TimeSource) {
        self.database = database
        self.time = time
    }

    // MARK: Reading

    public func turn(id: Int64) async throws -> TaskTurn? {
        try await database.reader.read { db in try TaskTurnRecord.fetchOne(db, key: id)?.turn }
    }

    /// The task's questions and answers, the first asked first.
    public func turns(task: Int64) async throws -> [TaskTurn] {
        try await database.reader.read { db in try Self.records(db, task: task).compactMap(\.turn) }
    }

    /// The task's conversation as it is read: its questions and answers, and between them, at the time each was made,
    /// every change History recorded to the task's set or to how it is read, from the first question on.
    public func conversation(task: Int64) async throws -> [ConversationItem] {
        try await database.reader.read { db in
            let turns = try Self.records(db, task: task).compactMap(\.turn)
            guard let first = turns.first else { return [] }
            let changes = try EventRecord
                .filter([EventKind.taskEdited.rawValue, EventKind.taskPrepared.rawValue].contains(Column("kind")))
                .filter(sql: "json_extract(payload_json, '$.task') = ?", arguments: [task])
                .filter(Column("at") > first.asked.unixSeconds)
                .order(Column("at"), Column("id")).fetchAll(db)
            var items = turns.map { (at: $0.asked, order: 0, item: ConversationItem(at: $0.asked, turn: $0, change: nil)) }
            items += changes.map { (at: $0.at, order: 1, item: ConversationItem(at: $0.at, turn: nil, change: $0.summary)) }
            // A change made in the same instant as a question is made before it, as the question saw it.
            return items.enumerated().sorted { a, b in
                (a.element.at, -a.element.order, a.offset) < (b.element.at, -b.element.order, b.offset)
            }.map(\.element.item)
        }
    }

    static func records(_ db: Database, task: Int64) throws -> [TaskTurnRecord] {
        try TaskTurnRecord.filter(Column("task_id") == task).order(Column("id")).fetchAll(db)
    }

    // MARK: The queue

    /// The question to answer next: of the queued questions that are due, the one asked first (by `id`). `next_run_at`
    /// only says when a question is due: one waiting for Ollama is not answered before its time, and holds up none
    /// behind it. A question being answered when the app stopped keeps its place, so it is answered first at the next
    /// start.
    func nextDue() async throws -> TaskTurnRecord? {
        let now = time.now()
        return try await database.reader.read { db in
            try TaskTurnRecord.filter(Column("state") == TurnState.queued.rawValue)
                .filter(Column("next_run_at") == nil || Column("next_run_at") <= now.unixSeconds)
                .order(Column("id")).fetchOne(db)
        }
    }

    /// How many questions wait in the queue, due or not: the one being answered is not among them.
    public func queuedCount() async throws -> Int {
        try await database.reader.read { db in try TaskTurnRecord.filter(Column("state") == TurnState.queued.rawValue).fetchCount(db) }
    }

    /// When the next queued question is due.
    func earliestDue() async throws -> Date? {
        try await database.reader.read { db in
            try TaskTurnRecord.filter(Column("state") == TurnState.queued.rawValue)
                .select(min(Column("next_run_at")), as: Double.self).fetchOne(db).map(Date.init(unixSeconds:))
        }
    }

    /// Takes a queued question to answer, with its task; nil when it is no longer queued.
    func begin(_ id: Int64) async throws -> (turn: TaskTurnRecord, task: SearchTaskRecord)? {
        try await database.writer.write { db in
            guard var record = try TaskTurnRecord.fetchOne(db, key: id), record.state == .queued,
                  let task = try SearchTaskRecord.fetchOne(db, key: record.taskId) else { return nil }
            record.state = .answering
            try record.update(db)
            return (record, task)
        }
    }

    /// Questions being answered when the app stopped go back into the queue, in their place: they were due when they
    /// were taken, so they are due still.
    func recoverInterrupted() async throws -> Int {
        try await database.writer.write { db in
            try TaskTurnRecord.filter(Column("state") == TurnState.answering.rawValue)
                .updateAll(db, Column("state").set(to: TurnState.queued.rawValue))
        }
    }

    /// Puts a question back in the queue until `date`, as while Ollama cannot be reached.
    func postpone(_ id: Int64, until date: Date) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE search_task_turns SET state = ?, next_run_at = ? WHERE id = ? AND state = ?",
                           arguments: [TurnState.queued.rawValue, date.unixSeconds, id, TurnState.answering.rawValue])
        }
    }

    /// Keeps the answer to a question, with what it found outside the set if it was asked to find more. Nothing is kept,
    /// and false returned, when the question was removed or asked again while it was answered.
    func finish(_ id: Int64, answer: TaskAnswer, finding: TurnFinding?, trace: Int64?) async throws -> Bool {
        let now = time.now()
        return try await database.writer.write { db in
            guard var record = try TaskTurnRecord.fetchOne(db, key: id), record.state == .answering else { return false }
            record.state = .answered
            record.answer = answer.text
            record.sourcesJson = answer.sources.isEmpty ? nil : JSON.string(answer.sources)
            record.findingJson = finding.map { JSON.string($0) }
            record.model = answer.model
            record.problem = answer.problem
            record.lastTraceId = trace
            record.nextRunAt = nil
            record.answeredAt = now
            try record.update(db)
            return true
        }
    }

    /// Takes a question out of the queue, saying why: one waiting, or one another process is answering, which then keeps
    /// nothing of its answer (`finish`). False when it was in the queue no more.
    func withdraw(_ id: Int64, problem: String) async throws -> Bool {
        let now = time.now()
        return try await database.writer.write { db in
            guard var record = try TaskTurnRecord.fetchOne(db, key: id), record.state.isActive else { return false }
            record.state = .failed
            record.problem = problem
            record.nextRunAt = nil
            record.answeredAt = now
            try record.update(db)
            return true
        }
    }

    /// Records that a question was not answered, with what came of the answer before it ended, if anything did, unless
    /// the question was removed or asked again meanwhile.
    func fail(_ id: Int64, problem: String, partial: String?, model: String?, trace: Int64?) async throws {
        let now = time.now()
        try await database.writer.write { db in
            guard var record = try TaskTurnRecord.fetchOne(db, key: id), record.state == .answering else { return }
            record.state = .failed
            record.answer = partial.flatMap { $0.isEmpty ? nil : $0 }
            record.sourcesJson = nil
            record.findingJson = nil
            record.model = model ?? record.model
            record.problem = problem
            record.lastTraceId = trace ?? record.lastTraceId
            record.nextRunAt = nil
            record.answeredAt = now
            try record.update(db)
        }
    }
}

extension TaskConversationStore {
    // MARK: The archive's record

    /// A task's questions and answers as its file in `System/Conversations` records them, the first asked first.
    static func entries(_ db: Database, task: Int64) throws -> [ConversationTurnEntry] {
        try records(db, task: task).compactMap(ConversationTurnEntry.init)
    }

    /// Adds and updates a task's questions and answers from its file, and when `replacing` also removes those the file
    /// no longer has, keeping what the index keeps of its own (each one's trace, and when a waiting question is next
    /// tried). The task is one the index has (`ParsedRecords.apply`).
    static func restore(_ entries: [ConversationTurnEntry], task: Int64, replacing: Bool, db: Database) throws {
        let existing = Dictionary(try records(db, task: task).compactMap { r in r.id.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        if replacing {
            try db.execute(sql: "DELETE FROM search_task_turns WHERE task_id = ? AND id NOT IN (\(ArchiveRecords.ids(entries.map(\.id))))",
                           arguments: [task])
        }
        for entry in entries {
            var record = entry.record(task: task)
            if let kept = existing[entry.id] {
                record.lastTraceId = kept.lastTraceId
                record.nextRunAt = kept.state == record.state ? kept.nextRunAt : record.nextRunAt
            }
            try record.save(db)
        }
    }
}
