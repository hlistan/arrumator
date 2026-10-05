@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// Two processes on one index, as the app and `arrumatorcli` beside it (docs/architecture.md, "How the app learns of a
/// change"): what one commits, the other's observations see as soon as it is committed, told by a notification of the
/// index's own (`IndexChangeSignal`), and its own commits are no change from another.
@Suite struct IndexChangeTests {
    /// The index at `url`, as a process opens it, complete: as one rebuilt from its archive.
    private func open(_ url: URL) async throws -> AppDatabase {
        let config = try PipelineConfig.bundledDefaults()
        let (database, _) = try AppDatabase.open(at: url, config: config.database, setAsideSuffix: config.records.setAsideSuffix,
                                                 time: TestTime(.advances)) { false }
        try await database.writer.write { db in try AppDatabase.setPendingRebuild(db, nil) }
        return database
    }

    @Test(.timeLimit(.minutes(1))) func whatAnotherProcessCommitsIsSeenByThisOnesObservationsAtOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.sqlite")
        let app = try await open(url)
        // A connection of its own on the same file, as another process has: its commits are none of the app's pool's.
        let command = try await open(url)
        let others = await Collected.reading(app.othersCommits())
        #expect(await Patience.until { await others.all.count == 1 }, "a follower is told to look once as it begins listening")
        let activity = await Collected.reading(app.activity())
        #expect(await Patience.until { await !activity.all.isEmpty }, "the app follows History, as its pages do")
        let paused = try #require(try await HistoryStore(database: command, time: TestTime(.advances)).record(.paused, summary: "Paused from a terminal"))
        #expect(await Patience.until { await activity.all.last == paused },
                "the app's observation of History sees the event the other process recorded, as it does its own")
        #expect(await Patience.until { await others.all.count == 2 }, "and is told the other process committed, to wake its queues")
        let resumed = try #require(try await HistoryStore(database: app, time: TestTime(.advances)).record(.resumed, summary: "Resumed in the app"))
        let edited = try #require(try await HistoryStore(database: command, time: TestTime(.advances)).record(.paused, summary: "Paused again"))
        #expect(await Patience.until { await activity.all.last == edited } && resumed < edited, "each commit is seen, whoever made it")
        let told = await Patience.until { await others.all.count == 3 }
        let count = await others.all.count
        #expect(told && count == 3, "of which only the other process's are another's")
        await others.stop()
        await activity.stop()
    }
    @Test(.timeLimit(.minutes(1))) func aCommitMadeWhileAFollowerBeginsListeningIsNotMissed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.sqlite")
        let app = try await open(url)
        let command = try await open(url)
        // The app's writer is busy, so the follower cannot yet read how many commits others have made.
        let busy = Signal(), release = DispatchSemaphore(value: 0)
        let holding = Task {
            try await app.writer.writeWithoutTransaction { _ in
                busy.fire()
                release.wait()
            }
        }
        #expect(await Patience.until { busy.fired }, "the writer is held")
        let others = await Collected.reading(app.othersCommits())
        // The other process commits after the follower listens, and before it counts: its count holds this commit.
        _ = try await HistoryStore(database: command, time: TestTime(.advances)).record(.paused, summary: "Paused from a terminal")
        release.signal()
        try await holding.value
        #expect(await Patience.until { await others.all.count >= 1 },
                "the follower looks once it listens, so a commit its first count already holds is not lost")
        await others.stop()
    }
    @Test func everySpellingOfAnIndexsPathNamesOneNotification() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = folder.appendingPathComponent("index.sqlite")
        #expect(FileManager.default.createFile(atPath: index.path, contents: Data()))
        let link = folder.deletingLastPathComponent().appendingPathComponent("arrumator-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        defer { try? FileManager.default.removeItem(at: link) }
        let spellings = [index.path, index.resolvingSymlinksInPath().path, "/private" + index.resolvingSymlinksInPath().path,
                         link.appendingPathComponent("index.sqlite").path,
                         folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent.uppercased()).appendingPathComponent("index.sqlite").path]
        let names = Set(spellings.map { IndexChangeSignal(index: URL(fileURLWithPath: $0)).name })
        #expect(names.count == 1, "a process that opens the index through a link, /private or another case tells and hears the same: \(spellings)")
    }
}
