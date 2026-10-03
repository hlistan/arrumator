@testable import ArrumatorCore
@testable import ArrumatorRuntime
import ArrumatorTesting
import Foundation
import Testing

/// A switch of archives that fails once it has stopped the runtime starts it again as it was (docs/storage.md, One index
/// per archive): it reads the archive first if it was being read, and starts nothing once the app has stopped it for good.
@Suite struct FailedSwitchTests {
    /// How many times the runtime started, as History says: each start records one event.
    private func starts(_ runtime: ArrumatorRuntime) async throws -> Int {
        try await runtime.services.history.events(limit: 10, kinds: [.appStarted]).count
    }

    /// Holds the writing of the record of a switch, as a slow disk holds it, once the switch has stopped the runtime's
    /// work and recorded itself: what a test does meanwhile, the user could do then.
    private func holdTheRecordOfTheSwitch(_ runtime: ArrumatorRuntime) async -> Hold {
        let writing = Hold()
        await runtime.records.setBeforeWriting { _ in
            let switched = try? await runtime.services.history.events(limit: 1, kinds: [.settingsChanged])
            guard switched?.isEmpty == false else { return }
            await writing.arrive()
        }
        return writing
    }

    /// The jobs the ingest queue holds, in the order they are worked through.
    private func queue(_ runtime: ArrumatorRuntime) async throws -> [JobRecord] {
        try await runtime.services.jobs.active(kinds: [.ingest])
    }

    /// The names of the files of `jobs`.
    private func files(_ jobs: [JobRecord]) -> [String] {
        jobs.map { URL(fileURLWithPath: $0.sourcePath).lastPathComponent }
    }

    @Test func aSwitchThatFailsOnceItHasStoppedTheAppKeepsTheQueueAsItWas() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try home.watchQuickly()
        let runtime = try await home.open()
        await runtime.start()
        try await runtime.setPaused(true)
        try Data(Self.waiting.utf8).write(to: home.folder("Incoming").appendingPathComponent(Self.before))
        try #require(await Patience.until { try await files(queue(runtime)) == [Self.before] }, "a file waits in Incoming, paused")
        let waiting = try await queue(runtime).map(\.id)
        let writing = await holdTheRecordOfTheSwitch(runtime)
        let switching = Task { try await runtime.switchArchive(to: home.folder("Second").path) }
        try #require(await Patience.until { writing.arrivals == 1 }, "the switch has stopped the work and writes the record of it")
        try home.setWritable(false, home.paths.supportDirectory, withFoldersInIt: false)
        defer { try? home.setWritable(true, home.paths.supportDirectory, withFoldersInIt: false) }
        writing.open()
        await #expect(throws: CocoaError.self, "the switch fails, as the settings cannot be saved") { _ = try await switching.value }

        let kept = try await queue(runtime).map(\.id)
        #expect(kept == waiting, "the file waits in the job it had, with its place in the queue")
        try Data(Self.waiting.utf8).write(to: home.folder("Incoming").appendingPathComponent(Self.after))
        #expect(try await Patience.until { try await queue(runtime).count == waiting.count + 1 }, "the app watches Incoming again")
        #expect(try await files(queue(runtime)) == [Self.before, Self.after], "and the file that waited keeps its place before the next")
        await runtime.stop()
    }

    static let before = "before.txt"
    static let after = "after.txt"
    static let waiting = "a document waiting in Incoming"

    @Test func aSwitchThatFailsBeforeTheAppStartedLeavesItFreeToStart() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        // As during onboarding: the archive is open, and the app has not started the work yet.
        let runtime = try await home.open()
        let writing = await holdTheRecordOfTheSwitch(runtime)
        let switching = Task { try await runtime.switchArchive(to: home.folder("Second").path) }
        try #require(await Patience.until { writing.arrivals == 1 }, "the switch has stopped the runtime and writes the record of it")
        try home.setWritable(false, home.paths.supportDirectory, withFoldersInIt: false)
        defer { try? home.setWritable(true, home.paths.supportDirectory, withFoldersInIt: false) }
        writing.open()
        await #expect(throws: CocoaError.self, "the switch fails, as the settings cannot be saved") { _ = try await switching.value }
        #expect(try await starts(runtime) == 0, "nothing that had not started is started by the switch that failed")

        try await runtime.openAndStart()
        #expect(try await starts(runtime) == 1, "and when onboarding is done, the app opens the archive and starts the work")
        #expect(await runtime.tasks.isStarted, "which runs")
        await runtime.stop()
    }

    @Test func aSwitchThatFailsAfterTheAppQuitStartsNothingAgain() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let runtime = try await home.open()
        await runtime.start()
        // The app quits while the record of the switch is written.
        let writing = await holdTheRecordOfTheSwitch(runtime)
        let switching = Task { try await runtime.switchArchive(to: home.folder("Second").path) }
        try #require(await Patience.until { writing.arrivals == 1 }, "the switch has stopped the work and writes the record of it")
        try home.setWritable(false, home.paths.supportDirectory, withFoldersInIt: false)
        defer { try? home.setWritable(true, home.paths.supportDirectory, withFoldersInIt: false) }
        let quitting = Task { await runtime.stop() }
        try #require(await Patience.until { await runtime.records.waitingTurns == 1 },
                     "the app quits, and its stop waits for its turn to write the record files")
        writing.open()
        await #expect(throws: CocoaError.self, "the switch fails, as the settings cannot be saved") { _ = try await switching.value }
        await quitting.value
        let (started, running) = (try await starts(runtime), await runtime.tasks.isStarted)
        #expect(started == 1, "the runtime the app stopped for good is not started again by the switch, as History says")
        #expect(!running, "and nothing of it runs")
    }

    @Test func aSwitchThatFailsWhileTheArchiveIsReadReadsItBeforeTheWorkStartsAgain() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        do {
            let earlier = try await home.open()
            try await earlier.services.history.record(.paused, summary: Self.kept)
            try await earlier.records.flush()
        }
        // The index is lost: the next one is to be rebuilt from the archive before anything works on it.
        try FileManager.default.removeItem(at: home.paths.indexesDirectory)
        let runtime = try await home.bootstrap()
        let (reading, stopped, read) = (Signal(), Signal(), OneShot<Void>())
        // The archive is read as macOS reads a folder it holds behind its prompt for access: the read does not notice
        // being stopped, and ends only when it ends.
        let opening = Task {
            try await runtime.openAndStart {
                reading.fire()
                await withTaskCancellationHandler { await read.wait() } onCancel: { stopped.fire() }
            }
        }
        try #require(await Patience.until { reading.fired }, "the app reads the archive")
        let switching = Task { try await runtime.switchArchive(to: home.folder("Second").path) }
        try #require(await Patience.until { stopped.fired }, "the switch stops the reading")
        try home.setWritable(false, home.paths.supportDirectory, withFoldersInIt: false)
        defer { try? home.setWritable(true, home.paths.supportDirectory, withFoldersInIt: false) }
        read.fire(())
        await #expect(throws: CancellationError.self, "the reading the switch stopped started nothing") { try await opening.value }
        await #expect(throws: CocoaError.self, "the switch fails, as the settings cannot be saved") { _ = try await switching.value }

        let rebuilt = try await runtime.services.history.events(limit: 10, kinds: [.rebuilt]).count
        #expect(rebuilt == 1, "the archive the app stays on is read, its index rebuilt from it")
        #expect(await runtime.tasks.isStarted, "and then the work starts on it")
        #expect(try await runtime.services.history.events(limit: 10, kinds: [.paused]).map(\.summary) == [Self.kept],
                "with what its record files hold")
        await runtime.stop()
    }

    static let kept = "Kept in the archive"
}
