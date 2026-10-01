import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "How the archive is labelled and where the pipeline spends its time.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let insights = try await options.runtime().stats.insights()
        options.emit(insights) {
            var out = ["Documents: \(insights.documents) · " + insights.statuses.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")]
            out.append("Labelled: \(insights.labelled) · not labelled yet: \(insights.unlabelled)")
            if !insights.labelsByKind.isEmpty {
                out.append("Labels: " + LabelKind.allCases.map { "\($0.rawValue) \(insights.labelsByKind[$0.rawValue] ?? 0)" }
                    .joined(separator: ", "))
            }
            out.append("Corrected by you: \(insights.corrected) · confirmed: \(insights.confirmed)")
            out.append("Rules about labels: " + LabelRuleAction.allCases.map { "\($0.rawValue) \(insights.labelRules[$0.rawValue] ?? 0)" }
                .joined(separator: " · ") + " · labels tidied in readings: \(insights.labelsTidied)")
            out.append("Latency per stage (p50 / p95):")
            out += insights.latency.map { "  \($0.stage.padding(toLength: 13, withPad: " ", startingAt: 0)) \(Int($0.p50Ms)) / \(Int($0.p95Ms)) ms (\($0.count))" }
            if let ocr = insights.meanOCRConfidence { out.append(String(format: "Mean OCR confidence: %.2f", ocr)) }
            if !insights.warnings.isEmpty {
                let warnings = insights.warnings.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
                out.append("Extraction warnings: " + warnings.joined(separator: ", "))
            }
            return out.joined(separator: "\n")
        }
    }
}

struct Funnel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "How far documents got through the pipeline and where they stopped.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Only documents that arrived in the last N days (stats.defaultWindowDays unless set).") var days: Int?

    func run() async throws {
        let runtime = try await options.runtime()
        let funnel = try await runtime.stats.funnel(days: days ?? runtime.config.stats.defaultWindowDays)
        options.emit(funnel) {
            var out = ["\(funnel.documents) documents in the last \(funnel.windowDays) days"]
            for step in funnel.steps {
                var line = "  \(step.title.padding(toLength: 30, withPad: " ", startingAt: 0)) \(step.reached) reached"
                if step.dropped > 0 { line += ", \(step.dropped) stopped" }
                if step.medianMs > 0 { line += " · \(Int(step.medianMs)) ms median" }
                if step.errors > 0 { line += " · \(step.errors) errors" }
                if step.warnings > 0 { line += " · \(step.warnings) warnings" }
                out.append(line)
                out += step.stoppedHere.map { "      \($0.count) \($0.reason.lowercased())" }
            }
            if let slow = funnel.slowestStep { out.append("Slowest step: \(slow.title) at \(Int(slow.medianMs)) ms median") }
            if let drop = funnel.biggestDropOff { out.append("Most documents stopped at: \(drop.title) (\(drop.dropped))") }
            return out.joined(separator: "\n")
        }
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read the structured logs (JSONL, one file per day).")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Only this category (app, watch, ingest, extract, classify, ollama, …).") var category: LogCategory?
    @Option(help: "Minimum level: error, warning, info, debug, trace.") var level: LogLevel = .info
    @Option(help: "Only lines newer than this many minutes.") var minutes: Double?
    @Flag(help: "Keep printing new lines.") var follow = false

    func run() async throws {
        // Logs are read without opening the archive, so this reads the configuration alone.
        let paths = AppPaths.resolve(.current)
        let followInterval = try PipelineConfig.load(paths: paths, environment: .current).logging.followInterval
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            return try Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
        }
        let cutoff = minutes.map { Date().addingTimeInterval(-$0 * Units.secondsPerMinute) }
        var offsets: [URL: UInt64] = [:]
        repeat {
            let files = ((try? FileManager.default.contentsOfDirectory(at: paths.logsDirectory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                try handle.seek(toOffset: offsets[file] ?? 0)
                let data = handle.readDataToEndOfFile()
                offsets[file] = (offsets[file] ?? 0) + UInt64(data.count)
                for line in data.split(separator: 0x0A) {
                    guard let entry = try? decoder.decode(LogEntry.self, from: Data(line)), entry.level <= level,
                          category.map({ $0 == entry.cat }) ?? true, cutoff.map({ entry.ts >= $0 }) ?? true else { continue }
                    if options.json {
                        print(String(decoding: line, as: UTF8.self))
                    } else {
                        let fields = entry.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                        let time = entry.ts.formatted(.iso8601.time(includingFractionalSeconds: false))
                        let level = entry.level.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
                        let category = entry.cat.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
                        print("\(time) \(level) \(category) \(entry.msg) \(fields)")
                    }
                }
            }
            if follow { try await SystemTime().sleep(seconds: followInterval) }
        } while follow
    }
}

extension LogCategory: ExpressibleByArgument {}
extension LogLevel: ExpressibleByArgument {}

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Local models: status of the configured ones, every one installed that can read a request, and explicit downloads.",
        subcommands: [Status.self, List.self, Pull.self], defaultSubcommand: Status.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Every installed model that answers in words: those a search task can be given (`tasks new --model`).")
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            _ = await runtime.lifecycle.ensureRunning()
            let models = try await runtime.models.chatModels()
            options.emit(models) { models.isEmpty ? "No model that answers in words is installed." : models.joined(separator: "\n") }
        }
    }

    struct Status: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            let settings = await runtime.settings.current
            _ = await runtime.lifecycle.ensureRunning()
            let resolved = try runtime.config.models(for: settings.models)
            let status = try await runtime.models.status(for: resolved)
            options.emit(status) {
                (["Profile \(resolved.profileName)"] + status.map {
                    "\($0.installed ? "✓" : "✗") \($0.role.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.name)"
                        + ($0.sizeBytes.map { String(format: "  %.1f GB", Double($0) / Units.bytesPerGigabyte) } ?? "")
                }).joined(separator: "\n")
            }
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download a model (needs the internet; recognition never does).")
        @OptionGroup var options: GlobalOptions
        @Argument var model: String
        func run() async throws {
            let runtime = try await options.runtime()
            _ = await runtime.lifecycle.ensureRunning()
            var last = ""
            for try await p in try await runtime.models.pull(model) {
                let status = p.status ?? ""
                let line = p.fraction.map { "\(status) \(Format.percent($0))" } ?? status
                if line != last { print(line); last = line }
            }
        }
    }
}

struct Diagnostics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write a zip with logs, recent traces, doctor report and settings.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Also include the prompts and model answers that contain document text.") var includeDocumentText = false
    @Argument var output: String

    func run() async throws {
        let runtime = try await options.runtime()
        let contents = try await runtime.exportDiagnostics(to: URL(fileURLWithPath: output.expandingTilde),
                                                           includeDocumentText: includeDocumentText)
        options.emit(contents) { "Wrote \(output): \(contents.logFiles.count) log files, \(contents.traces) traces" }
    }
}
