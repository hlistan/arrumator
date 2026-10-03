@testable import ArrumatorCore
import ArrumatorRuntime
import ArrumatorTesting
import Foundation
import Testing

/// A change to the settings is recorded in History once, by the one writer of settings events (`SettingsActions`),
/// however many parts of the running app follow it (AGENTS.md §4.4).
@Suite struct SettingsEventTests {
    @Test func aSettingChangedWhileTheAppRunsIsRecordedOnceNotTwice() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let runtime = try await home.open()
        await runtime.start()
        let elsewhere = home.folder("Elsewhere")
        try await runtime.settingsActions.change(summary: "Incoming elsewhere") { $0.incomingPath = elsewhere.path }
        #expect(await Patience.until { FileManager.default.fileExists(atPath: elsewhere.path) },
                "the running app follows the change: it watches the new Incoming, which it makes")
        try await runtime.useOllama(at: "http://localhost:9")
        let again = home.folder("Again")
        try await runtime.settingsActions.change(summary: "Incoming again") { $0.incomingPath = again.path }
        // The app follows changes in the order they were made, so once it watches this folder it has followed them all.
        #expect(await Patience.until { FileManager.default.fileExists(atPath: again.path) }, "and every change after it")
        let events = try await runtime.services.history.events(limit: 20, kinds: [.settingsChanged])
        #expect(events.map(\.summary).sorted() == ["Incoming again", "Incoming elsewhere", "Ollama at http://localhost:9"],
                "each change is in History once, in its own words, and the running app records none of its own: \(events.map(\.summary))")
        await runtime.stop()
    }

    @Test func aSettingThatCannotBeAppliedKeepsNoOtherFromWorkingAndIsRecordedOnce() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        // Incoming is a file, so it can be neither made nor watched.
        let incoming = home.folder("Incoming")
        try Data("not a folder".utf8).write(to: incoming)
        let runtime = try await home.open()
        await runtime.start()
        #expect(await Patience.until { (try? await runtime.database.meta(ArchiveWatcher.deviceKey)) != nil },
                "the archive is watched all the same, as each setting is applied on its own")
        try await runtime.settingsActions.change(TestSettingChange.make)
        let watched = home.folder("Watched")
        try await runtime.settingsActions.change(summary: "Incoming watched") { $0.incomingPath = watched.path }
        // The app follows changes in the order they were made, so once it watches this folder it has applied them all.
        #expect(await Patience.until { FileManager.default.fileExists(atPath: watched.path) }, "and Incoming is, once it can be")
        let failures = try await runtime.services.history.events(limit: 20, kinds: [.error])
        #expect(failures.count == 1 && failures.first?.summary.contains(incoming.path) == true,
                "that Incoming was not watched is in History, once, though the settings were applied again meanwhile: \(failures.map(\.summary))")
        await runtime.stop()
    }
}
