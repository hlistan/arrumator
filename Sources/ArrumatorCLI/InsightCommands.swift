import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Where the pipeline needs tuning: accuracy, confusions, calibration, latency.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let runtime = try await options.runtime()
        let insights = try await runtime.stats.insights()
        let taxonomy = try await runtime.taxonomy.snapshot(root: await runtime.settings.current.archiveURL)
        let folder = { (code: String) in taxonomy.path(ofCode: code) ?? code }
        options.emit(insights) {
            var out = ["Documents: \(insights.documents) · decided by \(insights.decidedBy.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))"]
            out.append("Accuracy (not later moved by you): " + insights.accuracy.map { "\($0.days)d \(Format.percent($0.accuracy)) of \($0.autoFiled)" }
                .joined(separator: " · "))
            if !insights.accuracyByLanguage.isEmpty {
                out.append("By language: " + insights.accuracyByLanguage.sorted { $0.key < $1.key }.map { "\($0.key) \(Format.percent($0.value))" }
                    .joined(separator: ", "))
            }
            if !insights.confusion.isEmpty {
                out.append("Most frequent corrections:")
                out += insights.confusion.map { "  \(folder($0.from)) → \(folder($0.to)): \($0.count)" }
            }
            out.append("Auto-filing threshold what-if:")
            out += insights.whatIf.map { "  ≥ \(String(format: "%.2f", $0.autoThreshold)): \(Format.percent($0.autoShare)) automatic, \(Format.percent($0.autoAccuracy)) right" }
            out.append("Latency per stage (p50 / p95):")
            out += insights.latency.map { "  \($0.stage.padding(toLength: 12, withPad: " ", startingAt: 0)) \(Int($0.p50Ms)) / \(Int($0.p95Ms)) ms (\($0.count))" }
            out.append("Rules: \(insights.rules), hits \(insights.ruleHits), contradictions \(insights.ruleContradictions)")
            if let ocr = insights.meanOCRConfidence { out.append(String(format: "Mean OCR confidence: %.2f", ocr)) }
            if !insights.warnings.isEmpty { out.append("Extraction warnings: " + insights.warnings.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
            if !insights.overlaps.isEmpty {
                out.append("Folders that look alike (consider merging or sharpening descriptions):")
                out += insights.overlaps.map { "  \(folder($0.a)) ~ \(folder($0.b)) (\(String(format: "%.2f", $0.similarity)))" }
            }
            return out.joined(separator: "\n")
        }
    }
}

struct Funnel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "How far documents got through the pipeline and where they stopped.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Only documents that arrived in the last N days.") var days = 30

    func run() async throws {
        let runtime = try await options.runtime()
        let funnel = try await runtime.stats.funnel(days: days)
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
            if !funnel.decisions.isEmpty {
                out.append("Who chose the folder:")
                out += funnel.decisions.map { "  \($0.count) \($0.id.lowercased())\($0.learned ? " (no model call)" : "")" }
                out.append("Placed without the model: \(funnel.decidedWithoutModel) of \(funnel.decidedTotal)")
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
        let paths = AppPaths.resolve()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            return try Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
        }
        let cutoff = minutes.map { Date().addingTimeInterval(-$0 * 60) }
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
                        print("\(entry.ts.formatted(.iso8601.time(includingFractionalSeconds: false))) \(entry.level.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(entry.cat.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(entry.msg) \(fields)")
                    }
                }
            }
            if follow { try await Task.sleep(for: .seconds(Self.followInterval)) }
        } while follow
    }

    /// Polling interval for `--follow`.
    static let followInterval: Double = 1
}

extension LogCategory: ExpressibleByArgument {}
extension LogLevel: ExpressibleByArgument {}

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Local models: status of the configured ones, and explicit downloads.",
                                                    subcommands: [Status.self, Pull.self], defaultSubcommand: Status.self)

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
                    "\($0.installed ? "✓" : "✗") \($0.role.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.name)"
                        + ($0.sizeBytes.map { String(format: "  %.1f GB", Double($0) / 1_073_741_824) } ?? "")
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
    static let configuration = CommandConfiguration(abstract: "Write a zip with logs, recent traces, doctor report, settings and folder tree.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Also include prompts that contain document text.") var includeDocumentText = false
    @Argument var output: String

    func run() async throws {
        let runtime = try await options.runtime()
        let settings = await runtime.settings.current
        let exporter = DiagnosticsExporter(database: runtime.database, paths: runtime.paths, config: runtime.config.stats)
        let contents = try await exporter.export(to: URL(fileURLWithPath: output.expandingTilde), doctor: await runtime.runDoctor(),
                                                 settings: settings,
                                                 taxonomy: try await runtime.taxonomy.snapshot(root: settings.archiveURL),
                                                 includeDocumentText: includeDocumentText)
        options.emit(contents) { "Wrote \(output): \(contents.logFiles.count) log files, \(contents.traces) traces" }
    }
}
