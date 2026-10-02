import ArrumatorCore
@testable import ArrumatorRuntime
import ArrumatorTesting
import Foundation
import Testing

/// Each archive keeps its own documents and history, with an index of its own, and switching archives brings the
/// other archive's with it (docs/storage.md).
@Suite struct ArchiveSwitchingTests {
    private func marks(_ runtime: ArrumatorRuntime) async throws -> [String] {
        try await runtime.services.history.events(limit: 50, kinds: [.paused]).map(\.summary)
    }

    @Test func eachArchiveKeepsItsOwnHistory() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let first = try await home.open()
        try await first.services.history.record(.paused, summary: "In the first archive")
        try await first.records.flush()

        let second = try await first.switchArchive(to: home.folder("Second").path).runtime
        try await second.openArchive()
        #expect(second.archive == home.folder("Second"), "the runtime opens the archive switched to")
        #expect(await second.settings.current.archiveURL == home.folder("Second"), "the settings name the archive switched to")
        #expect(second.index != first.index, "each archive has its own index")
        #expect(try await marks(second).isEmpty, "one archive's history is not another's")
        try await second.services.history.record(.paused, summary: "In the second archive")
        try await second.records.flush()
        let layout = second.services.layout(await second.settings.current)
        #expect(layout.history.path.hasPrefix(home.folder("Second").path + "/"), "the history is kept in its archive")

        let back = try await second.switchArchive(to: home.folder("First").path).runtime
        try await back.openArchive()
        #expect(try await marks(back) == ["In the first archive"], "switching back brings the archive's history back")
        let switched = try await back.services.history.events(limit: 20, kinds: [.settingsChanged]).map(\.summary)
        #expect(switched.contains("Switched to the archive at \(home.folder("Second").path)"), "the switch is in the archive's history")

        let again = try await home.open()
        #expect(again.archive == home.folder("First"), "the app opens the archive last switched to")
    }

    @Test func theHistoryLivesInTheArchiveSoALostIndexGetsItBack() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        do {
            let runtime = try await home.open()
            try await runtime.services.history.record(.paused, summary: "Kept in the archive")
            try await runtime.records.flush()
        }
        try FileManager.default.removeItem(at: home.paths.indexesDirectory)

        let rebuilt = try await home.open()
        #expect(rebuilt.opening == .created, "a lost index is made anew")
        #expect(try await marks(rebuilt) == ["Kept in the archive"], "and the history comes back from the archive")
    }

    @Test func theIndexOfEarlierVersionsBecomesTheArchivesOwn() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let single = home.paths.supportDirectory.appendingPathComponent("arrumator.sqlite")
        do {
            let config = try PipelineConfig.bundledDefaults()
            let (database, _) = try AppDatabase.open(at: single, config: config.database, setAsideSuffix: config.records.setAsideSuffix,
                                                     time: TestTime(.advances)) { false }
            try await HistoryStore(database: database, time: TestTime(.advances)).record(.paused, summary: "Written before")
        }

        let runtime = try await home.open()
        #expect(runtime.opening == .existing, "the index was moved, not rebuilt")
        #expect(try await marks(runtime) == ["Written before"], "its history comes with it")
        #expect(!FileManager.default.fileExists(atPath: single.path), "the old index is not left behind")
        #expect(FileManager.default.fileExists(atPath: runtime.index.path), "it is the archive's own index now")
    }

    @Test func theSameFolderSpelledAnotherWayIsTheSameArchive() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        // The temporary folder lives under /private/var, reached as /var; the archive does not exist yet.
        let aliased = "/private" + home.folder("Aliased").path
        try await SettingsStore(paths: home.paths).update { $0.archivePath = aliased }
        let first = try await home.open()
        let again = try await home.open()
        #expect(again.index == first.index && again.opening == .existing, "one folder has one index, before and after it exists")
        await #expect(throws: ArchiveSwitchError.self, "another spelling of the archive is the archive") {
            _ = try await again.switchArchive(to: home.folder("Aliased").path)
        }
        let link = home.root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: aliased))
        await #expect(throws: ArchiveSwitchError.self, "and so is a link to it") { _ = try await again.switchArchive(to: link.path) }

        let other = try await again.switchArchive(to: home.folder("Other").path).runtime
        let back = try await other.switchArchive(to: link.path).runtime
        #expect(back.index == first.index, "reached through a link, the archive opens its own index")
        #expect(await back.settings.current.archiveURL == home.folder("Aliased"), "and is kept under the name the file system gives it")
    }

    /// The jobs the ingest queue holds, by the name of their file.
    private func queued(_ runtime: ArrumatorRuntime) async throws -> [String] {
        try await runtime.services.jobs.active().map { URL(fileURLWithPath: $0.sourcePath).lastPathComponent }.sorted()
    }

    @Test func aSwitchThatFailsLeavesTheAppOnItsArchiveRunningWithItsQueueAndNothingRecorded() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        try home.watchQuickly()
        let runtime = try await home.open()
        await runtime.start()
        try await runtime.setPaused(true)
        try Data(Self.waiting.utf8).write(to: home.folder("Incoming").appendingPathComponent(Self.before))
        #expect(try await Patience.until { try await queued(runtime) == [Self.before] }, "a file waits in Incoming, paused")

        // The settings cannot be saved, so the archive cannot be switched to; the next archive's index can be made.
        try home.setWritable(false, home.paths.supportDirectory, withFoldersInIt: false)
        let refused = await #expect(throws: CocoaError.self, "the switch fails") {
            _ = try await runtime.switchArchive(to: home.folder("Second").path)
        }
        try home.setWritable(true, home.paths.supportDirectory, withFoldersInIt: false)
        #expect(refused?.code == .fileWriteNoPermission, "as the settings could not be saved")

        #expect(try await SettingsStore(paths: home.paths).current.archiveURL == home.folder("First"), "the app stays on its archive")
        let switched = try await runtime.services.history.events(limit: 20, kinds: [.settingsChanged]).map(\.summary)
        #expect(!switched.contains { $0.hasPrefix("Switched") }, "and History records no switch that did not happen: \(switched)")
        try Data(Self.waiting.utf8).write(to: home.folder("Incoming").appendingPathComponent(Self.after))
        #expect(try await Patience.until { try await queued(runtime) == [Self.after, Self.before] },
                "it still watches Incoming, and the file that waited still waits with its place in the queue")
        await runtime.stop()
    }

    @Test func anArchiveThatCannotBeWrittenToIsSwitchedAwayFromAndSaysSoOnceItCanBe() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let first = try await home.open()
        try home.setWritable(false, home.folder("First"), withFoldersInIt: true)
        defer { try? home.setWritable(true, home.folder("First"), withFoldersInIt: true) }
        let switched = try await first.switchArchive(to: home.folder("Second").path)
        let second = switched.runtime
        try await second.openArchive()
        #expect(try await SettingsStore(paths: home.paths).current.archiveURL == home.folder("Second"),
                "an archive whose disk cannot be written to does not keep the user from switching away from it")
        #expect(switched.unwritten?.archive == home.folder("First").path,
                "and the user is told whose record files wait to be written: \(switched.unwritten?.note ?? "nothing")")
        let recorded = try await first.services.history.events(limit: 20, kinds: [.settingsChanged]).map(\.summary)
        #expect(recorded.contains("Switched to the archive at \(home.folder("Second").path)"), "the switch is in the archive's index")

        try home.setWritable(true, home.folder("First"), withFoldersInIt: true)
        let back = try await second.switchArchive(to: home.folder("First").path).runtime
        try await back.openArchive()
        let history = back.services.layout(await back.settings.current).history
        let files = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
        let written = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(written.contains("Switched to the archive at \(home.folder("Second").path)"),
                "the switch is written into the archive's history once it can be: it was kept in its index meanwhile")
    }

    /// Holds `runtime`'s stop, as a page being read or a file being moved holds it, until `letGo` fires; `stopped` fires
    /// once the stop has begun.
    private func holdStop(_ runtime: ArrumatorRuntime, stopped: Signal, letGo: OneShot<Void>) async {
        await runtime.tasks.run(Self.lingering) {
            await withTaskCancellationHandler { await letGo.wait() } onCancel: { stopped.fire() }
        }
    }

    @Test func aSettingChangedWhileASwitchStopsTheAppIsKeptAndTheSettingsNameTheArchiveSwitchedTo() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        let first = try await home.open()
        await first.start()
        let (stopped, letGo) = (Signal(), OneShot<Void>())
        await holdStop(first, stopped: stopped, letGo: letGo)
        let switching = Task { try await first.switchArchive(to: home.folder("Second").path) }
        try #require(await Patience.until { stopped.fired }, "the switch stops the app's work")
        // The user pauses from the menu bar meanwhile, through the runtime the app still has.
        try await first.setPaused(true)
        letGo.fire(())
        let second = try await switching.value.runtime
        let saved = await (try SettingsStore(paths: home.paths)).current
        let inUse = await second.settings.current
        #expect(saved.archiveURL == home.folder("Second"), "the settings on disk name the archive the app now runs on")
        #expect(saved.paused && inUse.paused,
                "and keep the pause made meanwhile, which the runtime switched to has too: one store holds the settings")
    }

    @Test func aSwitchWhoseSettingsCannotBeSavedOnceRecordedSaysTheAppStayedAndStartsItAgain() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        try home.watchQuickly()
        let first = try await home.open()
        await first.start()
        let (stopped, letGo) = (Signal(), OneShot<Void>())
        await holdStop(first, stopped: stopped, letGo: letGo)
        let switching = Task { try await first.switchArchive(to: home.folder("Second").path) }
        try #require(await Patience.until { stopped.fired }, "the switch stops the app's work")
        // The settings could be saved when the switch began, and can no longer be once it has stopped the work.
        try home.setWritable(false, home.paths.supportDirectory, withFoldersInIt: false)
        letGo.fire(())
        let refused = await #expect(throws: CocoaError.self, "the switch fails") { _ = try await switching.value }
        try home.setWritable(true, home.paths.supportDirectory, withFoldersInIt: false)
        #expect(refused?.code == .fileWriteNoPermission, "as the settings could not be saved")

        #expect(try await SettingsStore(paths: home.paths).current.archiveURL == home.folder("First"), "the app stays on its archive")
        let recorded = try await first.services.history.events(limit: 20, kinds: [.settingsChanged]).map(\.summary)
        #expect(recorded.contains("Switched to the archive at \(home.folder("Second").path)")
                    && recorded.contains { $0.hasPrefix("Stayed on the archive at \(home.folder("First").path): ") },
                "History says the switch it recorded did not happen, and why: \(recorded)")
        try Data(Self.waiting.utf8).write(to: home.folder("Incoming").appendingPathComponent(Self.after))
        #expect(try await Patience.until { try await queued(first) == [Self.after] }, "and the app works on, watching Incoming again")
        await first.stop()
    }

    static let lingering = "lingering"
    static let before = "before.txt"
    static let after = "after.txt"
    static let waiting = "a document waiting in Incoming"

    @Test func switchingRefusesWhatCannotBeAnArchive() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let runtime = try await home.open()
        let file = home.root.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)
        await #expect(throws: ArchiveSwitchError.self, "the archive already open is no switch") {
            _ = try await runtime.switchArchive(to: home.folder("First").path)
        }
        await #expect(throws: ArchiveSwitchError.self, "a file is no archive") { _ = try await runtime.switchArchive(to: file.path) }
        await #expect(throws: ArchiveSwitchError.self, "its files would be filed again") {
            _ = try await runtime.switchArchive(to: home.folder("Incoming").appendingPathComponent("Archive").path)
        }
        #expect(await runtime.settings.current.archiveURL == home.folder("First"), "a refused switch changes nothing")
    }
}
