import ArrumatorCore
import ArrumatorRuntime
import Foundation
import Testing

/// Logic belongs to the archive: each archive keeps its own, with an index of its own, and switching archives brings
/// the other archive's logic with it (docs/storage.md).
@Suite struct ArchiveSwitchingTests {
    /// A scratch app home whose settings name scratch folders, never the user's archive or Incoming.
    private struct Home {
        let root: URL
        let environment: RuntimeEnvironment

        var paths: AppPaths { AppPaths.resolve(environment) }
        func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true).standardizedFileURL }
        func cleanup() { try? FileManager.default.removeItem(at: root) }

        static func make() async throws -> Home {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-runtime-\(UUID().uuidString)",
                                                                                   isDirectory: true)
            var environment = RuntimeEnvironment.current
            environment.home = root.appendingPathComponent("support").path
            environment.ollamaURL = nil
            environment.pipelineOverridePath = nil
            environment.logLevel = .error
            let home = Home(root: root, environment: environment)
            try home.paths.ensureDirectories()
            try await SettingsStore(paths: home.paths).update {
                $0.archivePath = home.folder("First").path
                $0.incomingPath = home.folder("Incoming").path
            }
            return home
        }

        /// What the app and every command do first.
        func open() async throws -> ArrumatorRuntime {
            let runtime = try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: environment, echoLogsToStderr: false)
            try await runtime.openArchive()
            return runtime
        }
    }

    @Test func eachArchiveKeepsItsOwnLogic() async throws {
        let home = try await Home.make()
        defer { home.cleanup() }
        let first = try await home.open()
        #expect(try await first.logic.current()?.followsBuiltin == true, "an archive starts with the built-in logic")
        try await first.logic.update(body: "First: everything by year.")
        try await first.records.flush()

        let second = try await first.switchArchive(to: home.folder("Second").path)
        try await second.openArchive()
        #expect(second.archive == home.folder("Second"))
        #expect(await second.settings.current.archiveURL == home.folder("Second"), "the settings name the archive switched to")
        #expect(second.index != first.index, "each archive has its own index")
        #expect(try await second.logic.current()?.followsBuiltin == true, "a folder never used as an archive starts with the built-in logic")
        try await second.logic.update(body: "Second: by sender.")
        try await second.records.flush()
        let secondFile = try #require(try await second.records.logicFileURL())
        #expect(secondFile.path.hasPrefix(home.folder("Second").path + "/"), "the logic is kept in its archive")
        #expect(try String(contentsOf: secondFile, encoding: .utf8).contains("Second: by sender."))

        let back = try await second.switchArchive(to: home.folder("First").path)
        try await back.openArchive()
        #expect(try await back.logic.current()?.body == "First: everything by year.", "switching back brings the archive's logic back")
        let switched = try await back.services.history.events(limit: 20, kinds: [.settingsChanged]).map(\.summary)
        #expect(switched.contains("Switched to the archive at \(home.folder("Second").path)"), "the switch is in the archive's history")

        let again = try await home.open()
        #expect(again.archive == home.folder("First"), "the app opens the archive last switched to")
    }

    @Test func theLogicLivesInTheArchiveSoALostIndexGetsItBack() async throws {
        let home = try await Home.make()
        defer { home.cleanup() }
        do {
            let runtime = try await home.open()
            try await runtime.logic.update(body: "Kept in the archive.")
            try await runtime.records.flush()
        }
        try FileManager.default.removeItem(at: home.paths.indexesDirectory)

        let rebuilt = try await home.open()
        #expect(rebuilt.opening == .created)
        let logic = try #require(try await rebuilt.logic.current())
        #expect(logic.body == "Kept in the archive." && !logic.followsBuiltin)
    }

    @Test func theIndexOfEarlierVersionsBecomesTheArchivesOwn() async throws {
        let home = try await Home.make()
        defer { home.cleanup() }
        let single = home.paths.supportDirectory.appendingPathComponent("arrumator.sqlite")
        do {
            let (database, _) = try AppDatabase.open(at: single, setAsideSuffix: "unreadable") { false }
            try await LogicStore(database: database, maxChars: 1_000).update(body: "Written before each archive had an index.")
        }

        let runtime = try await home.open()
        #expect(runtime.opening == .existing, "the index was moved, not rebuilt")
        #expect(try await runtime.logic.current()?.body == "Written before each archive had an index.")
        #expect(!FileManager.default.fileExists(atPath: single.path))
        #expect(FileManager.default.fileExists(atPath: runtime.index.path))
    }

    @Test func theSameFolderSpelledAnotherWayIsTheSameArchive() async throws {
        let home = try await Home.make()
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

        let other = try await again.switchArchive(to: home.folder("Other").path)
        let back = try await other.switchArchive(to: link.path)
        #expect(back.index == first.index, "reached through a link, the archive opens its own index")
        #expect(await back.settings.current.archiveURL == home.folder("Aliased"), "and is kept under the name the file system gives it")
    }

    @Test func switchingRefusesWhatCannotBeAnArchive() async throws {
        let home = try await Home.make()
        defer { home.cleanup() }
        let runtime = try await home.open()
        let file = home.root.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)
        await #expect(throws: ArchiveSwitchError.self) { _ = try await runtime.switchArchive(to: home.folder("First").path) }
        await #expect(throws: ArchiveSwitchError.self) { _ = try await runtime.switchArchive(to: file.path) }
        await #expect(throws: ArchiveSwitchError.self, "its files would be filed again") {
            _ = try await runtime.switchArchive(to: home.folder("Incoming").appendingPathComponent("Archive").path)
        }
        #expect(await runtime.settings.current.archiveURL == home.folder("First"), "a refused switch changes nothing")
    }
}
