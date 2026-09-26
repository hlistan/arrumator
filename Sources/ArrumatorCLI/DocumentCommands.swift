import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Ingest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "File documents now (moves them into the archive), or show what would happen with --dry-run.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Analyse and decide without moving files or recording anything.") var dryRun = false
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
                let taxonomy = try await runtime.taxonomy.snapshot(root: settings.archiveURL)
                let outcome = try await runtime.classifier.classify(content, taxonomy: taxonomy, settings: settings,
                                                                    config: runtime.config, mode: .arrival, trace: trace)
                let steps = await sink.steps
                options.emit(DryRun(content: content, decision: outcome.decision, steps: steps)) {
                    describe(outcome.decision, content: content, steps: steps, taxonomy: taxonomy)
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
        var decision: FilingDecision
        var steps: [TraceStep]
    }

    func describe(_ d: FilingDecision, content: ExtractedContent, steps: [TraceStep], taxonomy: TaxonomySnapshot) -> String {
        let target = Terminal.target(of: d, in: taxonomy) ?? "Needs review"
        return """
        \(content.source.originalFilename)
          content:   \(content.kind.rawValue), \(content.textOrigin.rawValue), \(content.text.count) chars, language \(content.language.primary)
          decision:  \(target)
          file name: \(d.fileName ?? "(template)")
          metadata:  \(d.documentType.rawValue) · \(d.correspondent ?? "—") · \(d.documentDate ?? "—")
          confidence \(String(format: "%.2f", d.confidence.final)) → \(d.confidence.band.rawValue), decided by \(d.decidedBy.rawValue)
          rationale: \(d.rationale)
          stages:    \(steps.map { "\($0.stage.rawValue) \(Int($0.durationMs))ms" }.joined(separator: ", "))
        """
    }
}

func visionOptions(_ runtime: ArrumatorRuntime, _ settings: AppSettings) throws -> VisionModelOptions {
    let models = try runtime.config.models(for: settings.models)
    return VisionModelOptions(model: models.vision, keepAlive: models.keepAliveChat,
                              numPredict: runtime.config.classification.vlmNumPredict, numCtx: models.visionNumCtx,
                              options: runtime.config.classification.llmOptions)
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
                                                   sources: $0.sources.map(\.rawValue).sorted()) }) {
            var lines = results.hits.map { hit in
                "\(hit.document.path)\n    \(Terminal.highlight(hit.snippet).replacingOccurrences(of: "\n", with: " "))"
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
    }
}

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recent events: arrivals, filings, corrections, rules, folders.")
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
            var lines = ["Trace #\(id) · \(trace.source) · \(trace.outcome ?? "running") · \(Int(trace.totalMs ?? 0)) ms · models \(trace.modelChat ?? "—") / \(trace.modelEmbed ?? "—")"]
            for s in steps {
                lines.append("\(String(s.seq).padding(toLength: 3, withPad: " ", startingAt: 0)) \(s.stage.padding(toLength: 13, withPad: " ", startingAt: 0)) \(s.status.padding(toLength: 7, withPad: " ", startingAt: 0)) \(Int(s.durationMs)) ms")
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
        abstract: "Ask the model again about a stored document, from the archive's logic and optionally with another model, without touching files.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Chat model to use instead of the configured one.") var model: String?
    @Argument(help: "Document id or file path.") var document: String

    func run() async throws {
        let runtime = try await options.runtime()
        let docID = try await resolveDocument(document, runtime: runtime)
        guard let content = try await runtime.services.documents.content(docID: docID) else {
            throw ValidationError("Document \(docID) has no stored content")
        }
        var settings = await runtime.settings.current
        if let model { settings.models.chatModel = model }
        _ = await runtime.lifecycle.ensureRunning()
        let taxonomy = try await runtime.taxonomy.snapshot(root: settings.archiveURL)
        let trace = try await runtime.services.startTrace(docID: docID, jobID: nil, attempt: 0, source: .replay, settings: settings)
        let outcome = try await runtime.classifier.classify(content, taxonomy: taxonomy, settings: settings, config: runtime.config,
                                                            mode: .rethink(documentID: docID), trace: trace)
        await runtime.traces.finish(trace, outcome: "replay", docID: docID)
        let original = try await runtime.services.documents.document(id: docID)?.decision
        options.emit(["original": original, "replay": outcome.decision]) {
            """
            original: \(original.flatMap { Terminal.target(of: $0, in: taxonomy) } ?? "—") · \(original?.fileName ?? "—") · \(String(format: "%.2f", original?.confidence.final ?? 0))
            replay:   \(Terminal.target(of: outcome.decision, in: taxonomy) ?? "review") · \(outcome.decision.fileName ?? "—") · \(String(format: "%.2f", outcome.decision.confidence.final)) (\(outcome.decision.decidedBy.rawValue))
            trace #\(trace.traceID ?? 0)
            """
        }
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
