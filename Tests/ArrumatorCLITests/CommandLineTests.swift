import ArrumatorCore
import Foundation
import Testing

/// `arrumatorcli` as scripts and agents run it (AGENTS.md §4.6): the built command, in a scratch home whose settings
/// name scratch folders (§4.3) and an address where no Ollama answers, so nothing needs a model and nothing reaches the
/// user's archive. Every command's `--json` output is decoded as the contract it is.
@Suite struct CommandLineTests {
    /// Finds the built command beside this test bundle, as SwiftPM builds both into one products folder.
    private final class Marker: NSObject {}

    private struct Home {
        let root: URL
        var support: URL { root.appendingPathComponent("support", isDirectory: true) }

        static func make() throws -> Home {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-cli-\(UUID().uuidString)", isDirectory: true)
            let home = Home(root: root)
            try FileManager.default.createDirectory(at: home.support, withIntermediateDirectories: true)
            // Port 9 is the discard service: nothing answers there, so every model check sees Ollama as not running.
            let settings: [String: String] = ["incomingPath": root.appendingPathComponent("Incoming").path,
                                              "archivePath": root.appendingPathComponent("Archive").path,
                                              "ollamaURL": "http://127.0.0.1:9", "ollamaManagement": "external"]
            try JSONEncoder().encode(settings).write(to: home.support.appendingPathComponent("settings.json"))
            return home
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    private func run(_ home: Home, _ arguments: [String]) throws -> Result {
        let command = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("arrumatorcli")
        guard FileManager.default.isExecutableFile(atPath: command.path) else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        process.executableURL = command
        process.arguments = arguments
        // Only what the command needs: its scratch home, and a home folder for the disk-space check.
        process.environment = ["ARRUMATOR_HOME": home.support.path, "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
    }

    private func settings(_ home: Home) throws -> AppSettings {
        try JSON.decoder.decode(AppSettings.self, from: try run(home, ["settings", "--json"]).stdout)
    }

    @Test func doctorReportsAHealthyIndexAndExitsAsItsReportSays() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let result = try run(home, ["doctor", "--json"])
        let report = try JSON.decoder.decode(DoctorReport.self, from: result.stdout)
        #expect(report.checks.first { $0.name == "Database" }?.status == .ok, "a current index is healthy: \(report.checks)")
        #expect(report.checks.first { $0.name == "Ollama running" }?.status == .warning, "Ollama not running is a warning, not a failure")
        // Whether Ollama is installed depends on the machine (GitHub's runners have none); nothing else may fail here.
        let failures = report.checks.filter { $0.status == .error }.map(\.name)
        #expect(failures.allSatisfy { $0 == "Ollama installed" }, "a scratch archive and its index have nothing wrong: \(failures)")
        #expect(result.status == (report.hasErrors ? 1 : 0), "the exit code says whether a check failed: \(result.stderr)")
    }

    @Test func aProfileThePipelineDoesNotDefineIsRefusedAndNothingIsSaved() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let before = try settings(home)
        let result = try run(home, ["settings", "--profile", "bogus", "--rename-files", "false"])
        #expect(result.status == 1 && result.stderr.contains("bogus"), "the command fails and names the profile: \(result.stderr)")
        let after = try settings(home)
        #expect(after.models.profile == before.models.profile && after.renameFiles == before.renameFiles,
                "a refused change saves nothing, so every later command still resolves its models")
    }

    @Test func everySettingTheAppChangesCanBeChangedFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let result = try run(home, ["settings", "--json", "--show-in-dock", "false", "--rename-files", "false", "--transliterate", "true",
                                    "--duplicate-action", "leaveInIncoming", "--notify-on-filed", "true", "--notify-on-review", "false",
                                    "--pause-on-battery", "false", "--log-level", "debug", "--trace-retention-days", "30",
                                    "--group-labels-by-kind", "true", "--task-effort", "high"])
        #expect(result.status == 0, "the command accepts every setting: \(result.stderr)")
        let changed = try JSON.decoder.decode(AppSettings.self, from: result.stdout)
        #expect(!changed.showInDock && !changed.renameFiles && changed.transliterate && changed.duplicateAction == .leaveInIncoming,
                "the filing settings are the ones given")
        #expect(changed.notifyOnFiled && !changed.notifyOnReview && !changed.pauseOnBattery && changed.logLevel == .debug
                    && changed.traceRawRetentionDays == 30 && changed.groupLabelsByKind && changed.taskEffort == .high,
                "and so are the rest")
        #expect(try settings(home) == changed, "and they are saved")
    }

    @Test func pausingFromTheCommandLineIsRecordedAsTheAppRecordsIt() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        #expect(try run(home, ["settings", "--paused", "true"]).status == 0, "pausing from the command line succeeds")
        #expect(try settings(home).paused, "the setting is saved")
        let events = try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json"]).stdout)
        #expect(events.map(\.kind) == [.paused], "and the pause is in History, as when the app pauses: \(events.map(\.kind))")
    }

    @Test func listingCommandsAnswerInJSON() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let review = try run(home, ["review", "list", "--json"])
        #expect(try JSON.decoder.decode([DocumentRecord].self, from: review.stdout).isEmpty, "an empty archive has nothing waiting")
        let archive = try JSONSerialization.jsonObject(with: try run(home, ["archive", "show", "--json"]).stdout) as? [String: String]
        #expect(archive?["archive"] == home.root.appendingPathComponent("Archive").path, "the archive the settings name")
        let stats = try JSONSerialization.jsonObject(with: try run(home, ["stats", "--json"]).stdout) as? [String: Any]
        #expect(stats?["warnings"] is [String: Any], "warnings are an object keyed by their code, as before they were typed")
        let funnel = try JSONSerialization.jsonObject(with: try run(home, ["funnel", "--json"]).stdout) as? [String: Any]
        #expect(funnel?["windowDays"] as? Int == 30, "the period is stats.defaultWindowDays unless --days says otherwise")
    }

    @Test func browsingLabelsTakesTheSidebarsSearchAndAnswersInJSON() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let result = try run(home, ["labels", "browse", "--json", "--matching", "edp", "type=invoice"])
        #expect(result.status == 0, "a search for labels is accepted beside the labels chosen: \(result.stderr)")
        let scope = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        #expect(scope?["labels"] is [Any] && scope?["documents"] is [Any],
                "the scope lists its documents and the labels to narrow them by, as before: \(result.text)")
    }

    @Test func searchTasksAreAskedChangedAndRemovedFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        // No model answers here, so the task only joins the queue.
        let asked = try run(home, ["tasks", "new", "--queue-only", "--json", "electricity", "invoices", "from", "2025"])
        #expect(asked.status == 0, "a prompt in several words is one request: \(asked.stderr)")
        let detail = try JSON.decoder.decode(SearchTaskDetail.self, from: asked.stdout)
        #expect(detail.task.state == .queued && detail.task.prompt == "electricity invoices from 2025" && detail.tree.count == 0,
                "it waits in the queue, having found nothing yet")
        #expect(detail.task.effort == (try AppSettings.bundledDefaults().taskEffort) && detail.task.assignedModel == nil,
                "to be read with the effort Settings gives new tasks, by the profile's model")
        let id = String(detail.task.id)
        let careful = try run(home, ["tasks", "new", "--queue-only", "--json", "--effort", "high", "--model", "qwen3.5:9b", "water", "bills"])
        let carefulTask = try JSON.decoder.decode(SearchTaskDetail.self, from: careful.stdout).task
        #expect(carefulTask.effort == .high && carefulTask.assignedModel == "qwen3.5:9b", "or with the effort and model asked: \(careful.stderr)")
        let shown = try run(home, ["tasks", "show", String(carefulTask.id)])
        #expect(shown.text.contains("read with:   high effort, by qwen3.5:9b (yours)"), "the task says how it is read: \(shown.text)")
        let lowered = try run(home, ["tasks", "update", String(carefulTask.id), "--json", "--queue-only", "--effort", "low", "--model", ""])
        let loweredTask = try JSON.decoder.decode(SearchTaskDetail.self, from: lowered.stdout).task
        #expect(loweredTask.effort == .low && loweredTask.assignedModel == nil, "another effort, and the profile's model back: \(lowered.stderr)")
        #expect(try run(home, ["tasks", "new", "--effort", "extreme", "bills"]).status != 0, "an effort that is no preset is refused")
        #expect(try run(home, ["tasks", "delete", String(carefulTask.id)]).status == 0, "and the task can go")
        let changed = try run(home, ["tasks", "update", id, "--json", "--title", "Bills", "--group-by", "sender,date", "--queue-only"])
        let task = try JSON.decoder.decode(SearchTaskDetail.self, from: changed.stdout).task
        #expect(task.name == "Bills" && task.grouping == [.sender, .date] && task.groupedByUser, "renamed and arranged as asked: \(changed.stderr)")
        #expect(try run(home, ["tasks", "update", id, "--group-by", "colour"]).status != 0, "an arrangement by no kind of label is refused")
        let listed = try JSON.decoder.decode([SearchTask].self, from: try run(home, ["tasks", "list", "--json"]).stdout)
        #expect(listed.map(\.id) == [detail.task.id], "the task is listed")
        let add = try run(home, ["tasks", "add", id, "999"])
        #expect(add.status != 0 && add.stderr.contains("999"), "a document the archive does not have is refused by number: \(add.stderr)")
        let export = try run(home, ["tasks", "export", id, "--to", home.root.appendingPathComponent("Out").path])
        #expect(export.status != 0 && export.stderr.contains("no documents"), "an empty set has nothing to export: \(export.stderr)")
        let removed = try JSON.decoder.decode(SearchTask.self, from: try run(home, ["tasks", "delete", id, "--json"]).stdout)
        #expect(removed.id == detail.task.id, "removing prints the task removed")
        #expect(try JSON.decoder.decode([SearchTask].self, from: try run(home, ["tasks", "--json"]).stdout).isEmpty, "and it is gone")
        let events = try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json"]).stdout)
        #expect(Set(events.map(\.kind)) == [.taskCreated, .taskEdited, .taskRemoved], "each step is in History: \(events.map(\.kind))")
    }

    @Test func logsAreReadAsJSONLinesWithoutOpeningTheArchive() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        _ = try run(home, ["doctor"])
        let lines = try run(home, ["logs", "--json", "--level", "trace"]).text.split(separator: "\n")
        #expect(!lines.isEmpty, "the doctor's run was logged")
        for line in lines {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) is [String: Any], "every line is a JSON object: \(line)")
        }
    }
}
