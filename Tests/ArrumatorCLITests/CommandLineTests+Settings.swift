@testable import ArrumatorCore
import Foundation
import Testing

/// Settings given together, as the command line changes them, and settings an earlier version saved that it mends.
extension CommandLineTests {
    /// Every option of `settings` is one change, checked whole before anything is saved: one refused, here an Incoming
    /// that holds the archive, refuses those given beside it, the profile among them.
    @Test func settingsGivenTogetherAreSavedTogetherOrNotAtAll() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let (file, incoming) = (try Data(contentsOf: home.support.appendingPathComponent("settings.json")), home.root.path)
        let refused = try run(home, ["settings", "--profile", "smart", "--rename-files", "false", "--paused", "true", "--incoming", incoming])
        #expect(refused.status == 1 && refused.stderr.contains("archivePath “\(home.archive.path)”") && refused.stderr.contains("incomingPath “\(incoming)”"),
                "the command fails, naming both folders: \(refused.stderr)")
        #expect(try Data(contentsOf: home.support.appendingPathComponent("settings.json")) == file, "and nothing given is saved")
        #expect(try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json"]).stdout).isEmpty, "nor recorded, the pause among them")
        let tooShort = try run(home, ["settings", "--rename-files", "false", "--trace-retention-days", "0"])
        #expect(tooShort.status == 1 && tooShort.stderr.contains("traceRawRetentionDays"), "a retention the app does not offer is refused: \(tooShort.stderr)")
        #expect(try settings(home).renameFiles, "with what was given beside it")
    }

    @Test func whetherImagesAreDescribedAndWhichOllamaIsStartedAreSetFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let program = home.root.appendingPathComponent("bin/ollama").path
        let set = try run(home, ["settings", "--json", "--describe-images", "false", "--ollama-binary", program])
        let changed = try JSON.decoder.decode(AppSettings.self, from: set.stdout)
        #expect(set.status == 0 && !changed.enableVLM && changed.ollamaBinaryPath == program, "both are set: \(set.stderr)")
        #expect(try settings(home).ollamaBinaryPath == program, "and saved")
        let cleared = try run(home, ["settings", "--ollama-binary", ""])
        #expect(try cleared.status == 0 && (try settings(home)).ollamaBinaryPath == nil, "an empty path looks for Ollama where it is installed again")
        let summaries = try settingsEvents(home).map(\.summary).sorted()
        #expect(summaries == ["Changed enableVLM to false, ollamaBinaryPath to \(program)", "Changed ollamaBinaryPath to null"], "each recorded: \(summaries)")
    }

    /// Settings an earlier version saved that this one cannot run with, written into the scratch home's `settings.json`.
    private func upgrade(_ home: Home, _ settings: [String: JSONValue]) throws {
        let url = home.support.appendingPathComponent("settings.json")
        guard case var .object(saved) = try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: url)) else { throw CocoaError(.fileReadCorruptFile) }
        for (key, value) in settings { saved[key] = value }
        try JSON.encoder.encode(JSONValue.object(saved)).write(to: url)
    }

    /// Settings an earlier version let be saved, Incoming kept inside the archive, stop every command naming the file
    /// and what mends it, and `settings` mends them.
    @Test func incomingKeptInsideTheArchiveByAnEarlierVersionIsMendedFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let file = home.support.appendingPathComponent("settings.json").path
        try upgrade(home, ["incomingPath": .string(home.archive.appendingPathComponent("Inbox").path)])
        let stopped = try run(home, ["history", "--json"])
        #expect(stopped.status == 1 && stopped.stderr.contains(file) && stopped.stderr.contains("arrumatorcli settings"),
                "a command stops naming the file and what mends it: \(stopped.stderr)")
        let unmended = try run(home, ["settings", "--rename-files", "false"])
        #expect(unmended.status == 1 && unmended.stderr.contains(file) && unmended.stderr.contains("incomingPath"),
                "settings that leave it as it is are refused, naming what is left: \(unmended.stderr)")
        let incoming = home.root.appendingPathComponent("Incoming").path
        let mended = try run(home, ["settings", "--json", "--incoming", incoming])
        #expect(try mended.status == 0 && (try settings(home)).incomingPath == incoming, "another Incoming mends them: \(mended.stderr)")
        #expect(try settingsEvents(home).map(\.summary) == ["Changed incomingPath to \(incoming)"], "and the change is recorded")
    }

    @Test func aRetentionAnEarlierVersionAcceptedIsMendedFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        try upgrade(home, ["traceRawRetentionDays": .number(5_000)])
        let stopped = try run(home, ["doctor", "--json"])
        #expect(stopped.status == 1 && stopped.stderr.contains("traceRawRetentionDays") && stopped.stderr.contains("settings.json"),
                "the doctor stops naming the setting and the file: \(stopped.stderr)")
        let mended = try run(home, ["settings", "--trace-retention-days", "30"])
        #expect(try mended.status == 0 && (try settings(home)).traceRawRetentionDays == 30, "a retention the app offers mends them: \(mended.stderr)")
        #expect(try run(home, ["doctor", "--json"]).stderr.isEmpty, "and every command runs again")
    }

    @Test func anEmptyIncomingIsRefusedRatherThanTakenForTheFolderTheCommandRunsIn() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let before = try settings(home)
        let refused = try run(home, ["settings", "--incoming", ""])
        #expect(refused.status != 0 && refused.stderr.contains("--incoming needs a folder"), "the option is refused: \(refused.stderr)")
        #expect(try settings(home).incomingPath == before.incomingPath, "and Incoming is as it was")
    }

    /// An archive named by a partial path is refused before anything uses it, even by `settings`, which cannot mend it:
    /// no index is made for wherever the command runs.
    @Test func anArchiveNamedByAPartialPathIsRefusedBeforeAnythingUsesIt() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        try upgrade(home, ["archivePath": .string("Archive")])
        let refused = try run(home, ["settings", "--incoming", home.root.appendingPathComponent("Incoming").path])
        #expect(refused.status == 1 && refused.stderr.contains("archivePath “Archive”") && refused.stderr.contains("Correct archivePath in that file")
                    && refused.stderr.contains(home.support.appendingPathComponent("settings.json").path),
                "the command stops, naming the setting, the file and what mends it: \(refused.stderr)")
        let indexes = (try? FileManager.default.contentsOfDirectory(atPath: home.support.appendingPathComponent("Indexes").path)) ?? []
        #expect(indexes.isEmpty, "and no index is made: \(indexes)")
    }
}
