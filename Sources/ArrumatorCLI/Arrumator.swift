import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

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
}

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    @Flag(name: .long, help: "Echo log lines to stderr.")
    var verbose = false

    func runtime() async throws -> ArrumatorRuntime {
        let environment = RuntimeEnvironment.current
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: Arrumator.version, environment: environment,
                                                           echoLogsToStderr: verbose, trash: environment.trash(orElse: SystemTrash()))
        try await runtime.openArchive()
        return runtime
    }

    func emit(_ value: some Encodable, text: () -> String) {
        print(json ? JSON.string(value, pretty: true) : text())
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
    static let configuration = CommandConfiguration(abstract: "Check the environment: folders, database, Ollama, models, disk, network.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let runtime = try await options.runtime()
        let report = await runtime.runDoctor()
        options.emit(report) {
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
        await runtime.start()
        let current = await runtime.settings.current
        print("Watching \(current.incomingPath) → \(current.archivePath). Press Ctrl-C to stop.")
        for await status in await runtime.coordinator.statusUpdates() {
            if let current = status.current {
                let tags = current.tags.isEmpty ? "" : " · " + current.tags.map(\.value).joined(separator: " · ")
                print("[\(current.stage.rawValue)] \((current.path as NSString).lastPathComponent)\(tags) — queue \(status.queued)")
            } else if status.waitingForOllama {
                print("Waiting for Ollama…")
            }
        }
    }
}

struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change settings, as Settings in the app does, each change recorded in History. "
            + "Switch archives with `arrumatorcli archive switch`; add and change model profiles with `arrumatorcli profiles`.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Folder to watch for new files.") var incoming: String?
    @Option(help: "The model profile documents and requests are read with, by its id as `arrumatorcli profiles` lists it.")
    var profile: String?
    @Option(help: "Ollama management: launchApp, spawnServe, external.") var ollama: OllamaManagement?
    @Option(help: "Ollama server: this Mac or a machine on the local network, such as http://192.168.1.20:11434.") var ollamaURL: String?
    @Option(help: "Pause processing (true/false).") var paused: Bool?
    @Option(help: "Show the app's icon in the Dock (true/false).") var showInDock: Bool?
    @Option(help: "Give filed documents the name the model chose (true/false).") var renameFiles: Bool?
    @Option(help: "Write file names in Latin letters (true/false).") var transliterate: Bool?
    @Option(help: "Notify when a document is filed (true/false).") var notifyOnFiled: Bool?
    @Option(help: "Notify when a document waits for you (true/false).") var notifyOnReview: Bool?
    @Option(help: "Pause on battery when it runs low (true/false).") var pauseOnBattery: Bool?
    @Option(help: "Lowest level logged: error, warning, info, debug, trace.") var logLevel: LogLevel?
    @Option(help: "Days the prompts and raw model answers of a reading are kept in its trace.") var traceRetentionDays: Int?
    @Option(help: "List the sidebar's labels under their kinds, rather than in one list, the most used first (true/false).")
    var groupLabelsByKind: Bool?
    @Option(help: "How much the model thinks before it answers a new search task's request: low (not at all), medium or high (the most).")
    var taskEffort: TaskEffort?

    func validate() throws {
        if let traceRetentionDays, traceRetentionDays < 1 { throw ValidationError("--trace-retention-days must be at least 1") }
    }

    func run() async throws {
        let runtime = try await options.runtime()
        // The profile first: one the settings do not list is refused before anything else is saved.
        if let profile { try await runtime.profiles.use(profile) }
        try await runtime.settingsActions.change(given)
        if let paused { try await runtime.setPaused(paused) }
        if let ollamaURL {
            try await runtime.useOllama(at: ollamaURL)
            _ = await runtime.lifecycle.ensureRunning()
        }
        let settings = await runtime.settings.current
        options.emit(settings) { JSON.string(settings, pretty: true) }
    }

    /// The settings given, other than the profile, pausing and the Ollama server, which have actions of their own, as one
    /// change to the settings in force.
    private var given: @Sendable (inout AppSettings) -> Void {
        let (incoming, ollama) = (incoming, ollama)
        let (showInDock, renameFiles, transliterate) = (showInDock, renameFiles, transliterate)
        let (notifyOnFiled, notifyOnReview, pauseOnBattery, logLevel) = (notifyOnFiled, notifyOnReview, pauseOnBattery, logLevel)
        let (traceRetentionDays, groupLabelsByKind, taskEffort) = (traceRetentionDays, groupLabelsByKind, taskEffort)
        return { s in
            if let incoming { s.incomingPath = incoming }
            if let ollama { s.ollamaManagement = ollama }
            if let showInDock { s.showInDock = showInDock }
            if let renameFiles { s.renameFiles = renameFiles }
            if let transliterate { s.transliterate = transliterate }
            if let notifyOnFiled { s.notifyOnFiled = notifyOnFiled }
            if let notifyOnReview { s.notifyOnReview = notifyOnReview }
            if let pauseOnBattery { s.pauseOnBattery = pauseOnBattery }
            if let logLevel { s.logLevel = logLevel }
            if let traceRetentionDays { s.traceRawRetentionDays = traceRetentionDays }
            if let groupLabelsByKind { s.groupLabelsByKind = groupLabelsByKind }
            if let taskEffort { s.taskEffort = taskEffort }
        }
    }
}

extension OllamaManagement: ExpressibleByArgument {}
