import Foundation
import GRDB

/// What the user does with the conversation about a search task's documents: ask about them in their own words, ask a
/// question again, stop one, or clear the conversation. Questions join a queue of their own (`TaskConversationQueue`);
/// each change reaches the task's file in the archive's `System/Conversations`. Clearing a conversation removes what the
/// user wrote, so History records it; asking does not, as the conversation keeps the question and the trace the answer.
public struct TaskConversationActions: Sendable {
    public let services: PipelineServices
    public let queue: TaskConversationQueue

    public init(services: PipelineServices, queue: TaskConversationQueue) {
        self.services = services
        self.queue = queue
    }

    public var store: TaskConversationStore { TaskConversationStore(database: services.database, time: services.time) }

    /// Asks a question about the documents of `task`, to be answered from its set as it is when the question's turn
    /// comes. A question without words, or longer than `conversation.maxQuestionChars`, is refused, and nothing is
    /// asked.
    @discardableResult
    public func ask(_ task: Int64, question: String) async throws -> TaskTurn {
        let asked = try Self.question(question, limit: services.config.conversation.maxQuestionChars)
        let now = services.time.now()
        let id = try await services.database.writer.write { db in
            guard try SearchTaskRecord.exists(db, key: task) else { throw SearchTaskError.taskNotFound(task) }
            var record = TaskTurnRecord(id: nil, taskId: task, question: asked, state: .queued, answer: nil, sourcesJson: nil, findingJson: nil,
                                        model: nil, problem: nil, lastTraceId: nil, nextRunAt: now, askedAt: now, answeredAt: nil)
            try record.insert(db)
            return record.id ?? 0
        }
        await queue.wake()
        return try await turn(id)
    }

    /// Asks a question again, answered or not, in its place in the conversation: its answer is replaced by the new one,
    /// drawn from the set as it is then. One still in the queue is refused.
    @discardableResult
    public func askAgain(_ turn: Int64) async throws -> TaskTurn {
        let now = services.time.now()
        try await services.database.writer.write { db in
            guard var record = try TaskTurnRecord.fetchOne(db, key: turn) else { throw ConversationError.turnNotFound(turn) }
            guard !record.state.isActive else { throw ConversationError.stillAnswering(turn) }
            record.requeue(at: now)
            try record.update(db)
        }
        await queue.wake()
        return try await self.turn(turn)
    }

    /// Stops a question in the queue: one being answered here keeps what came of its answer, one waiting, or being
    /// answered by another process, keeps none; each says it was stopped, and can be asked again. A question no longer in
    /// the queue is left as it is.
    public func stop(_ turn: Int64) async throws {
        // The queue answering it records it stopped, with what came of the answer, once its work has ended: told first,
        // so nothing that can fail comes before it.
        if await queue.stop(turn) { return }
        guard try await store.turn(id: turn) != nil else { throw ConversationError.turnNotFound(turn) }
        if try await store.withdraw(turn, problem: TaskConversationQueue.stoppedProblem) { await queue.wake() }
    }

    /// Removes every question about the task's documents and its answer, any being answered too, and records that in
    /// History. Returns how many there were.
    @discardableResult
    public func clear(_ task: Int64) async throws -> Int {
        await queue.forget(task: task)
        let now = services.time.now()
        let config = services.config.tasks
        let removed = try await services.database.writer.write { db -> Int in
            guard let record = try SearchTaskRecord.fetchOne(db, key: task) else { throw SearchTaskError.taskNotFound(task) }
            let removed = try TaskTurnRecord.filter(Column("task_id") == task).deleteAll(db)
            guard removed > 0 else { return 0 }
            try HistoryStore.insert(db, .taskEdited, at: now, actor: .user,
                                    summary: "Cleared the conversation about “\(SearchTaskStore.name(record, config: config))”: "
                                        + Format.count(removed, "question"),
                                    payload: TaskEventPayload(task: task, documents: nil, plan: nil))
            return removed
        }
        await queue.wake()
        return removed
    }

    private func turn(_ id: Int64) async throws -> TaskTurn {
        guard let turn = try await store.turn(id: id) else { throw ConversationError.turnNotFound(id) }
        return turn
    }

    /// The question without the space around it; one without words, or longer than `limit`, is refused.
    static func question(_ text: String, limit: Int) throws -> String {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw ConversationError.emptyQuestion }
        guard question.count <= limit else { throw ConversationError.questionTooLong(limit) }
        return question
    }
}
