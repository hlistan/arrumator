import Foundation

/// Everything the pipeline needs, assembled by the composition root (app or CLI).
public struct PipelineServices: Sendable {
    public var database: AppDatabase
    /// The archive the pipeline files into, whose index `database` is: the runtime's own, whatever the settings name
    /// once a switch has made them name another.
    public var archive: URL
    public var config: PipelineConfig
    public var settings: SettingsStore
    public var extractor: any ContentExtracting
    public var analyzer: any DocumentAnalyzing
    public var filer: DocumentFiler
    public var traces: TraceRecorder
    public var vectors: VectorIndex
    /// Where an exact copy of a document in the archive goes once its original is read again in its place.
    public var trash: any Trashing
    public var time: any TimeSource
    /// The Ollama server, asked whether it answers at all when a request to it timed out.
    public var ollama: any OllamaAPI
    /// The Mac's time zone, which today is in when a request or a question is read.
    public var timeZone: TimeZone
    /// Which labels looked alike when last worked out, shared by every `LabelStore` this makes (`labels`).
    public let lookAlikes = LookAlikeMemo()

    public init(database: AppDatabase, archive: URL, config: PipelineConfig, settings: SettingsStore, extractor: any ContentExtracting,
                analyzer: any DocumentAnalyzing, filer: DocumentFiler, traces: TraceRecorder, vectors: VectorIndex,
                trash: any Trashing, time: any TimeSource, ollama: any OllamaAPI, timeZone: TimeZone) {
        self.database = database
        self.archive = archive.standardizedFileURL
        self.config = config
        self.settings = settings
        self.extractor = extractor
        self.analyzer = analyzer
        self.filer = filer
        self.traces = traces
        self.vectors = vectors
        self.trash = trash
        self.time = time
        self.ollama = ollama
        self.timeZone = timeZone
    }

    public var documents: DocumentStore { DocumentStore(database: database, time: time) }
    public var jobs: JobStore { JobStore(database: database, time: time) }
    public var history: HistoryStore { HistoryStore(database: database, time: time) }
    public var index: IndexStore { IndexStore(database: database, time: time) }

    /// Whether `document`'s file is in this pipeline's archive, whatever its status and however either path is spelled
    /// (`URL.holds`): one left in Incoming, failed or held there, is not.
    public func isInArchive(_ document: DocumentRecord) -> Bool {
        archive.holds(document.path)
    }

    /// The document a file named to be filed is, as the queue takes it: the package that holds it when it is in one, at
    /// its path as the disk spells it (`Packages.document(holding:incoming:)`). What the Incoming watcher never takes in is
    /// refused, saying why (`IngestError.notTaken`): a link, which would file what it points to, wherever that is, a
    /// hidden or temporary file, one of the app's own (`SkipRules`); and so is a package of more than
    /// `watcher.maxPackageItems` items (`FileOperationError.tooManyItems`), before anything reads it whole.
    public func arrival(_ named: URL, settings: AppSettings) throws -> URL {
        let url = Packages.document(holding: named, incoming: settings.incomingURL)
        if let reason = SkipRules(watcher: config.watcher).ignoreReason(url) { throw IngestError.notTaken(url.path, reason: reason) }
        try Packages.check(url, holdsAtMost: config.watcher.maxPackageItems)
        return url
    }

    /// Starts a trace stamped with the prompt version and the models of the profile in use. Settings that name no profile
    /// they list leave it unstamped: reading with them fails, saying so, and the trace records that.
    public func startTrace(docID: Int64?, jobID: Int64?, attempt: Int, source: TraceSource,
                           settings: AppSettings) async throws -> TraceContext {
        try await traces.start(TraceHeader(docID: docID, jobID: jobID, attempt: attempt, source: source,
                                           promptVersion: config.analysis.promptVersion,
                                           models: try? settings.modelProfile(), settings: settings))
    }

    /// Whether `error` says Ollama is away, which work waits out spending nothing, as every queue decides it: it could not
    /// be reached, or it did not answer in time and does not answer a probe for its version either, which a server busy
    /// with one request it cannot finish does. A server that answers the probe is there, and the work fails or spends an
    /// attempt.
    public func ollamaIsAway(_ error: any Error) async -> Bool {
        guard let error = error as? OllamaError else { return false }
        if error.isAway { return true }
        guard error.timedOut else { return false }
        // A probe: its failure is the answer, whatever it is.
        return (try? await ollama.version()) == nil
    }

    public var labels: LabelStore { LabelStore(database: database, config: config.labels, lookAlikes: lookAlikes) }

    /// The tags a file at `url` is given when it is queued (`GivenTag`): the name of the folder at the top of Incoming it is
    /// in (`IncomingFolders`), then those `given` with the command that files it, each once and at most
    /// `labels.maxPerKind`; a value that is no tag is left out.
    public func tags(for url: URL, given: [String], settings: AppSettings) -> [GivenTag] {
        let folder = IncomingFolders(incoming: settings.incomingURL, watcher: config.watcher, labels: config.labels).tag(of: url)
        let command = given.compactMap { config.labels.label($0, kind: .tag) }.map { GivenTag(label: $0, source: .command) }
        return GivenTag.distinct([folder].compactMap { $0 } + command, limit: config.labels.maxPerKind)
    }

    /// Gives a document the tags its file was queued with that it does not have yet, each as the user's rules write it
    /// and never merged with another unasked (`LabelConsolidator.ruled`), at most `labels.maxPerKind` tags in all. A tag
    /// labels nothing, so a document not labelled yet stays so. The trace records what gave each (`TraceStage.tag`).
    /// Returns the job's tags as the rules write them, those the rules drop left out.
    public func giveTags(_ given: [GivenTag], docID: Int64, trace: TraceContext) async throws -> [GivenTag] {
        let new = given.filter(\.isNew)
        guard !new.isEmpty, let document = try await documents.document(id: docID) else { return given }
        let consolidator = try await labels.consolidator()
        let ruled = await trace.measure(.tag, input: new, output: { (r: (tags: [GivenTag], consolidation: LabelConsolidation)) in r.consolidation }) {
            var changes: [LabelChange] = []
            let tags = new.compactMap { tag -> GivenTag? in
                let one = consolidator.ruled([tag.label])
                changes += one.changes
                return one.labels.first.map { GivenTag(label: $0, source: tag.source, folder: tag.folder) }
            }
            return (tags, LabelConsolidation(labels: tags.map(\.label), changes: changes))
        }
        let current = document.labels ?? []
        let had = current.filter(\.kind.isUsersOwn).map { GivenTag(label: $0, source: .document) }
        let added = GivenTag.distinct(had + ruled.tags, limit: config.labels.maxPerKind).filter(\.isNew).map(\.label)
        if !added.isEmpty { try await index.saveLabels(current + added, docID: docID, labelled: document.isLabelled) }
        return given.filter { !$0.isNew } + ruled.tags
    }

    /// Reads a document with the model, telling it of the archive's labels and the user's decisions about them, and
    /// keeps its labels one vocabulary with the archive's (`LabelConsolidator`), recording what that changed in the
    /// trace. The document's `tags`, the user's own, follow the user's rules alone and come after the model's labels.
    /// Nothing is saved: dry runs and replays read this way too.
    public func read(_ content: ExtractedContent, tags: [DocumentLabel], settings: AppSettings, trace: TraceContext) async throws -> Reading {
        var outcome = try await analyzer.analyse(content, guidance: try await labels.guidance(), settings: settings, config: config,
                                                 trace: trace)
        let consolidator = try await labels.consolidator()
        let kept = consolidator.ruled(tags).labels
        guard let given = outcome.labels else { return Reading(outcome: outcome, tags: kept, changes: []) }
        let consolidation = await trace.measure(.consolidate, input: given, output: { (c: LabelConsolidation) in c }) {
            consolidator.consolidate(given)
        }
        outcome.labels = (consolidation.labels + kept).distinct()
        return Reading(outcome: outcome, tags: kept, changes: consolidation.changes)
    }

    /// Queues `document` to be read again with the model and filed under the name it gives: where it is in the archive,
    /// or, for one outside it (back in Incoming), at the top of the archive. It keeps its tags, which its row in the
    /// queue shows, and one in a folder in Incoming is given that folder's too. With `content`, its text as read
    /// before, reading starts with the model; without it, its text is read from its file again too, as a file that
    /// arrives is read. One outside the archive, as one left in Incoming, or whose file is no longer as it was recorded
    /// (`FileFingerprint.matches`) is read as an arrival: hashed again, so an exact copy is handed over to its original
    /// (`IngestCoordinator`), and its text read from its file. The job, or the one already queued for its file, which
    /// reads it as well.
    @discardableResult
    public func queueReadingAgain(_ document: DocumentRecord, content: ExtractedContent?, settings: AppSettings) async throws -> Int64? {
        guard let docID = document.id else { throw IngestError.documentNotPersisted }
        var doc = document
        let inArchive = isInArchive(doc)
        if !inArchive || [.undone, .held].contains(doc.status) {
            doc.status = .processing
            doc = try await documents.save(doc)
        }
        // What earlier stages found of it goes with the job, so it starts at the first stage it lacks (`IngestCoordinator`).
        var payload = JobPayload()
        if inArchive, doc.isAsRecorded {
            payload.sha256 = doc.sha256
            payload.content = content
        }
        let kept = (doc.labels ?? []).filter(\.kind.isUsersOwn).map { GivenTag(label: $0, source: .document) }
        let tags = kept + (inArchive ? [] : self.tags(for: doc.url, given: [], settings: settings))
        payload.tags = tags.isEmpty ? nil : tags
        return try await jobs.enqueue(path: doc.path, kind: inArchive ? .reanalyse : .ingest, docID: docID, payload: payload)
    }

    /// Asks the model about a document and keeps what it says: the labels on the document and in the search index
    /// straight away, with the tags it has, and a history event with what it was labelled with, or why it was not, and
    /// what gave its tags (`given`, the tags its job was queued with). A document the model gives no valid answer keeps
    /// the labels it had: its tags, or what an earlier reading gave it.
    public func analyse(docID: Int64, jobID: Int64?, content: ExtractedContent, given: [GivenTag], settings: AppSettings,
                        trace: TraceContext) async throws -> AnalysisOutcome {
        let tags = try await documents.document(id: docID)?.labels?.filter(\.kind.isUsersOwn) ?? []
        let reading = try await read(content, tags: tags, settings: settings, trace: trace)
        let outcome = reading.outcome
        let sources = GivenTag.sources(of: reading.tags, given: given)
        let note = GivenTag.note(sources).map { "; " + $0 } ?? ""
        if let labels = outcome.labels {
            try await index.saveLabels(labels, docID: docID, labelled: true)
            let read = labels.filter { !$0.kind.isUsersOwn }
            try await history.record(.analysed, doc: docID, job: jobID, trace: trace.traceID,
                                     summary: (read.isEmpty ? "Nothing worth a label" : read.map(\.value).joined(separator: " · ")) + note,
                                     payload: AnalysedPayload(analysis: outcome.analysis, changes: reading.changes,
                                                              tags: sources.isEmpty ? nil : sources))
        } else {
            try await history.record(.error, doc: docID, job: jobID, trace: trace.traceID,
                                     summary: "Not read: " + outcome.analysis.problems.joined(separator: "; ") + note, payload: outcome.analysis)
        }
        return outcome
    }
}

/// A reading of a document: what the model gave it, its labels kept one vocabulary with the archive's and followed by
/// its tags, and what that changed of what the model gave. Without a valid answer, `outcome.labels` is nil and `tags`
/// are still what the document keeps.
public struct Reading: Sendable, Codable {
    public var outcome: AnalysisOutcome
    /// The document's tags, as the user's rules write them.
    public var tags: [DocumentLabel]
    public var changes: [LabelChange]
}

/// What the history keeps of a reading: how the document was read, which of the model's labels became others, and what
/// gave each of its tags.
public struct AnalysedPayload: Sendable, Codable, Hashable {
    public var analysis: DocumentAnalysis
    public var changes: [LabelChange]
    /// Absent for a document without tags, as in every reading recorded before there were any.
    public var tags: [GivenTag]?
}
