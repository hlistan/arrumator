import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation
import Synchronization

@main
struct Arrumator: AsyncParsableCommand {
    static let version = AppVersion.of(.main)

    static let configuration = CommandConfiguration(
        commandName: "arrumatorcli",
        abstract: "Local-only document organiser: watches Incoming, labels files with local models, files them.",
        version: version,
        subcommands: [Doctor.self, Run.self, Ingest.self, Extract.self, Search.self, Labels.self, Tasks.self, History.self, Trace.self, Replay.self,
                      Review.self, Archive.self, Funnel.self, Stats.self, Rebuild.self, Logs.self,
                      Models.self, Profiles.self, Diagnostics.self, Eval.self, Settings.self])

    /// Runs the command given, then stops every runtime it opened, as the app stops its own before it quits, and writes
    /// the record files its changes marked, also when it failed part way: a command ends with its process, and nothing
    /// else would write them until the app or another command did (docs/storage.md). Ctrl-C, or SIGTERM, stops the
    /// command the same way (`Interruption`), and it exits with 128 and the signal's number, as a shell reports one. The
    /// throw-away folders it made, as `eval` makes its home, are removed last, whatever it came to.
    static func main() async {
        let opened = OpenedArchives()
        let command = Task {
            try await OpenedArchives.$current.withValue(opened) {
                var command = try await asyncParseAsRoot()
                if var asyncCommand = command as? any AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            }
        }
        let interruption = Interruption(stopping: command, endingAtOnce: { opened.endSpawnedServers() })
        let outcome = await command.result
        await opened.stop()
        let interrupted = interruption.end()
        if case let .failure(error) = outcome {
            await opened.flushAfterFailure()
            opened.discard()
            exit(withError: interrupted.map(Interruption.exitCode) ?? error)
        }
        do {
            try await opened.flush()
        } catch {
            opened.discard()
            exit(withError: error)
        }
        opened.discard()
        if let interrupted { exit(withError: Interruption.exitCode(interrupted)) }
    }
}

/// Ctrl-C (SIGINT) and SIGTERM, while a command runs: the first cancels the command, whose work then stops as the app's
/// does before it quits, the document in hand carrying on at the next start; a second, or two that arrive together,
/// ends the process at once, and the Ollama server it spawned with it. Once the stop is done (`end()`), a signal ends
/// the process at once, as by default, while it writes the record files and removes what it threw away.
final class Interruption: Sendable {
    /// The signals that stop a command.
    static let signals = [SIGINT, SIGTERM]
    /// What a shell adds to a signal's number for the status of a process it ended.
    static let signalStatusBase: Int32 = 128

    private let sources = Mutex<[any DispatchSourceSignal]>([])
    private let received = Mutex<Int32?>(nil)

    /// - Parameter endingAtOnce: what must end with the process when a signal ends it at once, called on the signal's
    ///   queue just before it exits.
    init(stopping command: Task<Void, any Error>, endingAtOnce: @escaping @Sendable () -> Void) {
        let made = Self.signals.map { number in
            // Caught by a handler that does nothing, so it reaches the source rather than ending the process. Not
            // ignored: a process the command starts, such as `ollama serve`, would inherit that, and outlive a stop.
            signal(number) { _ in }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            // The source hears of a signal when it is sent, which may be before the process takes it: the handler stays
            // as it is, as a signal taken after it went back to the default would end the process all the same.
            source.setEventHandler { [weak self, unowned source] in
                guard let self else { return }
                // How many times the signal came since the handler last ran: two quick Ctrl-Cs may come as one event.
                let times = source.data
                let first = received.withLock { received in
                    defer { received = received ?? number }
                    return received == nil
                }
                guard first, times < 2 else {
                    // The next one ends the process, should the stop not end.
                    endingAtOnce()
                    exit(Self.signalStatusBase + number)
                }
                FileHandle.standardError.write(Data("Stopping… (press Ctrl-C again to quit at once)\n".utf8))
                command.cancel()
            }
            source.resume()
            return source
        }
        sources.withLock { $0 = made }
    }

    /// Stops listening, and gives each signal its default again; the signal that cancelled the command, if one did.
    func end() -> Int32? {
        sources.withLock { all in
            for source in all { source.cancel() }
            all = []
        }
        for number in Self.signals { signal(number, SIG_DFL) }
        return received.withLock { $0 }
    }

    /// The status a command a signal stopped exits with.
    static func exitCode(_ signal: Int32) -> ExitCode { ExitCode(signalStatusBase + signal) }
}

/// The archives a command opened (`GlobalOptions.runtime`), whose record files `Arrumator.main` writes before the command
/// exits.
final class OpenedArchives: Sendable {
    /// Those of the command running in this task.
    @TaskLocal static var current: OpenedArchives?

    private let runtimes = Mutex<[ArrumatorRuntime]>([])
    /// Folders the command made to throw away, such as `eval`'s home (`discardAfterwards(_:)`).
    private let throwAway = Mutex<[URL]>([])

    func add(_ runtime: ArrumatorRuntime) {
        runtimes.withLock { $0.append(runtime) }
    }

    /// Removes `folder`, which the command made for itself alone, once it has ended, however it ends: after its
    /// runtimes have stopped and written into it.
    func discardAfterwards(_ folder: URL) {
        throwAway.withLock { $0.append(folder) }
    }

    /// Removes the throw-away folders; one that cannot be removed is said on standard error, and left.
    func discard() {
        for folder in throwAway.withLock({ $0 }) where FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.removeItem(at: folder) } catch {
                FileHandle.standardError.write(Data("Could not remove \(folder.path): \(error.localizedDescription)\n".utf8))
            }
        }
    }

    /// Stops every runtime the command opened (`ArrumatorRuntime.stop()`): what it started, Ollama among it, ends with
    /// the command.
    func stop() async {
        for runtime in runtimes.withLock({ $0 }) { await runtime.stop() }
    }

    /// Ends at once every Ollama server the command's runtimes spawned, as a second Ctrl-C ends the command before its
    /// stop could: from the signal's queue, without waiting for anything.
    func endSpawnedServers() {
        for runtime in runtimes.withLock({ $0 }) { runtime.lifecycle.endSpawnedServerNow() }
    }

    /// Writes every record file the command's changes marked; those of an archive whose folder is away wait in its index
    /// until it is back, as the command said.
    func flush() async throws {
        for runtime in runtimes.withLock({ $0 }) where runtime.records.archiveIsThere { try await runtime.records.flush() }
    }

    /// Writes them after the command failed, whose error is the one it exits with: one that cannot be written is said
    /// before it.
    func flushAfterFailure() async {
        do {
            try await flush()
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        }
    }
}

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    @Flag(name: .long, help: "Echo log lines to stderr.")
    var verbose = false

    /// The runtime open on the archive the settings name, its index brought in line with the archive. What the command
    /// changes is written into the archive's record files before it exits (`Arrumator.main`). `ollamaURL`, an address
    /// already validated, is the Ollama server it talks to in place of the saved one, as `settings --ollama-url` needs to
    /// mend a saved address the runtime would refuse.
    func runtime(ollamaURL: URL? = nil) async throws -> ArrumatorRuntime {
        let runtime = try await bootstrapped(ollamaURL: ollamaURL)
        try await runtime.openArchive()
        return runtime
    }

    /// `runtime(ollamaURL:)` for a command the app also runs on an archive it cannot read: changing a setting, switching
    /// to another archive, on one whose index its rebuild refused for a record file that cannot be read, or whose folder
    /// is away. Why is said on standard error, and the command goes on: its change is made, and recorded in the archive's
    /// History, held until the index is rebuilt or kept in it until the folder is back (docs/storage.md).
    func runtimeEvenIfUnread(ollamaURL: URL? = nil) async throws -> ArrumatorRuntime {
        try await openEvenIfUnread(try await bootstrapped(ollamaURL: ollamaURL))
    }

    /// A runtime whose settings may be ones the app could not run with, which `settings` mends before its archive is
    /// opened (`openEvenIfUnread`): nothing is read in the archive by settings that would take Incoming for part of it.
    func runtimeMendingSettings(ollamaURL: URL?) async throws -> ArrumatorRuntime {
        try await bootstrapped(ollamaURL: ollamaURL, mendingSettings: true)
    }

    /// Opens `runtime`'s archive as `runtimeEvenIfUnread` does.
    func openEvenIfUnread(_ runtime: ArrumatorRuntime) async throws -> ArrumatorRuntime {
        do {
            try await runtime.openArchive()
        } catch let unread as RecordsError {
            switch unread {
            case .unreadableFiles, .archiveNotThere: FileHandle.standardError.write(Data((unread.localizedDescription + "\n").utf8))
            default: throw unread
            }
        }
        return runtime
    }

    private func bootstrapped(ollamaURL: URL?, mendingSettings: Bool = false) async throws -> ArrumatorRuntime {
        var environment = RuntimeEnvironment.current
        if let ollamaURL { environment.ollamaURL = ollamaURL.absoluteString }
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: Arrumator.version, environment: environment,
                                                           echoLogsToStderr: verbose, mendingSettings: mendingSettings,
                                                           resolver: SystemHostResolver(), trash: environment.trash(orElse: SystemTrash()))
        OpenedArchives.current?.add(runtime)
        return runtime
    }

    func emit(_ value: some Encodable, text: () throws -> String) throws {
        print(json ? try JSON.string(value, pretty: true) : try text())
    }
}

/// Terminal-only rendering. Shared number and date formatting lives in `Format` in ArrumatorCore.
enum Terminal {
    static func highlight(_ s: String) -> String {
        SearchHighlight.runs(s).map { $0.1 ? "\u{1B}[1m\($0.0)\u{1B}[0m" : $0.0 }.joined()
    }

    /// A document's labels on one line, "Maria Exemplo · Portugal · pt (Portuguese)", or why there are none. One not
    /// `labelled` yet shows its tags after saying so: "not labelled yet · Taxes 2024".
    static func labels(_ labels: [DocumentLabel]?, labelled: Bool = true) -> String {
        guard let labels else { return "not labelled" }
        guard labelled else { return (["not labelled yet"] + labels.map(label)).joined(separator: " · ") }
        return labels.isEmpty ? "nothing worth a label" : labels.map(label).joined(separator: " · ")
    }

    /// Every kind a document has labels of, one per line: "  sender        EDP Comercial".
    static func labelTable(_ labels: [DocumentLabel]?, indent: Int) -> String {
        guard let labels, !labels.isEmpty else { return String(repeating: " ", count: indent) + Self.labels(labels) }
        return LabelKind.allCases.compactMap { kind in
            let values = labels.filter { $0.kind == kind }.map(label)
            guard !values.isEmpty else { return nil }
            return String(repeating: " ", count: indent) + kind.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
                + values.joined(separator: " · ")
        }.joined(separator: "\n")
    }

    static func label(_ label: DocumentLabel) -> String {
        guard label.kind == .language, let name = DocumentLabel.languageName(label.value) else { return label.value }
        return "\(label.value) (\(name))"
    }

    /// Labels the model gave that became others: “sender EDP Comercial → EDP (rule #3)”.
    static func changes(_ changes: [LabelChange]) -> String {
        changes.map { change in
            let reason = switch change.reason {
            case let .rule(id: id): "rule #\(id)"
            case let .alike(similarity: similarity): String(format: "alike %.2f", similarity)
            }
            return "\(change.from.kind.rawValue) \(change.from.value) → \(change.to?.value ?? "dropped") (\(reason))"
        }.joined(separator: " · ")
    }

    /// What a decision about a label did.
    static func outcome(_ outcome: LabelActionOutcome) -> String {
        "Rule #\(outcome.rule.id ?? 0): \(outcome.rule.summary)"
            + (outcome.documents.isEmpty ? "" : "; changed \(Format.count(outcome.documents.count, "document"))")
    }

    static func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        let widths = (0..<first.count).map { i in rows.map { $0.indices.contains(i) ? $0[i].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { i, cell in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check the environment: folders, database and record files, Ollama, models, disk, network.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let runtime = try await options.runtime()
        let report = await runtime.runDoctor()
        try options.emit(report) {
            var lines = ["Arrumator \(report.appVersion) on \(report.macOS)", "Ollama: \(report.ollama)", ""]
            lines += report.checks.map { c in
                let mark = switch c.status {
                case .ok: "✓"
                case .warning: "!"
                case .error: "✗"
                }
                return "\(mark) \(c.name): \(c.detail)"
            }
            lines.append("")
            lines += report.paths.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            return lines.joined(separator: "\n")
        }
        if report.hasErrors { throw ExitCode(1) }
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run headless: watch Incoming and file documents until interrupted.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let runtime = try await options.runtime()
        guard await runtime.start() else { throw await runtime.database.notRebuilt() }
        let incoming = await runtime.settings.current.incomingURL
        Self.say("Watching \(incoming.path) → \(runtime.archive.path). Press Ctrl-C to stop.")
        for await status in await runtime.coordinator.statusUpdates() {
            if let current = status.current {
                let tags = current.tags.isEmpty ? "" : " · " + current.tags.map(\.value).joined(separator: " · ")
                Self.say("[\(current.stage.rawValue)] \((current.path as NSString).lastPathComponent)\(tags) — queue \(status.queued)")
            } else if status.waitingForOllama {
                Self.say("Waiting for Ollama" + (status.retryAt.map { ": it cannot be reached, and is tried again at \(Format.date($0))" } ?? "…"))
            }
        }
    }

    /// Writes `line` to standard output at once, as it happens, also into a file or a pipe, where printing would hold it
    /// until the command ends.
    static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change settings, as Settings in the app does, each change recorded in History. "
            + "Switch archives with `arrumatorcli archive switch`; add and change model profiles with `arrumatorcli profiles`.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Folder to watch for new files: neither the archive nor a folder inside it or around it.") var incoming: String?
    @Option(help: "The model profile documents and requests are read with, by its id as `arrumatorcli profiles` lists it.")
    var profile: String?
    @Option(help: "Ollama management: launchApp, spawnServe, external.") var ollama: OllamaManagement?
    @Option(help: "Ollama server: this Mac or a machine on the local network, such as http://192.168.1.20:11434.") var ollamaURL: String?
    @Option(help: "The `ollama` program to start when it is not where Ollama installs it; \"\" looks for it there again.")
    var ollamaBinary: String?
    @Option(help: "Pause processing (true/false).") var paused: Bool?
    @Option(help: "Show the app's icon in the Dock (true/false).") var showInDock: Bool?
    @Option(help: "Give filed documents the name the model chose (true/false).") var renameFiles: Bool?
    @Option(help: "Write file names in Latin letters (true/false).") var transliterate: Bool?
    @Option(help: "Describe images with the profile's model that describes images, so a picture is read by what it shows (true/false).")
    var describeImages: Bool?
    @Option(help: "Notify when a document is filed (true/false).") var notifyOnFiled: Bool?
    @Option(help: "Notify when a document waits for you (true/false).") var notifyOnReview: Bool?
    @Option(help: "Pause on battery when it runs low (true/false).") var pauseOnBattery: Bool?
    @Option(help: "Lowest level logged: error, warning, info, debug, trace.") var logLevel: LogLevel?
    @Option(help: "Days the prompts and raw model answers of a reading are kept in its trace, \(Self.retentionDays).")
    var traceRetentionDays: Int?
    @Option(help: "List the sidebar's labels under their kinds, rather than in one list, the most used first (true/false).")
    var groupLabelsByKind: Bool?
    @Option(help: "How much the model thinks before it answers a new search task's request: low (not at all), medium or high (the most).")
    var taskEffort: TaskEffort?

    func validate() throws {
        // An empty folder would be taken for the one the command runs in.
        if incoming?.isEmpty == true { throw ValidationError("--incoming needs a folder") }
    }

    func run() async throws {
        // A new server is checked before anything opens, and the runtime talks to it rather than to the saved one, which
        // may be an address this version refuses: so the command that gives another can always run.
        let server = try ollamaURL.map { try OllamaEndpoint.validated($0) }
        // Settings the app could not run with, as an earlier version let them be saved, are taken to be mended: the
        // command always runs, and refuses only what the settings given leave unusable, naming the file.
        let runtime = try await options.runtimeMendingSettings(ollamaURL: server)
        // Every other setting given is one change, checked whole before anything is saved: a profile the settings do not
        // list, or settings the app could not start with, refuse all of it. Pausing and the server, which have actions of
        // their own, come after it, so nothing is saved once anything given is refused.
        try await runtime.settingsActions.change(given)
        try await runtime.settings.refuseUnusable()
        // The settings are saved and their change recorded by now. An archive that cannot be opened for another reason
        // stops the command, as pausing and the server act on it, saying what was saved, so the user does not give it
        // again.
        do { _ = try await options.openEvenIfUnread(runtime) } catch {
            FileHandle.standardError.write(Data("The settings given were saved and recorded; then the archive could not be opened.\n".utf8))
            throw error
        }
        if let paused { try await runtime.setPaused(paused) }
        if let server {
            try await runtime.useOllama(at: server.absoluteString)
            _ = await runtime.lifecycle.ensureRunning()
        }
        let settings = await runtime.settings.current
        try options.emit(settings) { try JSON.string(settings, pretty: true) }
    }

    /// The settings given, other than pausing and the Ollama server, which have actions of their own, as one change to
    /// the settings in force. A folder or program given by a partial path is taken from the folder the command runs in.
    private var given: @Sendable (inout AppSettings) throws -> Void {
        let (profile, incoming, ollama) = (profile, incoming.map(Self.fullPath), ollama)
        let ollamaBinary = ollamaBinary.map { $0.isEmpty ? nil : Self.fullPath($0) }
        let (showInDock, renameFiles, transliterate, describeImages) = (showInDock, renameFiles, transliterate, describeImages)
        let (notifyOnFiled, notifyOnReview, pauseOnBattery, logLevel) = (notifyOnFiled, notifyOnReview, pauseOnBattery, logLevel)
        let (traceRetentionDays, groupLabelsByKind, taskEffort) = (traceRetentionDays, groupLabelsByKind, taskEffort)
        return { s in
            if let profile { try s.use(profile: profile) }
            if let incoming { s.incomingPath = incoming }
            if let ollama { s.ollamaManagement = ollama }
            if let ollamaBinary { s.ollamaBinaryPath = ollamaBinary }
            if let showInDock { s.showInDock = showInDock }
            if let renameFiles { s.renameFiles = renameFiles }
            if let transliterate { s.transliterate = transliterate }
            if let describeImages { s.enableVLM = describeImages }
            if let notifyOnFiled { s.notifyOnFiled = notifyOnFiled }
            if let notifyOnReview { s.notifyOnReview = notifyOnReview }
            if let pauseOnBattery { s.pauseOnBattery = pauseOnBattery }
            if let logLevel { s.logLevel = logLevel }
            if let traceRetentionDays { s.traceRawRetentionDays = traceRetentionDays }
            if let groupLabelsByKind { s.groupLabelsByKind = groupLabelsByKind }
            if let taskEffort { s.taskEffort = taskEffort }
        }
    }

    /// How many days the prompts of a reading may be kept, as its option says.
    private static let retentionDays = "from \(AppSettings.traceRawRetentionDaysRange.lowerBound) to \(AppSettings.traceRawRetentionDaysRange.upperBound)"

    /// `path` from the top of the disk: as given when it starts at `/` or `~`, otherwise inside the folder the command runs
    /// in, as a shell takes it.
    private static func fullPath(_ path: String) -> String {
        path.hasPrefix("~") ? path : URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

extension OllamaManagement: ExpressibleByArgument {}
