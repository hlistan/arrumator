@testable import ArrumatorCore
@testable import ArrumatorRuntime
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// The app beside `arrumatorcli` (the QA run of 4 October 2026): what a command commits to the index reaches the running
/// app as soon as it commits, never at the app's next start or `maintenance.interval`, an hour later. The command is a
/// runtime of its own on the same index, with a database pool of its own, as another process has.
@Suite struct OtherProcessTests {
    /// Whether the app's search task queue has taken up task `id`: each attempt at it starts its trace.
    private func taken(_ id: Int64, by app: ArrumatorRuntime) async -> Bool {
        let record = (try? await app.database.reader.read { db in try SearchTaskRecord.fetchOne(db, key: id) }) ?? nil
        return record?.lastTraceId != nil
    }

    @Test func aTaskACommandQueuesIsTakenUpByTheRunningAppAtOnceAndItsPagesSeeIt() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let app = try await home.open()
        await app.start()
        let activity = await Collected.reading(app.database.activity())
        // As `arrumatorcli tasks new --queue-only` beside the app: queued, and read by nothing of its own.
        let command = try await home.open()
        let first = try await command.searchTasks.create(prompt: "phone bills").id
        #expect(await Patience.until { await taken(first, by: app) }, "the app's queue takes up a task the command queued")
        // Taken up, however it was: by the app's first maintenance round, or by what the command committed. The next is
        // queued after that round, which comes again only after `maintenance.interval`. No Ollama answers here, so the
        // first waits for it, and no other is read until it is tried again (`ModelQueue.ollamaRetryAt`): the app knows
        // of the next at once, and says it waits for Ollama too.
        _ = try await command.searchTasks.create(prompt: "water bills").id
        #expect(await Patience.until {
                    let status = await app.taskQueue.status
                    return status.queued == 2 && status.waitingForOllama
                },
                "and of the next one at once, not at its next maintenance round an hour later")
        let asked = try await app.services.history.events(limit: 1, kinds: [.taskCreated]).first?.id
        #expect(await Patience.until { await activity.all.last == asked },
                "the app's pages, which follow History, see what the command recorded, as a forgotten rule or labels it changed")
        await activity.stop()
        await command.stop()
        await app.stop()
    }
}
