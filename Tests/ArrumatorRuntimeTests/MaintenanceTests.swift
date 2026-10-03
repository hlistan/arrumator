import ArrumatorCore
@testable import ArrumatorRuntime
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// What the app does every `maintenance.interval` beside pruning and trimming: it looks for the work another process
/// queued or left, which wakes no worker of the app's own.
@Suite struct MaintenanceTests {
    /// A process that ran once and has ended: no process of this Mac started at the beginning of 1970.
    static let ended = ProcessTag(pid: 1, started: 1)

    @Test func maintenanceTakesUpATaskAndAQuestionACommandLeftWhenItWasKilled() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        try home.tune("maintenance", ["interval": .number(RuntimeHome.quickly)])
        let runtime = try await home.open()
        let task = try await runtime.searchTasks.create(prompt: "phone bills")
        let question = try await runtime.conversations.ask(task.id, question: "How much?")
        await runtime.start()
        // Both queues have looked, found what they can do waiting for Ollama, and wait for nothing more.
        try #require(await Patience.until {
            let reading = (try? await runtime.searchTasks.store.task(id: task.id))?.state
            let answering = (try? await runtime.conversations.store.turn(id: question.id))?.state
            let waiting = await runtime.taskQueue.status.waitingForOllama
            return reading == .queued && answering == .queued && waiting
        }, "the queues find Ollama away")
        // A command takes both and is killed, without a word to the app's queues.
        try await runtime.database.writer.write { db in
            try db.execute(sql: "UPDATE search_tasks SET state = ?, worker = ? WHERE id = ?",
                           arguments: [SearchTaskState.interpreting.rawValue, Self.ended.description, task.id])
            try db.execute(sql: "UPDATE search_task_turns SET state = ?, worker = ? WHERE id = ?",
                           arguments: [TurnState.answering.rawValue, Self.ended.description, question.id])
        }
        let takenUp = await Patience.until {
            let reading = (try? await runtime.database.reader.read { db in try SearchTaskRecord.fetchOne(db, key: task.id) }) ?? nil
            let answering = (try? await runtime.database.reader.read { db in try TaskTurnRecord.fetchOne(db, key: question.id) }) ?? nil
            return reading?.worker == nil && reading?.state == .queued && answering?.worker == nil && answering?.state == .queued
        }
        await runtime.stop()
        #expect(takenUp, "maintenance wakes both queues, which put back in the queue what the killed command had in hand")
    }
}
