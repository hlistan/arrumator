import ArrumatorCore
import ArrumatorRuntime
import Foundation
import Testing

/// Opening an archive whose index is to be rebuilt (docs/storage.md): the runtime works on no index that has not been
/// rebuilt from its archive, whoever starts it.
@Suite struct OpeningTests {
    @Test func anIndexWhoseRebuildWasRefusedStartsNothingUntilItIsRebuilt() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        let config = try PipelineConfig.bundledDefaults()
        let archive = home.folder("First")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let listing = archive.appendingPathComponent(config.records.documentsFileName)
        // The archive's list of documents, broken by hand, read by a new index.
        try "---\narrumator: 1\nentries: [unclosed\n---\n".write(to: listing, atomically: true, encoding: .utf8)

        let refused = try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: home.environment, echoLogsToStderr: false, trash: home.trash)
        await #expect(throws: RecordsError.self, "the index cannot be rebuilt without the list") { try await refused.openArchive() }
        #expect(await refused.start() == false, "and the app, which starts it all the same, starts nothing on it")
        #expect(try await refused.services.history.events(limit: 10).isEmpty, "not even to record that it started")

        // The user corrects the list, and rebuilds the index from Settings › Advanced.
        try "---\narrumator: 1\nentries: []\n---\n".write(to: listing, atomically: true, encoding: .utf8)
        try await refused.rebuildIndex()
        let kinds = try await refused.services.history.events(limit: 10).map(\.kind)
        #expect(kinds.contains(.rebuilt) && kinds.contains(.appStarted), "the index is rebuilt and the work on it starts, as History says: \(kinds)")
        try await refused.rebuildIndex()
        let started = try await refused.services.history.events(limit: 10, kinds: [.appStarted])
        #expect(started.count == 1, "and a rebuild while it runs does not start it twice")
        await refused.stop()
    }

    @Test func aRebuildStartsNothingTheAppHasNotStartedOrHasStopped() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: home.environment, echoLogsToStderr: false, trash: home.trash)
        try await runtime.openArchive()
        func started() async throws -> Int { try await runtime.services.history.events(limit: 10, kinds: [.appStarted]).count }
        // As before onboarding is done: the archive is open, and the app has started nothing on it.
        try await runtime.rebuildIndex()
        #expect(try await started() == 0, "a rebuild starts no work the app has not started")
        let began = await runtime.start()
        let afterStart = try await started()
        #expect(began && afterStart == 1, "the work starts when the app starts it")
        await runtime.stop()
        try await runtime.rebuildIndex()
        let again = await runtime.start()
        let afterStop = try await started()
        #expect(afterStop == 1 && !again, "and a rebuild after it stopped starts nothing again, nor does anything else")
    }

    @Test func aNewArchiveTakesWhatTheUserChangesBeforeItIsOpened() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        // As at onboarding: the index is made when the app starts, and the archive is opened once onboarding is done.
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: home.environment, echoLogsToStderr: false, trash: home.trash)
        try await runtime.settingsActions.change { $0.renameFiles = false }
        let changes = try await runtime.services.history.events(limit: 10, kinds: [.settingsChanged])
        #expect(changes.count == 1, "an archive with no records has nothing to read, so its new index takes the change and its event")
        try await runtime.openArchive()
    }

    @Test func anArchiveWhoseRebuildWasRefusedCanStillBeLeft() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let archive = home.folder("First")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try "---\narrumator: 1\nentries: [unclosed\n---\n".write(to: archive.appendingPathComponent(try PipelineConfig.bundledDefaults().records.documentsFileName),
                                                                    atomically: true, encoding: .utf8)
        let refused = try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: home.environment, echoLogsToStderr: false, trash: home.trash)
        await #expect(throws: RecordsError.self) { try await refused.openArchive() }
        let next = try await refused.switchArchive(to: home.folder("Second").path).runtime
        try await next.openArchive()
        let chosen = await next.settings.current.archiveURL
        #expect(next.archive == home.folder("Second") && chosen == home.folder("Second"),
                "the user can switch to another archive, though the first takes no record of it")
    }
}
