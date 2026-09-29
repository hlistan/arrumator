import ArrumatorCore
import ArrumatorRuntime
import Foundation
import Testing

/// What the app learns belongs to the archive: each keeps its own senders and history, with an index of its own, and
/// switching archives brings the other archive's with it (docs/storage.md).
@Suite struct ArchiveSwitchingTests {
    @Test func eachArchiveKeepsItsOwnSenders() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let first = try await home.open()
        try await first.senders.saveCorrespondent(Correspondent(canonicalName: "EDP Comercial", origin: .learned))
        try await first.records.flush()

        let second = try await first.switchArchive(to: home.folder("Second").path)
        try await second.openArchive()
        #expect(second.archive == home.folder("Second"))
        #expect(await second.settings.current.archiveURL == home.folder("Second"), "the settings name the archive switched to")
        #expect(second.index != first.index, "each archive has its own index")
        #expect(try await second.senders.correspondents().isEmpty, "nothing learned in one archive advises another")
        try await second.senders.saveCorrespondent(Correspondent(canonicalName: "MEO", origin: .learned))
        try await second.records.flush()
        let layout = second.services.layout(await second.settings.current)
        #expect(layout.senders.path.hasPrefix(home.folder("Second").path + "/"), "the senders are kept in their archive")
        #expect(try String(contentsOf: layout.senders, encoding: .utf8).contains("MEO"))

        let back = try await second.switchArchive(to: home.folder("First").path)
        try await back.openArchive()
        #expect(try await back.senders.correspondents().map(\.canonicalName) == ["EDP Comercial"],
                "switching back brings the archive's senders back")
        let switched = try await back.services.history.events(limit: 20, kinds: [.settingsChanged]).map(\.summary)
        #expect(switched.contains("Switched to the archive at \(home.folder("Second").path)"), "the switch is in the archive's history")

        let again = try await home.open()
        #expect(again.archive == home.folder("First"), "the app opens the archive last switched to")
    }

    @Test func theSendersLiveInTheArchiveSoALostIndexGetsThemBack() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        do {
            let runtime = try await home.open()
            try await runtime.senders.saveCorrespondent(Correspondent(canonicalName: "EDP Comercial", aliases: ["EDP"], origin: .learned))
            try await runtime.records.flush()
        }
        try FileManager.default.removeItem(at: home.paths.indexesDirectory)

        let rebuilt = try await home.open()
        #expect(rebuilt.opening == .created)
        #expect(try await rebuilt.senders.correspondents().map(\.aliases) == [["EDP"]])
    }

    @Test func theIndexOfEarlierVersionsBecomesTheArchivesOwn() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let single = home.paths.supportDirectory.appendingPathComponent("arrumator.sqlite")
        do {
            let (database, _) = try AppDatabase.open(at: single, setAsideSuffix: "unreadable") { false }
            try await SenderStore(database: database).saveCorrespondent(Correspondent(canonicalName: "Written before", origin: .learned))
        }

        let runtime = try await home.open()
        #expect(runtime.opening == .existing, "the index was moved, not rebuilt")
        #expect(try await runtime.senders.correspondents().map(\.canonicalName) == ["Written before"])
        #expect(!FileManager.default.fileExists(atPath: single.path))
        #expect(FileManager.default.fileExists(atPath: runtime.index.path))
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

        let other = try await again.switchArchive(to: home.folder("Other").path)
        let back = try await other.switchArchive(to: link.path)
        #expect(back.index == first.index, "reached through a link, the archive opens its own index")
        #expect(await back.settings.current.archiveURL == home.folder("Aliased"), "and is kept under the name the file system gives it")
    }

    @Test func switchingRefusesWhatCannotBeAnArchive() async throws {
        let home = try await RuntimeHome.make()
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
