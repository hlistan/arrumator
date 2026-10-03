@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What the command line does on an archive it cannot read whole: one whose index's rebuild is refused for a record
/// file that cannot be read, and one whose folder is away. Every command stops, naming why, but `settings` and
/// `archive switch`, which go on as the app does (docs/cli.md).
extension CommandLineTests {
    @Test func aSettingIsChangedOnAnArchiveWhoseIndexIsRefusedAndRecordedOnceItIsRebuilt() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let listing = try writeList(TestRecordFiles.brokenList, in: home.archive)
        let changed = try run(home, ["settings", "--json", "--rename-files", "false"])
        let saved = try JSON.decoder.decode(AppSettings.self, from: changed.stdout)
        #expect(changed.status == 0 && !saved.renameFiles && changed.stderr.contains(listing.path),
                "the setting is changed, as the app changes it, and the command says why the index is not rebuilt: \(changed.stderr)")
        try TestRecordFiles.emptyList.write(to: listing, atomically: true, encoding: .utf8)
        #expect(try settingsEvents(home).map(\.summary) == [TestSettingChange.summary], "once it is rebuilt, the change is in its History, once")
    }

    @Test func anArchiveWhoseIndexIsRefusedIsSwitchedAwayFromAndRecordsItOnceItIsRebuilt() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let listing = try writeList(TestRecordFiles.brokenList, in: home.archive)
        let second = home.root.appendingPathComponent("Second", isDirectory: true)
        let switched = try run(home, ["archive", "switch", second.path, "--json"])
        let summary = try JSONSerialization.jsonObject(with: switched.stdout) as? [String: String]
        #expect(switched.status == 0 && summary?["archive"] == second.path, "the switch is made, as the app makes it: \(switched.stderr)")
        try TestRecordFiles.emptyList.write(to: listing, atomically: true, encoding: .utf8)
        #expect(try run(home, ["archive", "switch", home.archive.path]).status == 0, "and the user can switch back once it is corrected")
        #expect(try settingsEvents(home).map(\.summary) == ["Switched to the archive at \(second.path)"], "where the switch away is in its History once")
    }

    @Test func noCommandMakesTheArchivesFolderButASwitchToIt() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        // The settings name an archive whose folder is not there, which no command can tell from one away.
        try FileManager.default.removeItem(at: home.archive)
        let history = try run(home, ["history", "--json"])
        #expect(history.status == 1 && history.stderr.contains(home.archive.path), "a command says the folder is not there: \(history.stderr)")
        #expect(!FileManager.default.fileExists(atPath: home.archive.path), "and makes none")
        let new = home.root.appendingPathComponent("New", isDirectory: true)
        let switched = try run(home, ["archive", "switch", new.path])
        #expect(switched.status == 0 && FileManager.default.fileExists(atPath: new.path),
                "a switch to a folder that is not there makes it, for a new archive: \(switched.stderr)")
        #expect(try run(home, ["history", "--json"]).status == 0, "on which every command then runs")
    }

    @Test func anArchiveWhoseFolderIsAwayStopsEveryCommandButASettingOrASwitchAndIsNeverMadeAgain() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        _ = try file(home, [("a.txt", [DocumentLabel(kind: .type, value: "invoice")])])
        #expect(try run(home, ["history", "--json"]).status == 0, "the index is made and holds the archive's document")
        // The disk the archive is on is taken out.
        let away = home.root.appendingPathComponent("Away", isDirectory: true)
        try FileManager.default.moveItem(at: home.archive, to: away)
        let history = try run(home, ["history", "--json"])
        #expect(history.status == 1 && history.stderr.contains(home.archive.path), "a command on it stops, naming the folder: \(history.stderr)")
        let changed = try run(home, ["settings", "--json", "--rename-files", "false"])
        #expect(changed.status == 0 && changed.stderr.contains(home.archive.path), "a setting is changed all the same: \(changed.stderr)")
        let second = home.root.appendingPathComponent("Second", isDirectory: true)
        #expect(try run(home, ["archive", "switch", second.path]).status == 0, "and the user can switch to another archive")
        #expect(!FileManager.default.fileExists(atPath: home.archive.path), "no command made a folder where the archive was")

        try FileManager.default.moveItem(at: away, to: home.archive)
        #expect(try run(home, ["archive", "switch", home.archive.path]).status == 0, "once it is back, the user switches to it again")
        let recorded = try settingsEvents(home).map(\.summary)
        #expect(recorded.contains(TestSettingChange.summary) && recorded.contains("Switched to the archive at \(second.path)"),
                "and what was changed while it was away is in its History: \(recorded)")
    }
}
