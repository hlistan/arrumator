import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Ingest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "File documents now (reads, labels and moves them into the archive), or show what would happen with --dry-run.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Read and label without moving files or recording anything.") var dryRun = false
    @Argument(help: "Files to ingest.") var files: [String]

    func run() async throws {
        let runtime = try await options.runtime()
        let settings = await runtime.settings.current
        _ = await runtime.lifecycle.ensureRunning()
        for path in files {
            let url = URL(fileURLWithPath: path.expandingTilde).standardizedFileURL
            if dryRun {
                let sink = MemoryTraceSink()
                let trace = TraceContext(traceID: 0, sink: sink)
                let content = try await runtime.services.extractor.extract(
                    url, sha256: try HashService.sha256(of: url),
                    context: ExtractionContext(config: runtime.config.extraction, entities: runtime.config.entities,
                                               vision: settings.enableVLM ? try visionOptions(runtime, settings) : nil),
                    trace: trace)
                let outcome = try await runtime.analyzer.analyse(content, settings: settings, config: runtime.config, trace: trace)
                let steps = await sink.steps
                options.emit(DryRun(content: content, analysis: outcome.analysis, labels: outcome.labels, steps: steps)) {
                    describe(outcome, content: content, steps: steps)
                }
            } else {
                await runtime.coordinator.enqueue(url)
            }
        }
        if !dryRun {
            await runtime.coordinator.drain()
            let docs = try await runtime.services.documents.list(DocumentFilter(), limit: files.count)
            options.emit(docs) {
                docs.map { "\($0.status.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \($0.path)" }.joined(separator: "\n")
            }
        }
    }

    struct DryRun: Encodable {
        var content: ExtractedContent
        var analysis: DocumentAnalysis
        /// Nil when the model gave no valid answer.
        var labels: [DocumentLabel]?
        var steps: [TraceStep]
    }

    func describe(_ outcome: AnalysisOutcome, content: ExtractedContent, steps: [TraceStep]) -> String {
        let a = outcome.analysis
        return """
        \(content.source.originalFilename)
          content:   \(content.kind.rawValue), \(content.textOrigin.rawValue), \(content.text.count) chars, language \(content.language.primary)
        \(Terminal.labelTable(outcome.labels, indent: 2))
          file name: \(a.fileName ?? "(keeps its name)")
          read by:   \(a.model ?? "—")\(a.problems.isEmpty ? "" : "; waits for you: " + a.problems.joined(separator: "; "))
          stages:    \(steps.map { "\($0.stage.rawValue) \(Int($0.durationMs))ms" }.joined(separator: ", "))
        """
    }
}

func visionOptions(_ runtime: ArrumatorRuntime, _ settings: AppSettings) throws -> VisionModelOptions {
    let models = try runtime.config.models(for: settings.models)
    return VisionModelOptions(model: models.vision, keepAlive: models.keepAliveChat,
                              numPredict: runtime.config.analysis.vlmNumPredict, numCtx: models.visionNumCtx,
                              options: runtime.config.analysis.llmOptions)
}

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what the extractors read from a file (no model decisions).")
    @OptionGroup var options: GlobalOptions
    @Argument var file: String

    func run() async throws {
        let runtime = try await options.runtime()
        let settings = await runtime.settings.current
        let url = URL(fileURLWithPath: file.expandingTilde)
        let content = try await runtime.services.extractor.extract(
            url, sha256: try HashService.sha256(of: url),
            context: ExtractionContext(config: runtime.config.extraction, entities: runtime.config.entities,
                                       vision: settings.enableVLM ? try visionOptions(runtime, settings) : nil),
            trace: .disabled)
        options.emit(content) {
            """
            \(content.source.originalFilename) — \(content.source.utType), \(content.source.byteSize) bytes
            kind \(content.kind.rawValue), text \(content.textOrigin.rawValue), \(content.text.count) chars, pages \(content.pageCount.map(String.init) ?? "—")
            language \(content.language.primary) (\(String(format: "%.2f", content.language.confidence)))
            date \(content.entities.documentDate.map { "\($0.date) via \($0.source.rawValue)" } ?? "—")
            identifiers \(content.entities.stableKeys.map(\.token).joined(separator: ", "))
            warnings \(content.warnings.map(\.code.rawValue).joined(separator: ", "))
            ---
            \(content.text.prefix(2_000))
            """
        }
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search the archive (full text + semantic).")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Full-text only.") var noSemantic = false
    @Argument(parsing: .remaining) var query: [String]

    func run() async throws {
        let runtime = try await options.runtime()
        try await runtime.prepareSearch(await runtime.settings.current)
        let results = try await runtime.search.search(SearchQuery(text: query.joined(separator: " "), semantic: !noSemantic))
        options.emit(results.hits.map { SearchRow(id: $0.id, path: $0.document.path, score: $0.score, snippet: SearchHighlight.plain($0.snippet),
                                                   sources: $0.sources.map(\.rawValue).sorted(), labels: $0.document.labels) }) {
            var lines = results.hits.map { hit in
                "\(hit.document.path)\n    \(Terminal.highlight(hit.snippet).replacingOccurrences(of: "\n", with: " "))"
                    + (hit.document.labels?.isEmpty == false ? "\n    \(Terminal.labels(hit.document.labels))" : "")
            }
            lines.append(String(format: "%d results in %.0f ms%@", results.hits.count, results.elapsedMs,
                                results.semanticUsed ? " (hybrid)" : " (full text: \(results.semanticUnavailableReason ?? ""))"))
            return lines.joined(separator: "\n")
        }
    }

    struct SearchRow: Encodable {
        var id: Int64
        var path: String
        var score: Double
        var snippet: String
        var sources: [String]
        var labels: [DocumentLabel]?
    }
}

struct Labels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a document's labels, correct them, or label every document that has none.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Give the document this label, as kind=value, such as sender=EDP or topic=electricity (repeatable).")
    var add: [String] = []
    @Option(help: "Take this label, as kind=value, off the document (repeatable).") var remove: [String] = []
    @Flag(help: "Read every document that has no labels yet with the model, such as one the model gave no answer for.")
    var unlabelled = false
    @Argument(help: "Document id or file path.") var document: String?

    func validate() throws {
        guard (document == nil) == unlabelled else { throw ValidationError("Name one document, or pass --unlabelled alone.") }
        if unlabelled && !(add.isEmpty && remove.isEmpty) { throw ValidationError("--add and --remove apply to one document.") }
        _ = try (add + remove).map(Self.label)
    }

    /// `kind=value` as a label.
    static func label(_ text: String) throws -> DocumentLabel {
        let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = LabelKind(rawValue: parts[0].trimmingCharacters(in: .whitespaces)) else {
            throw ValidationError("“\(text)” is no kind=value; the kinds are " + LabelKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return DocumentLabel(kind: kind, value: parts[1])
    }

    func run() async throws {
        let runtime = try await options.runtime()
        var ids: [Int64]
        if let document {
            let id = try await resolveDocument(document, runtime: runtime)
            ids = [id]
            if !(add.isEmpty && remove.isEmpty) {
                let removed = Set(try remove.map(Self.label).compactMap { DocumentLabel.normalized($0.value, kind: $0.kind) })
                let current = try await runtime.services.documents.document(id: id)?.labels ?? []
                try await runtime.review.edit(id, fileName: nil, labels: current.filter { !removed.contains($0) } + (try add.map(Self.label)))
            }
        } else {
            _ = await runtime.lifecycle.ensureRunning()
            ids = try await runtime.services.documents.unlabelled()
            for id in ids { try await runtime.review.retry(id) }
            await runtime.coordinator.drain()
        }
        var rows: [Row] = []
        for id in ids {
            guard let doc = try await runtime.services.documents.document(id: id) else { throw ValidationError("No document \(id)") }
            rows.append(Row(id: id, path: doc.path, labels: doc.labels))
        }
        if unlabelled {
            options.emit(rows) {
                (rows.map { "#\($0.id) \($0.path)\n    \(Terminal.labels($0.labels))" }
                    + ["Labelled \(rows.filter { $0.labels != nil }.count) of \(Format.count(rows.count, "document"))"])
                    .joined(separator: "\n")
            }
        } else if let row = rows.first {
            options.emit(row) {
                guard let labels = row.labels else {
                    return "\(row.path)\nNot labelled yet; `arrumatorcli review retry \(row.id)` reads it again."
                }
                return row.path + "\n" + Terminal.labelTable(labels, indent: 2)
            }
        }
    }

    struct Row: Encodable {
        var id: Int64
        var path: String
        /// Nil until the model has labelled the document.
        var labels: [DocumentLabel]?
    }
}

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recent events: arrivals, readings, filings, corrections, what was learned.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Number of events.") var limit = 50
    @Option(help: "Only events of this document.") var doc: Int64?

    func run() async throws {
        let runtime = try await options.runtime()
        let events = try await runtime.services.history.events(limit: limit, docID: doc)
        options.emit(events) {
            Terminal.table(events.reversed().map { [Format.date($0.at), $0.kind.rawValue, $0.actor.rawValue,
                                                  $0.docId.map { "#\($0)" } ?? "", $0.summary] })
        }
    }
}

struct Trace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show how a document was processed: every stage, its inputs, outputs and timing.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Include full stage inputs and outputs (prompts, raw model responses).") var full = false
    @Argument(help: "Document id or file path.") var document: String

    func run() async throws {
        let runtime = try await options.runtime()
        let docID = try await resolveDocument(document, runtime: runtime)
        guard let latest = try await runtime.traces.traces(docID: docID).first, let id = latest.id,
              let (trace, steps) = try await runtime.traces.trace(id: id) else {
            throw ValidationError("No trace recorded for document \(docID)")
        }
        options.emit(TraceExport(trace: trace, steps: steps)) {
            var lines = ["Trace #\(id) · \(trace.source) · \(trace.outcome ?? "running") · \(Int(trace.totalMs ?? 0)) ms · "
                         + "models \(trace.modelChat ?? "—") / \(trace.modelEmbed ?? "—")"]
            for s in steps {
                let seq = String(s.seq).padding(toLength: 3, withPad: " ", startingAt: 0)
                let stage = s.stage.padding(toLength: 13, withPad: " ", startingAt: 0)
                let status = s.status.padding(toLength: 7, withPad: " ", startingAt: 0)
                lines.append("\(seq) \(stage) \(status) \(Int(s.durationMs)) ms")
                if let e = s.error { lines.append("      error: \(e)") }
                if full {
                    if let i = s.inputJson { lines.append("      in:  \(i)") }
                    if let o = s.outputJson { lines.append("      out: \(o)") }
                } else if let o = s.outputJson {
                    lines.append("      \(o.prefix(240))")
                }
            }
            return lines.joined(separator: "\n")
        }
    }
}

struct Replay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read a stored document again with the model, optionally another one, and compare, without touching files.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Chat model to use instead of the configured one.") var model: String?
    @Argument(help: "Document id or file path.") var document: String

    func run() async throws {
        let runtime = try await options.runtime()
        let docID = try await resolveDocument(document, runtime: runtime)
        guard let content = try await runtime.services.documents.content(docID: docID),
              let stored = try await runtime.services.documents.document(id: docID) else {
            throw ValidationError("Document \(docID) has no stored content")
        }
        var settings = await runtime.settings.current
        if let model { settings.models.chatModel = model }
        _ = await runtime.lifecycle.ensureRunning()
        let trace = try await runtime.services.startTrace(docID: docID, jobID: nil, attempt: 0, source: .replay, settings: settings)
        let outcome = try await runtime.analyzer.analyse(content, settings: settings, config: runtime.config, trace: trace)
        await runtime.traces.finish(trace, outcome: "replay", docID: docID)
        let original = Reading(analysis: stored.analysis, labels: stored.labels)
        let replay = Reading(analysis: outcome.analysis, labels: outcome.labels)
        options.emit(["original": original, "replay": replay]) {
            """
            original: \(original.analysis?.fileName ?? "—") · \(Terminal.labels(original.labels))
            replay:   \(replay.analysis?.fileName ?? "—") · \(Terminal.labels(replay.labels)) (\(replay.analysis?.model ?? "no answer"))
            trace #\(trace.traceID ?? 0)
            """
        }
    }

    struct Reading: Encodable {
        var analysis: DocumentAnalysis?
        var labels: [DocumentLabel]?
    }
}

func resolveDocument(_ reference: String, runtime: ArrumatorRuntime) async throws -> Int64 {
    if let id = Int64(reference) { return id }
    let path = URL(fileURLWithPath: reference.expandingTilde).standardizedFileURL.path
    guard let id = try await runtime.services.documents.document(path: path)?.id else {
        throw ValidationError("No document at \(path)")
    }
    return id
}
