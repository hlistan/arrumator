import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

@main
struct Arrumator: AsyncParsableCommand {
    static let version = AppVersion.of(.main)

    static let configuration = CommandConfiguration(
        commandName: "arrumatorcli",
        abstract: "Local-only document organiser: watches Incoming, understands files with local models, files them.",
        version: version,
        subcommands: [Doctor.self, Run.self, Ingest.self, Extract.self, Search.self, History.self, Trace.self, Replay.self,
                      Review.self, Folders.self, Rules.self, Senders.self, Forget.self, Archive.self, Logic.self,
                      Rethink.self, Proposals.self, Funnel.self, Stats.self, Rebuild.self, Logs.self, Models.self,
                      Diagnostics.self, Eval.self, Settings.self])
}

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    @Flag(name: .long, help: "Echo log lines to stderr.")
    var verbose = false

    func runtime() async throws -> ArrumatorRuntime {
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: Arrumator.version, echoLogsToStderr: verbose)
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

    /// A decision's folder by path, "NEW …" for one it would create: "NEW Portugal / Banking / Santander (by year)".
    static func target(of decision: FilingDecision, in taxonomy: TaxonomySnapshot) -> String? {
        taxonomy.destination(of: decision).map { destination in
            guard destination.isNew else { return destination.path }
            return "NEW \(destination.path)" + (decision.proposedNewFolder?.yearSubfolders == true ? " (by year)" : "")
        }
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
            if let path = status.currentPath {
                print("[\(status.currentStage?.rawValue ?? "")] \((path as NSString).lastPathComponent) — queue \(status.queued)")
            } else if status.waitingForOllama {
                print("Waiting for Ollama…")
            }
        }
    }
}

struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change settings (Incoming, model profile, …). Switch archives with `arrumatorcli archive switch`.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Folder to watch for new files.") var incoming: String?
    @Option(help: "Model profile defined in pipeline.json (standard, balanced, lowMemory).") var profile: String?
    @Option(help: "Language for folder names and descriptions.") var folderLanguage: String?
    @Option(help: "Automatically create folders the model proposes (true/false).") var autoCreateFolders: Bool?
    @Option(help: "Ollama management: launchApp, spawnServe, external.") var ollama: OllamaManagement?
    @Option(help: "Ollama server: this Mac or a machine on the local network, such as http://192.168.1.20:11434.") var ollamaURL: String?
    @Option(help: "Pause processing (true/false).") var paused: Bool?

    func run() async throws {
        let runtime = try await options.runtime()
        let (incoming, profile, language, autoCreate, ollama, paused) =
            (incoming, profile, folderLanguage, autoCreateFolders, ollama, self.paused)
        let updated = try await runtime.settings.update { s in
            if let incoming { s.incomingPath = incoming }
            if let profile { s.models.profile = profile }
            if let language { s.folderNamingLanguage = language }
            if let autoCreate { s.autoCreateFolders = autoCreate }
            if let ollama { s.ollamaManagement = ollama }
            if let paused { s.paused = paused }
        }
        _ = try runtime.config.models(for: updated.models)
        if let ollamaURL {
            try await runtime.useOllama(at: ollamaURL)
            _ = await runtime.lifecycle.ensureRunning()
        }
        let current = await runtime.settings.current
        options.emit(current) { JSON.string(current, pretty: true) }
    }
}

extension OllamaManagement: ExpressibleByArgument {}
