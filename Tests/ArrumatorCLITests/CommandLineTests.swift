@testable import ArrumatorCore
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
        var archive: URL { root.appendingPathComponent("Archive", isDirectory: true) }

        /// Port 9 is the discard service: nothing answers there, so every model check sees Ollama as not running.
        static let nowhere = "http://127.0.0.1:9"

        /// A home whose settings save `ollamaURL` as the Ollama server.
        static func make(ollamaURL: String = nowhere) throws -> Home {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-cli-\(UUID().uuidString)", isDirectory: true)
            let home = Home(root: root)
            try FileManager.default.createDirectory(at: home.support, withIntermediateDirectories: true)
            let settings: [String: String] = ["incomingPath": root.appendingPathComponent("Incoming").path,
                                              "archivePath": home.archive.path,
                                              "ollamaURL": ollamaURL, "ollamaManagement": "external"]
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
        // Only what the command needs: its scratch home and Trash, and a home folder for the disk-space check.
        process.environment = ["ARRUMATOR_HOME": home.support.path, "ARRUMATOR_TRASH": home.root.appendingPathComponent("Trash").path,
                               "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
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

    @Test func aProfileTheSettingsDoNotListIsRefusedAndNothingIsSaved() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let before = try settings(home)
        let file = try Data(contentsOf: home.support.appendingPathComponent("settings.json"))
        let result = try run(home, ["settings", "--profile", "bogus", "--rename-files", "false"])
        #expect(result.status == 1 && result.stderr.contains("bogus"), "the command fails and names the profile: \(result.stderr)")
        #expect(try Data(contentsOf: home.support.appendingPathComponent("settings.json")) == file,
                "the settings refuse it before they are written, so the file is as it was")
        let after = try settings(home)
        #expect(after.profile == before.profile && after.renameFiles == before.renameFiles && after.modelProfiles == before.modelProfiles,
                "a refused change saves nothing, so every later command still finds its models")
        let switched = try run(home, ["settings", "--json", "--profile", "smart"])
        let smart = try JSON.decoder.decode(AppSettings.self, from: switched.stdout)
        #expect(switched.status == 0 && smart.profile == "smart" && smart.modelProfiles == before.modelProfiles,
                "a profile the settings list is taken, and the settings show every profile beside the one in use: \(switched.stderr)")
    }

    @Test func settingsAnEarlierVersionSavedStopTheCommandNamingTheKey() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let url = home.support.appendingPathComponent("settings.json")
        guard case var .object(saved) = try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: url)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        saved["models"] = ["profile": "lowMemory"]
        saved["duplicateAction"] = "leaveInIncoming"
        try JSON.encoder.encode(JSONValue.object(saved)).write(to: url)
        let result = try run(home, ["settings", "--json"])
        #expect(result.status == 1 && result.stderr.contains(ConfigLoader.unknownKey("models")),
                "the command stops naming the key to remove, rather than reading the profile chosen before as another: \(result.stderr)")
        #expect(result.stderr.contains(ConfigLoader.unknownKey("duplicateAction")),
                "and so does what copies were done with, now that a copy always has its original read again: \(result.stderr)")
    }

    /// The settings changes in the scratch archive's History.
    private func settingsEvents(_ home: Home) throws -> [EventRecord] {
        try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json"]).stdout).filter { $0.kind == .settingsChanged }
    }

    @Test func everySettingTheAppChangesCanBeChangedFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let arguments = ["settings", "--json", "--show-in-dock", "false", "--rename-files", "false", "--transliterate", "true",
                         "--notify-on-filed", "true", "--notify-on-review", "false",
                         "--pause-on-battery", "false", "--log-level", "debug", "--trace-retention-days", "30",
                         "--group-labels-by-kind", "true", "--task-effort", "high"]
        let result = try run(home, arguments)
        #expect(result.status == 0, "the command accepts every setting: \(result.stderr)")
        let changed = try JSON.decoder.decode(AppSettings.self, from: result.stdout)
        #expect(!changed.showInDock && !changed.renameFiles && changed.transliterate,
                "the filing settings are the ones given")
        #expect(changed.notifyOnFiled && !changed.notifyOnReview && !changed.pauseOnBattery && changed.logLevel == .debug
                    && changed.traceRawRetentionDays == 30 && changed.groupLabelsByKind && changed.taskEffort == .high,
                "and so are the rest")
        #expect(try settings(home) == changed, "and they are saved")
        let events = try settingsEvents(home)
        #expect(events.count == 1 && events.first?.actor == .user, "the change is in History once, as the user's: \(events.map(\.summary))")
        let payload = JSON.decode([String: JSONValue].self, from: events.first?.payloadJson)
        #expect(payload.map { Set($0.keys) } == ["showInDock", "renameFiles", "transliterate", "notifyOnFiled", "notifyOnReview",
                                                 "pauseOnBattery", "logLevel", "traceRawRetentionDays", "groupLabelsByKind", "taskEffort"],
                "naming every setting it changed: \(String(describing: payload))")
        #expect(events.first?.summary.contains("renameFiles to false") == true, "and saying what each became: \(events.first?.summary ?? "")")
        #expect(try run(home, arguments).status == 0 && (try settingsEvents(home)).count == 1, "the same settings again change nothing and record nothing")
    }

    @Test func modelProfilesAreListedAddedChangedResetAndRemovedFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let bundled = try AppSettings.bundledDefaults()
        let ids = bundled.modelProfiles.sorted { $0.value.position < $1.value.position }.map(\.key)
        let other = try #require(ids.first { $0 != bundled.profile }, "a bundled profile besides the one in use")
        let (source, inUse) = (try bundled.modelProfile(other), try bundled.modelProfile())
        let reader = "reads-well:9b"
        func listings() throws -> [ModelProfileListing] {
            try JSON.decoder.decode([ModelProfileListing].self, from: try run(home, ["profiles", "--json"]).stdout)
        }
        func saved() throws -> JSONValue? {
            try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: home.support.appendingPathComponent("settings.json")))["modelProfiles"]
        }
        let listed = try listings()
        #expect(listed.map(\.id) == ids && listed.allSatisfy(\.predefined) && listed.filter(\.inUse).map(\.id) == [bundled.profile],
                "the bundled profiles are listed in order, predefined, the one Settings uses in use: \(listed.map(\.id))")
        let table = try run(home, ["profiles"]).text
        #expect(table.contains(inUse.name) && table.contains(inUse.chatModel) && table.contains("in use") && table.contains("predefined"),
                "the text lists each profile with its models, marking the one in use and the predefined ones: \(table)")

        let added = try run(home, ["profiles", "add", "Mine", "--from", other, "--chat-model", reader, "--json"])
        let mine = try JSON.decoder.decode(ModelProfileListing.self, from: added.stdout)
        #expect(added.status == 0 && mine.id == "mine" && !mine.predefined, "a profile of the user's own is added under an id of its own: \(added.stderr)")
        #expect(mine.profile.chatModel == reader && mine.profile.visionModel == source.visionModel && mine.profile.embedModel == source.embedModel,
                "a copy of the profile named, with the model given")
        let changed = try JSON.decoder.decode(ModelProfileListing.self,
                                              from: try run(home, ["profiles", "update", other, "--chat-model", reader, "--json"]).stdout)
        #expect(changed.changed && changed.profile.chatModel == reader, "a predefined profile is changed, and says so")
        #expect(try saved()?[other] == ["chatModel": .string(reader)], "settings.json holds the one field changed")
        let nothing = try run(home, ["profiles", "update", other])
        #expect(nothing.status != 0 && nothing.stderr.contains("--chat-model"), "a change that gives nothing is refused, naming what to give: \(nothing.stderr)")
        let reset = try JSON.decoder.decode(ModelProfileListing.self, from: try run(home, ["profiles", "reset", other, "--json"]).stdout)
        #expect(try saved()?[other] == nil && !reset.changed && reset.profile == source, "reset, it is the bundled profile again, and the file forgets it")
        let removePredefined = try run(home, ["profiles", "remove", other])
        #expect(removePredefined.status == 1 && removePredefined.stderr.contains(other), "a predefined profile is never removed: \(removePredefined.stderr)")
        let resetOwn = try run(home, ["profiles", "reset", mine.id])
        #expect(resetOwn.status == 1 && resetOwn.stderr.contains(mine.id), "the user's own has nothing to reset to: \(resetOwn.stderr)")

        #expect(try run(home, ["settings", "--profile", mine.id]).status == 0, "Settings reads with the new profile")
        #expect(try listings().filter(\.inUse).map(\.id) == [mine.id], "and the list marks it in use")
        let removeInUse = try run(home, ["profiles", "remove", mine.id])
        #expect(removeInUse.status == 1 && removeInUse.stderr.contains(mine.id), "the profile in use stays: \(removeInUse.stderr)")
        #expect(try run(home, ["settings", "--profile", bundled.profile]).status == 0, "Settings reads with its profile again")
        let task = try JSON.decoder.decode(SearchTaskDetail.self, from: try run(home, ["tasks", "new", "--queue-only", "--json", "--profile", mine.id,
                                                                                       "water", "bills"]).stdout).task
        let removeNamed = try run(home, ["profiles", "remove", mine.id])
        #expect(removeNamed.status == 1 && removeNamed.stderr.contains("1 search task in this archive") && removeNamed.stderr.contains(mine.id),
                "so does one a search task of the archive reads with, saying how many and of which archive: \(removeNamed.stderr)")
        #expect(try run(home, ["tasks", "update", String(task.id), "--queue-only", "--profile", ""]).status == 0, "the task follows Settings again")
        let removed = try run(home, ["profiles", "remove", mine.id, "--json"])
        #expect(removed.status == 0, "then it is removed: \(removed.stderr)")
        #expect(try JSON.decoder.decode(ModelProfileListing.self, from: removed.stdout).id == mine.id, "and the profile removed is printed")
        #expect(try listings().map(\.id) == ids && (try saved()) == nil, "and it is gone from the list and from settings.json")

        let summaries = try settingsEvents(home).map(\.summary)
        #expect(summaries.sorted() == ["Added the profile “Mine”, reading with \(reader)",
                                       "The profile “\(source.name)” reads with \(reader) instead of \(source.chatModel)",
                                       "Reset the profile “\(source.name)”", "Reading with the profile “Mine”",
                                       "Reading with the profile “\(inUse.name)”", "Removed the profile “Mine”"].sorted(),
                "History has one event per change, and none for the refused ones: \(summaries)")
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
        #expect(archive?["archive"] == home.archive.path, "the archive the settings name")
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

    /// Puts documents into the scratch archive as an earlier run filed them, one a minute after the other, each labelled
    /// as given: the files, each with the identifier Arrumator keeps on it, and the archive's record of them, which the
    /// command's new index is rebuilt from. Returns their numbers, in the order given.
    private func file(_ home: Home, _ documents: [(name: String, labels: [DocumentLabel])]) throws -> [Int64] {
        try FileManager.default.createDirectory(at: home.archive, withIntermediateDirectories: true)
        var entries: [DocumentEntry] = []
        for (offset, document) in documents.enumerated() {
            let url = home.archive.appendingPathComponent(document.name)
            let text = Data("A document: \(document.name)".utf8)
            try text.write(to: url)
            var record = DocumentRecord.arrived(path: url.path, sha256: try HashService.sha256(of: url), size: Int64(text.count),
                                                uttype: "public.plain-text", inode: nil, modified: nil, now: Date())
            record.id = Int64(offset + 1)
            record.status = .filed
            record.filedAt = record.addedAt.addingTimeInterval(Double(offset) * 60)
            record.labelsJson = JSON.string(document.labels)
            try Xattr.set(Xattr.documentID, record.uid, on: url)
            entries.append(try #require(DocumentEntry(record)))
        }
        let records = home.archive.appendingPathComponent(try PipelineConfig.bundledDefaults().records.documentsFileName)
        try FrontMatter.compose(RecordList(entries), body: "").write(to: records, atomically: true, encoding: .utf8)
        return entries.map(\.id)
    }

    @Test func browsingLabelsListsTheDocumentsByTheirOwnDateNewestFirstAsTheAppDoes() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let invoice = DocumentLabel(kind: .type, value: "invoice")
        let day = { DocumentLabel(kind: .date, value: $0) }
        // Filed in this order, the reverse of their dates: the newest bill first, the undated one last.
        let ids = try file(home, [("c.txt", [invoice, day("2024-01-05")]), ("b.txt", [invoice, day("2023-03-10")]), ("a.txt", [invoice, day("2023-03-10")]),
                                  ("d.txt", [invoice]), ("contract.txt", [DocumentLabel(kind: .type, value: "contract"), day("2025-06-01")])])
        let (c, b, a, d) = (ids[0], ids[1], ids[2], ids[3])
        let result = try run(home, ["labels", "browse", "--json", "type=invoice"])
        let scope = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        let listed = (scope?["documents"] as? [[String: Any]])?.compactMap { ($0["id"] as? NSNumber)?.int64Value }
        #expect(listed == [c, a, b, d],
                "the invoices by their own date, the newest first, one date by name and the undated last, as the page lists them: \(result.text) \(result.stderr)")
        let text = try run(home, ["labels", "browse", "type=invoice"]).text
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("#") }.compactMap { $0.dropFirst().split(separator: " ").first.flatMap { Int64($0) } }
        #expect(lines == [c, a, b, d], "and so does the text: \(text)")
    }

    /// The numbers of the documents a listing's JSON names, in its order.
    private func documentIDs(_ json: Data, under key: String? = nil) throws -> [Int64] {
        let object = try JSONSerialization.jsonObject(with: json)
        let listing: Any? = if let key { (object as? [String: Any])?[key] } else { object }
        let rows = listing as? [[String: Any]] ?? []
        return rows.compactMap { ($0["id"] as? NSNumber)?.int64Value }
    }

    @Test func aFileInAFolderInIncomingIsTaggedByItsNameAndFoundByItFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let folder = home.root.appendingPathComponent("Incoming/Taxes 2024", isDirectory: true)
        let scan = folder.appendingPathComponent("scan.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Tax assessment for 2024".utf8).write(to: scan)
        let blank = try run(home, ["ingest", "--dry-run", "--tag", "  ", scan.path])
        #expect(blank.status != 0 && blank.stderr.contains("--tag"), "a tag of nothing is refused before anything is read: \(blank.stderr)")

        // No model answers here: the file is taken in with its tags and waits to be read.
        let ingested = try run(home, ["ingest", "--json", "--tag", "Mine", scan.path])
        let document = try #require(try JSON.decoder.decode([DocumentRecord].self, from: ingested.stdout).first, "\(ingested.text) \(ingested.stderr)")
        let (taxes, mine) = (DocumentLabel(kind: .tag, value: "Taxes 2024"), DocumentLabel(kind: .tag, value: "Mine"))
        #expect(document.labels == [taxes, mine] && !document.isLabelled,
                "the folder's name and the tag given are the document's own as it waits for the model, which has not labelled it: \(ingested.text)")
        #expect(FileManager.default.fileExists(atPath: folder.path), "and the folder stays where it is")
        let id = try #require(document.id)
        let row = try JSONSerialization.jsonObject(with: try run(home, ["labels", String(id), "--json"]).stdout) as? [String: Any]
        #expect(row?["labelled"] as? Bool == false, "its labels say it is not labelled yet: \(String(describing: row))")
        let shown = try run(home, ["labels", String(id)]).text
        #expect(shown.contains("tag") && shown.contains("Taxes 2024 · Mine") && shown.contains("Not labelled yet"), "and so does the text: \(shown)")
        let found = try run(home, ["search", "--json", "--no-semantic", "tag:\"taxes 2024\""])
        #expect(try documentIDs(found.stdout) == [id], "tag:… finds it, however the tag is cased: \(found.text) \(found.stderr)")
        let browsed = try run(home, ["labels", "browse", "--json", "tag=Taxes 2024"])
        #expect(try documentIDs(browsed.stdout, under: "documents") == [id], "and so does choosing the tag, as in the sidebar: \(browsed.text)")
    }

    @Test func tagsAreGivenByHandBrowsedCountedAndArrangedByFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let (taxes, mine) = (DocumentLabel(kind: .tag, value: "Taxes 2024"), DocumentLabel(kind: .tag, value: "Mine"))
        let (invoice, receipt) = (DocumentLabel(kind: .type, value: "invoice"), DocumentLabel(kind: .type, value: "receipt"))
        let ids = try file(home, [("a.txt", [invoice, taxes]), ("b.txt", [invoice]), ("c.txt", [receipt, taxes])])
        let added = try run(home, ["labels", String(ids[1]), "--json", "--add", "tag=Taxes 2024", "--add", "tag= Mine "])
        let row = try JSONSerialization.jsonObject(with: added.stdout) as? [String: Any]
        let labels = try JSON.decoder.decode([DocumentLabel].self, from: JSONSerialization.data(withJSONObject: row?["labels"] ?? []))
        #expect(labels == [invoice, taxes, mine] && row?["labelled"] as? Bool == true,
                "a tag is added by hand as any label, as written, and the document labelled stays so: \(added.text) \(added.stderr)")
        let browsed = try run(home, ["labels", "browse", "--json", "tag=taxes 2024"])
        #expect(try documentIDs(browsed.stdout, under: "documents") == ids, "every document with the tag, however it is cased: \(browsed.text)")
        let stats = try JSONSerialization.jsonObject(with: try run(home, ["stats", "--json"]).stdout) as? [String: Any]
        #expect((stats?["labelsByKind"] as? [String: Any])?["tag"] as? Int == 4, "Statistics counts the tags among the labels by kind")

        let asked = try JSON.decoder.decode(SearchTaskDetail.self, from: try run(home, ["tasks", "new", "--queue-only", "--json", "tax", "papers"]).stdout)
        let task = String(asked.task.id)
        #expect(try run(home, ["tasks", "add", task, "--label", "tag=Taxes 2024"]).status == 0, "the documents with a tag join a task's set")
        let arranged = try run(home, ["tasks", "update", task, "--json", "--queue-only", "--group-by", "tag,type"])
        let detail = try JSON.decoder.decode(SearchTaskDetail.self, from: arranged.stdout)
        #expect(detail.task.grouping == [.tag, .type] && detail.tree.groups.map(\.value) == ["Taxes 2024"]
                    && detail.tree.groups.first?.groups.map(\.value) == ["invoice", "receipt"],
                "and the set is arranged by tag, a folder per tag when it is exported: \(arranged.text) \(arranged.stderr)")
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
        #expect(detail.task.effort == (try AppSettings.bundledDefaults().taskEffort) && detail.task.profile == nil,
                "to be read with the effort Settings gives new tasks, by the profile Settings uses")
        let id = String(detail.task.id)
        let careful = try run(home, ["tasks", "new", "--queue-only", "--json", "--effort", "high", "--profile", "smart", "water", "bills"])
        let carefulTask = try JSON.decoder.decode(SearchTaskDetail.self, from: careful.stdout).task
        #expect(carefulTask.effort == .high && carefulTask.profile == "smart", "or with the effort and profile asked: \(careful.stderr)")
        let shown = try run(home, ["tasks", "show", String(carefulTask.id)])
        #expect(shown.text.contains("read with:   high effort, by Smart"), "the task says how it is read, its profile by name: \(shown.text)")
        let shownJSON = try JSON.decoder.decode(SearchTaskDetail.self, from: try run(home, ["tasks", "show", String(carefulTask.id), "--json"]).stdout)
        #expect(shownJSON.task.profile == "smart", "and its JSON names the profile by its id")
        let plain = try run(home, ["tasks", "show", id]).text
        #expect(plain.contains("read with:   medium effort, by Settings' profile (Standard)"),
                "a task that follows Settings says so, and which profile that is now: \(plain)")
        let list = try run(home, ["tasks", "list"]).text
        #expect(list.contains("Smart") && list.contains("Settings' profile (Standard)"), "the list shows each task's profile: \(list)")
        let unknown = try run(home, ["tasks", "new", "--queue-only", "--profile", "nonexistent", "bills"])
        #expect(unknown.status == 1 && unknown.stderr.contains("nonexistent"), "a profile the settings do not list is refused by name: \(unknown.stderr)")
        let refused = try run(home, ["tasks", "update", String(carefulTask.id), "--queue-only", "--effort", "low", "--profile", "nonexistent"])
        #expect(refused.status == 1 && refused.stderr.contains("nonexistent"), "when a task is changed too: \(refused.stderr)")
        let kept = try JSON.decoder.decode(SearchTaskDetail.self, from: try run(home, ["tasks", "show", String(carefulTask.id), "--json"]).stdout).task
        #expect(kept.effort == .high && kept.profile == "smart", "and nothing of the refused change is saved")
        let model = try run(home, ["tasks", "new", "--queue-only", "--model", "qwen3.5:9b", "bills"])
        #expect(model.status != 0 && model.stderr.contains("--model"), "a task is given a profile, no longer a model: \(model.stderr)")
        let lowered = try run(home, ["tasks", "update", String(carefulTask.id), "--json", "--queue-only", "--effort", "low", "--profile", ""])
        let loweredTask = try JSON.decoder.decode(SearchTaskDetail.self, from: lowered.stdout).task
        #expect(loweredTask.effort == .low && loweredTask.profile == nil, "another effort, and Settings' profile again: \(lowered.stderr)")
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

    /// A question and its answer as `tasks ask --json` gives them, with the documents it names.
    private struct Answered: Decodable {
        struct Named: Decodable { var id: Int64; var name: String }
        var turn: TaskTurn
        var documents: [Named]
    }

    private struct Conversation: Decodable {
        var items: [ConversationItem]
    }

    @Test func aTasksDocumentsAreAskedAboutStoppedAskedAgainAndClearedFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let task = try JSON.decoder.decode(SearchTaskDetail.self, from: try run(home, ["tasks", "new", "--queue-only", "--json", "bills"]).stdout).task
        let id = String(task.id)
        // No model answers here, so the question only joins the queue.
        let asked = try run(home, ["tasks", "ask", id, "--queue-only", "--json", "what", "do", "they", "come", "to?"])
        #expect(asked.status == 0, "a question in several words is one question: \(asked.stderr)")
        let turn = try JSON.decoder.decode(Answered.self, from: asked.stdout).turn
        #expect(turn.question == "what do they come to?" && turn.state == .queued && turn.task == task.id && turn.answer == nil,
                "it waits to be answered")
        let listed = try JSON.decoder.decode(Conversation.self, from: try run(home, ["tasks", "conversation", id, "--json"]).stdout)
        #expect(listed.items.compactMap(\.turn).map(\.id) == [turn.id], "the task's conversation holds it")
        let shown = try run(home, ["tasks", "conversation", id]).text
        #expect(shown.contains("Question #\(turn.id) · queued") && shown.contains("> what do they come to?"), "and shows it: \(shown)")
        let stopped = try JSON.decoder.decode(Answered.self, from: try run(home, ["tasks", "stop", String(turn.id), "--json"]).stdout).turn
        #expect(stopped.state == .failed && stopped.problem == TaskConversationQueue.stoppedProblem, "a question waiting can be stopped")
        let again = try JSON.decoder.decode(Answered.self, from: try run(home, ["tasks", "ask-again", String(turn.id), "--queue-only", "--json"]).stdout)
        #expect(again.turn.state == .queued && again.turn.problem == nil, "and asked again")
        let refused = try run(home, ["tasks", "ask-again", String(turn.id), "--queue-only"])
        #expect(refused.status != 0 && refused.stderr.contains("still waiting"), "but not while it waits: \(refused.stderr)")
        #expect(try run(home, ["tasks", "ask", id, "--queue-only", " "]).status != 0, "a question without words is refused")
        #expect(try run(home, ["tasks", "ask", "999", "--queue-only", "why?"]).stderr.contains("999"), "and one about no task, by its number")
        let cleared = try run(home, ["tasks", "clear", id, "--json"])
        #expect(cleared.text.contains(#""removed" : 1"#), "clearing removes the question: \(cleared.text)")
        #expect(try JSON.decoder.decode(Conversation.self, from: try run(home, ["tasks", "conversation", id, "--json"]).stdout).items.isEmpty,
                "and the conversation is empty")
        let answered = try run(home, ["tasks", "answer", "--json"])
        #expect(answered.status == 0 && answered.text.contains(#""waiting" : 0"#), "with nothing to answer, nothing waits: \(answered.text)")
        let events = try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json"]).stdout)
        #expect(events.contains { $0.kind == .taskEdited && $0.summary.hasPrefix("Cleared the conversation about") },
                "clearing is recorded in History: \(events.map(\.summary))")
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

/// What may be pasted into a public bug report.
extension CommandLineTests {
    /// What a bug report asks for, a trace without --full and diagnostics without consent, holds nothing of a document
    /// read by the real extractor: neither its text nor its name nor the identifier read from it (AGENTS.md §4.1).
    @Test func aTraceAndDiagnosticsHoldNothingOfTheDocumentUnlessAskedFor() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let file = home.root.appendingPathComponent("Incoming/Fatura-Exemplo.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Cliente Maria Exemplo, NIF 503504564, fatura de julho".utf8).write(to: file)
        let sentinels = ["Maria Exemplo", "503504564", "Fatura-Exemplo"]
        // No model answers here: the file is extracted and waits to be read, and its trace says so.
        let ingested = try run(home, ["ingest", "--json", file.path])
        let id = try #require(try JSON.decoder.decode([DocumentRecord].self, from: ingested.stdout).first?.id, "\(ingested.text) \(ingested.stderr)")

        let full = try run(home, ["trace", String(id), "--full"])
        #expect(full.status == 0 && full.text.contains("Maria Exemplo"), "with --full, the trace shows what was read: \(full.text) \(full.stderr)")
        let plain = try run(home, ["trace", String(id)])
        #expect(plain.status == 0 && plain.text.contains("extract") && plain.text.contains("--full"),
                "without it, the steps and how to see the rest: \(plain.text) \(plain.stderr)")
        #expect(sentinels.filter { plain.text.contains($0) }.isEmpty, "and nothing of the document: \(plain.text)")
        let json = try run(home, ["trace", String(id), "--json"])
        let exported = try JSON.decoder.decode(TraceExport.self, from: json.stdout)
        #expect(!exported.steps.isEmpty && exported.steps.allSatisfy { $0.inputJson == nil && $0.outputJson == nil && $0.error == nil },
                "its JSON keeps each step's stage, status and timing alone: \(json.text)")

        for consent in [false, true] {
            let zip = home.root.appendingPathComponent("diagnostics-\(consent).zip")
            let exportedZip = try run(home, ["diagnostics", zip.path] + (consent ? ["--include-document-text"] : []))
            #expect(exportedZip.status == 0, "\(exportedZip.stderr)")
            let files = try unzipped(zip, into: home.root.appendingPathComponent("unzipped-\(consent)", isDirectory: true))
            #expect(files.contains { $0.key.contains("/logs/") }, "the export holds the log of what was done: \(files.keys.sorted())")
            for sentinel in sentinels {
                let holding = files.filter { String(decoding: $0.value, as: UTF8.self).contains(sentinel) }.keys.sorted()
                #expect(holding.isEmpty != consent,
                        consent ? "with consent, \(sentinel) is shared" : "without consent, \(sentinel) is in no file of the export: \(holding)")
            }
        }
    }

    /// Every file `zip` holds, by its path in the zip, unzipped into `folder` with macOS's archiver.
    private func unzipped(_ zip: URL, into folder: URL) throws -> [String: Data] {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: DiagnosticsExporter.dittoPath)
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        try #require(ditto.terminationStatus == 0, "the export is a zip")
        let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects ?? []
        var files: [String: Data] = [:]
        for case let url as URL in found where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files[String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))] = try Data(contentsOf: url)
        }
        return files
    }
}

/// The Ollama server, as the command line gives it.
extension CommandLineTests {
    /// An address an earlier version saved that this one refuses stops every command, saying where it is saved and how
    /// to give another; giving another is the one command that never opens the archive with the old one first.
    @Test func anOllamaAddressThatCannotBeUsedIsNamedAndMendedFromTheCommandLine() throws {
        let home = try Home.make(ollamaURL: "http://ollama:s3cret@127.0.0.1:9")
        defer { home.cleanup() }
        let stopped = try run(home, ["labels", "browse", "--json"])
        #expect(stopped.status != 0 && stopped.stderr.contains("ollamaURL") && stopped.stderr.contains("settings --ollama-url")
                    && !stopped.stderr.contains("s3cret"),
                "a command stops naming the setting and how to give another, never the password: \(stopped.stderr)")
        let elsewhere = try run(home, ["settings", "--ollama-url", "http://ollama.example.com:11434"])
        #expect(elsewhere.status != 0 && elsewhere.stderr.contains("ollama.example.com"), "an address it refuses mends nothing: \(elsewhere.stderr)")
        let unreadable = try run(home, ["settings", "--ollama-url", "http://ollama:s3cret@gpu box:11434"])
        #expect(unreadable.status != 0 && unreadable.stderr.contains("does not read as an address") && !unreadable.stderr.contains("s3cret"),
                "nor does one that does not read as an address, which is never repeated: \(unreadable.stderr)")
        let mended = try run(home, ["settings", "--json", "--ollama-url", Home.nowhere])
        #expect(mended.status == 0, "a good address is taken in its place: \(mended.stderr)")
        #expect(try settings(home).ollamaURL == Home.nowhere, "and saved, so every command runs again")
        let events = try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json"]).stdout)
        #expect(events.map(\.summary) == ["Ollama at \(Home.nowhere)"], "and the change is in History once: \(events.map(\.summary))")
    }
}
