@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// The index's database: what it tells those who watch it, and the files it is kept in.
@Suite struct AppDatabaseTests {
    /// A clock whose sleeps last until the test ends them, saying how long each was asked to be: a wait that is missing,
    /// or one that ends by itself, shows.
    private final class HeldTime: TimeSource {
        private let state = Mutex<(asked: [Double], held: [CheckedContinuation<Void, Never>])>(([], []))

        func now() -> Date { TestTime.start }

        var asked: [Double] { state.withLock { $0.asked } }

        func sleep(seconds: Double) async throws {
            await withCheckedContinuation { continuation in
                state.withLock {
                    $0.asked.append(seconds)
                    $0.held.append(continuation)
                }
            }
            try Task.checkCancellation()
        }

        /// Ends every sleep under way.
        func end() {
            let held = state.withLock { state in
                defer { state.held = [] }
                return state.held
            }
            for sleep in held { sleep.resume() }
        }
    }

    private struct ReadFailed: Error {}

    @Test(.timeLimit(.minutes(1)))
    func anObservationThatFailsIsObservedAgainAfterTheConfiguredWait() async throws {
        let time = HeldTime()
        defer { time.end() }
        let config = try PipelineConfig.bundledDefaults().database
        let database = try AppDatabase.inMemory(time: time)
        try await database.writer.write { db in try db.execute(sql: "CREATE TABLE probe (failing INTEGER NOT NULL)") }
        // What is watched cannot be read while a row says so, as a database that fails for a while.
        let observation = ValueObservation.tracking { db -> Int in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM probe WHERE failing = 1)") == true { throw ReadFailed() }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe") ?? 0
        }
        var values = database.values(of: observation, named: "probe").makeAsyncIterator()
        #expect(await values.next() == 0, "the value now comes first")
        try await database.writer.write { db in try db.execute(sql: "INSERT INTO probe (failing) VALUES (1)") }
        #expect(await Patience.until { time.asked == [config.observationRetry] },
                "a read that fails is followed by a wait of database.observationRetry seconds, not by the end of the stream: \(time.asked)")
        try await database.writer.write { db in try db.execute(sql: "UPDATE probe SET failing = 0") }
        time.end()
        #expect(await values.next() == 1, "after the wait, it is observed again, from the value it has then")
        try await database.writer.write { db in try db.execute(sql: "INSERT INTO probe (failing) VALUES (0)") }
        #expect(await values.next() == 2, "and every change after is told as before")
    }

    @Test func theIndexOfEarlierVersionsIsMovedWholeWhateverItsLogHeld() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(supportDirectory: root.appendingPathComponent("support"), logsDirectory: root.appendingPathComponent("logs"))
        try paths.ensureDirectories()
        let config = try PipelineConfig.bundledDefaults()
        func open(_ url: URL) throws -> AppDatabase {
            try AppDatabase.open(at: url, config: config.database, setAsideSuffix: config.records.setAsideSuffix, time: TestTime(.advances)) { false }.0
        }
        // The one index of an earlier version as a stop left it: its last change only in its write-ahead log. Earlier
        // versions never marked an index to be rebuilt.
        let live = root.appendingPathComponent("live.sqlite")
        let database = try open(live)
        try await database.writer.write { db in try AppDatabase.setPendingRebuild(db, nil) }
        try await HistoryStore(database: database, time: TestTime(.advances)).record(.paused, summary: "Only in the log")
        for suffix in [""] + AppDatabase.companionSuffixes {
            try FileManager.default.copyItem(atPath: live.path + suffix, toPath: paths.singleIndexURL.path + suffix)
        }
        let index = paths.indexesDirectory.appendingPathComponent("archive.sqlite")
        #expect(try paths.moveSingleIndex(to: index), "it becomes the archive's index")
        // As if a stop had come between moving the database and the files beside it, which the move must not depend on.
        for suffix in AppDatabase.companionSuffixes where FileManager.default.fileExists(atPath: index.path + suffix) {
            try FileManager.default.removeItem(atPath: index.path + suffix)
        }
        let moved = try await HistoryStore(database: try open(index), time: TestTime(.advances)).events(limit: 10).map(\.summary)
        #expect(moved == ["Only in the log"], "the database file alone holds everything it held: \(moved)")
        #expect(!FileManager.default.fileExists(atPath: paths.singleIndexURL.path), "and nothing is left where it was")
    }
}
