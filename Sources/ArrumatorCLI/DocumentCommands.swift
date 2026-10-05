import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Ingest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "File documents now (reads, labels and moves them into the archive), or show what would happen with --dry-run.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Read and label without moving files or recording anything.") var dryRun = false
    @Option(help: "Give the documents this tag, your own label, besides the one the folder in Incoming they are in gives (repeatable).")
    var tag: [String] = []
    @Argument(help: "Files to ingest.") var files: [String]

    func validate() throws {
        for value in tag where DocumentLabel.normalized(value, kind: .tag) == nil {
            throw ValidationError("--tag “\(value)” is no tag: give it a name")
        }
    }

    func run() async throws {
        let runtime = try await options.runtime()
        let settings = await runtime.settings.current
        guard tag.count <= runtime.config.labels.maxPerKind else {
            throw ValidationError("--tag is given at most \(runtime.config.labels.maxPerKind) times (labels.maxPerKind)")
        }
        // Each file as the queue takes it, the package a path inside one names; one Incoming never takes in, as a link or
        // a package of too many items, is refused with why before anything is read.
        let urls = try files.map { try runtime.services.arrival(URL(fileURLWithPath: $0.expandingTilde), settings: settings) }
        _ = await runtime.lifecycle.ensureRunning()
        let failed = dryRun ? try await preview(urls, runtime: runtime, settings: settings) : try await ingest(urls, runtime: runtime)
        // Each file that failed was named on standard error; what the others came to is shown all the same.
        for (url, reason) in failed { FileHandle.standardError.write(Data("\(url.path): \(reason)\n".utf8)) }
        if !failed.isEmpty { throw ExitCode.failure }
    }

    /// Files each file, and shows the documents they became, in one list; the files that failed, each with why.
    private func ingest(_ urls: [URL], runtime: ArrumatorRuntime) async throws -> [(URL, String)] {
        var jobs: [(URL, Int64)] = []
        var failed: [(URL, String)] = []
        for url in urls {
            if let job = await runtime.coordinator.enqueue(url, tags: tag) {
                jobs.append((url, job))
            } else {
                failed.append((url, "not queued: it is held or undone in the archive, or the queue could not be written (see the log)"))
            }
        }
        await runtime.coordinator.drain()
        try Task.checkCancellation()
        // The documents these files became, whatever else the archive holds; for an exact copy of a document in the
        // archive, that document, read again in its place.
        var docs: [DocumentRecord] = []
        var waiting: [URL] = []
        for (url, id) in jobs {
            let job = try await runtime.services.jobs.job(id: id)
            if let doc = job?.docId ?? (try? job?.payload)?.copyOf, let document = try await runtime.services.documents.document(id: doc) {
                docs.append(document)
                if job?.state == .failed { failed.append((url, job?.lastError ?? "it could not be filed")) }
            } else if job?.state.isActive == true, job?.lastError == nil {
                // Not begun, as one another process, such as the app, has in hand before it is looked at: no failure.
                waiting.append(url)
            } else {
                // One that failed before it became a document, tried again later or not, fails here, saying why.
                failed.append((url, job?.lastError ?? "it became no document"))
            }
        }
        try options.emit(docs) {
            (docs.map { document in
                "\(document.status.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(document.path)"
                    + (document.labels(.tag).isEmpty ? "" : "\n            tags: " + document.labels(.tag).joined(separator: " · "))
            } + waiting.map { "\("queued".padding(toLength: 11, withPad: " ", startingAt: 0)) \($0.path)" }).joined(separator: "\n")
        }
        // The JSON is the documents alone; a file not begun, which is none yet, is named beside it, as no failure.
        if options.json { for url in waiting { FileHandle.standardError.write(Data("\(url.path): \(Self.notBegun)\n".utf8)) } }
        return failed
    }

    /// What `--json` says of a file queued and not begun, as one the app has in hand.
    static let notBegun = "queued, not read yet: the app or `run` files it"

    /// Reads and labels each file without moving it or recording anything, and shows what came of them in one list; the
    /// files that could not be read, each with why.
    private func preview(_ urls: [URL], runtime: ArrumatorRuntime, settings: AppSettings) async throws -> [(URL, String)] {
        var runs: [DryRun] = []
        var texts: [String] = []
        var failed: [(URL, String)] = []
        for url in urls {
            try Task.checkCancellation()
            do {
                let sink = MemoryTraceSink()
                let trace = TraceContext(traceID: 0, sink: sink)
                let tags = runtime.services.tags(for: url, given: tag, settings: settings)
                let context = try runtime.config.extractionContext(settings: settings, whenOllamaIsAway: .wait)
                let content = try await runtime.services.extractor.extract(url, sha256: try HashService.sha256(of: url), context: context,
                                                                           trace: trace)
                let reading = try await runtime.services.read(content, tags: tags.map(\.label), settings: settings, trace: trace)
                let steps = await sink.steps
                runs.append(DryRun(file: url.path, content: content, analysis: reading.outcome.analysis, labels: reading.outcome.labels,
                                   tags: tags, changes: reading.changes, steps: steps))
                texts.append(describe(reading, tags: tags, content: content, steps: steps))
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                failed.append((url, error.localizedDescription))
            }
        }
        try options.emit(runs) { texts.joined(separator: "\n") }
        return failed
    }

    struct DryRun: Encodable {
        /// The file read, as given.
        var file: String
        var content: ExtractedContent
        var analysis: DocumentAnalysis
        /// The model's labels, tidied, and the tags after them; nil when the model gave no valid answer.
        var labels: [DocumentLabel]?
        /// The tags the document would be given, and what gives each: the folder in Incoming it is in, or `--tag`.
        var tags: [GivenTag]
        /// Labels the model gave that the archive's vocabulary and the user's rules changed.
        var changes: [LabelChange]
        var steps: [TraceStep]
    }

    func describe(_ reading: Reading, tags: [GivenTag], content: ExtractedContent, steps: [TraceStep]) -> String {
        let a = reading.outcome.analysis
        let tagged = GivenTag.note(tags).map { "\n  tags:      " + $0 } ?? ""
        return """
        \(content.source.originalFilename)
          content:   \(content.kind.rawValue), \(content.textOrigin.rawValue), \(content.text.count) chars, language \(content.language.primary)
        \(Terminal.labelTable(reading.outcome.labels, indent: 2))\(reading.changes.isEmpty ? "" : "\n  tidied:    " + Terminal.changes(reading.changes))\(tagged)
          file name: \(a.fileName ?? "(keeps its name)")
          read by:   \(a.model ?? "—")\(a.problems.isEmpty ? "" : "; waits for you: " + a.problems.joined(separator: "; "))
          stages:    \(steps.map { "\($0.stage.rawValue) \(Int($0.durationMs))ms" }.joined(separator: ", "))
        """
    }
}

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what the extractors read from a file (no model decisions).")
    @OptionGroup var options: GlobalOptions
    @Argument var file: String

    func run() async throws {
        let runtime = try await options.runtime()
        let settings = await runtime.settings.current
        let url = URL(fileURLWithPath: file.expandingTilde)
        // What is read now: an image Ollama is away to describe is shown without its description, noted.
        let context = try runtime.config.extractionContext(settings: settings, whenOllamaIsAway: .note)
        let content = try await runtime.services.extractor.extract(url, sha256: try HashService.sha256(of: url), context: context,
                                                                   trace: .disabled)
        let preview = runtime.config.interface.extractPreviewChars
        try options.emit(content) {
            """
            \(content.source.originalFilename) — \(content.source.utType), \(content.source.byteSize) bytes
            kind \(content.kind.rawValue), text \(content.textOrigin.rawValue), \(content.text.count) chars, pages \(content.pageCount.map(String.init) ?? "—")
            language \(content.language.primary) (\(String(format: "%.2f", content.language.confidence)))
            date \(content.entities.documentDate.map { "\($0.date) via \($0.source.rawValue)" } ?? "—")
            identifiers \(content.entities.stableKeys.map(\.token).joined(separator: ", "))
            warnings \(content.warnings.map(\.code.rawValue).joined(separator: ", "))
            ---
            \(content.text.prefix(preview))
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
        let results = try await runtime.search.search(SearchQuery(text: query.joined(separator: " "), semantic: !noSemantic))
        try options.emit(results.hits.map { SearchRow(id: $0.id, path: $0.document.path, score: $0.score, snippet: SearchHighlight.plain($0.snippet),
                                                   sources: $0.sources.map(\.rawValue).sorted(), labels: $0.document.labels,
                                                   labelled: $0.document.isLabelled) }) {
            var lines = results.hits.map { hit in
                "\(hit.document.path)\n    \(Terminal.highlight(hit.snippet).replacingOccurrences(of: "\n", with: " "))"
                    + (hit.document.labels?.isEmpty == false ? "\n    \(Terminal.labels(hit.document.labels, labelled: hit.document.isLabelled))" : "")
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
        /// Whether the document has been labelled; one that has not may have its tags.
        var labelled: Bool
    }
}

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recent events: arrivals, readings, filings, corrections, what was learned.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Number of events (interface.pageSize unless set).") var limit: Int?
    @Option(help: "Only events of this document.") var doc: Int64?

    func run() async throws {
        let runtime = try await options.runtime()
        let events = try await runtime.services.history.events(limit: limit ?? runtime.config.interface.pageSize, docID: doc)
        try options.emit(events) {
            Terminal.table(events.reversed().map { [Format.date($0.at), $0.kind.rawValue, $0.actor.rawValue,
                                                  $0.docId.map { "#\($0)" } ?? "", $0.summary] })
        }
    }
}

struct Trace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show how a document was processed: every stage, its status and timing, and with --full its inputs and outputs.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Include each stage's inputs, outputs and errors (the document's text, prompts, raw model responses).") var full = false
    @Argument(help: "Document id or file path.") var document: String

    func run() async throws {
        let runtime = try await options.runtime()
        let docID = try await resolveDocument(document, runtime: runtime)
        guard let latest = try await runtime.traces.traces(docID: docID).first, let id = latest.id,
              let (trace, steps) = try await runtime.traces.trace(id: id) else {
            throw ValidationError("No trace recorded for document \(docID)")
        }
        // Without --full nothing of the document is shown, so the output can go into a bug report.
        let shown = DiagnosticsExporter.shareable(steps, includeDocumentText: full)
        try options.emit(TraceExport(trace: full ? trace : DiagnosticsExporter.shareable(trace), steps: shown)) {
            "Trace #\(id) · \(trace.source) · \(trace.outcome ?? "running") · \(Int(trace.totalMs ?? 0)) ms · "
                + "models \(trace.modelChat ?? "—") / \(trace.modelEmbed ?? "—")\n" + Terminal.steps(shown, full: full)
                + (full ? "" : "\n" + Self.fullHint)
        }
    }

    /// What the output without --full says of what it leaves out.
    static let fullHint = "Each stage's inputs, outputs and errors hold the document's text and name; --full shows them."
}

struct Replay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read a stored document again with the model, optionally another one, and compare, without touching files.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Chat model to read with instead of the profile's.") var model: String?
    @Argument(help: "Document id or file path.") var document: String

    func run() async throws {
        let runtime = try await options.runtime()
        let docID = try await resolveDocument(document, runtime: runtime)
        guard let content = try await runtime.services.documents.content(docID: docID),
              let stored = try await runtime.services.documents.document(id: docID) else {
            throw ValidationError("Document \(docID) has no stored content")
        }
        var settings = await runtime.settings.current
        if let model { settings = try settings.reading(withChatModel: model) }
        _ = await runtime.lifecycle.ensureRunning()
        let trace = try await runtime.services.startTrace(docID: docID, jobID: nil, attempt: 0, source: .replay, settings: settings)
        // Read with the tags the document has, which a reading keeps, so what differs is what the model gives.
        let outcome = try await runtime.services.read(content, tags: stored.labels?.filter(\.kind.isUsersOwn) ?? [], settings: settings,
                                                      trace: trace).outcome
        await runtime.traces.finish(trace, outcome: "replay", docID: docID)
        let original = Reading(analysis: stored.analysis, labels: stored.labels)
        let replay = Reading(analysis: outcome.analysis, labels: outcome.labels)
        try options.emit(["original": original, "replay": replay]) {
            """
            original: \(original.analysis?.fileName ?? "—") · \(Terminal.labels(original.labels, labelled: stored.isLabelled))
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
    // A document in Incoming is recorded as the file system spells its path (`URL.spelledOnDisk`), one in the archive
    // as its settings spell it.
    let named = URL(fileURLWithPath: reference.expandingTilde)
    let path = named.standardizedFileURL.path
    var found = try await runtime.services.documents.document(path: named.spelledOnDisk.path)
    if found == nil { found = try await runtime.services.documents.document(path: path) }
    guard let id = found?.id else {
        throw ValidationError("No document at \(path)")
    }
    return id
}
