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
        subcommands: [Doctor.self, Run.self, Ingest.self, Extract.self, Search.self, Labels.self, History.self, Trace.self, Replay.self,
                      Review.self, Archive.self, Funnel.self, Stats.self, Rebuild.self, Logs.self,
                      Models.self, Diagnostics.self, Eval.self, Settings.self])
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

    /// A document's labels on one line, "Maria Exemplo · Portugal · pt (Portuguese)", or why there are none.
    static func labels(_ labels: [DocumentLabel]?) -> String {
        guard let labels else { return "not labelled" }
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
    @Option(help: "Ollama management: launchApp, spawnServe, external.") var ollama: OllamaManagement?
    @Option(help: "Ollama server: this Mac or a machine on the local network, such as http://192.168.1.20:11434.") var ollamaURL: String?
    @Option(help: "Pause processing (true/false).") var paused: Bool?

    func run() async throws {
        let runtime = try await options.runtime()
        let (incoming, profile, ollama, paused) = (incoming, profile, ollama, self.paused)
        let updated = try await runtime.settings.update { s in
            if let incoming { s.incomingPath = incoming }
            if let profile { s.models.profile = profile }
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
