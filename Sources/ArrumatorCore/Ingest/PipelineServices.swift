import Foundation
import GRDB

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
    /// Which jobs the workers of this process hold, so that no job is worked on twice at once (`JobStore.nextDue`).
    public var claims: JobClaims
    /// The Mac's power as it is now (`PowerState.current`), which may keep the worker waiting (`PowerState.pauseReason`).
    public var power: @Sendable () -> PowerState
    /// The Ollama server, asked whether it answers at all when a request to it timed out.
    public var ollama: any OllamaAPI
    /// The Mac's time zone, which today is in when a request or a question is read.
    public var timeZone: TimeZone
    /// Which labels looked alike when last worked out, shared by every `LabelStore` this makes (`labels`).
    public let lookAlikes = LookAlikeMemo()

    public init(database: AppDatabase, archive: URL, config: PipelineConfig, settings: SettingsStore, extractor: any ContentExtracting,
                analyzer: any DocumentAnalyzing, filer: DocumentFiler, traces: TraceRecorder, vectors: VectorIndex,
                trash: any Trashing, time: any TimeSource, ollama: any OllamaAPI, timeZone: TimeZone, claims: JobClaims,
                power: @escaping @Sendable () -> PowerState) {
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
        self.claims = claims
        self.power = power
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
        if !added.isEmpty { try await index.addLabels(added, docID: docID) }
        return given.filter { !$0.isNew } + ruled.tags
    }

    /// Reads a document with the model, telling it of the archive's labels and the user's decisions about them, and
    /// keeps its labels one vocabulary with the archive's (`LabelConsolidator`), recording what that changed in the
    /// trace. The document's `tags`, the user's own, follow the user's rules alone and come after the model's labels.
    /// The file name is made of the labels kept, as the user's rules merged, aligned or dropped them, and the model's
    /// title (`FilenameBuilder.made`), never of what the model wrote before them. Nothing is saved: dry runs and replays
    /// read this way too.
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
        outcome.analysis.fileName = outcome.title.flatMap {
            FilenameBuilder(config: config.naming, reserved: SkipRules(watcher: config.watcher))
                .made(date: consolidation.labels.values(.date).first, sender: consolidation.labels.values(.sender).first, title: $0)
        }
        return Reading(outcome: outcome, tags: kept, changes: consolidation.changes)
    }

    /// Queues document `docID` to be read again from the start, as the user asks it (**Read Again**), as a file that
    /// arrives is read: its file hashed and its text read again, then the model reads it, and it is filed under the name
    /// it gives: where it is in the archive, or, for one outside it (back in Incoming), at the top of the archive. One in
    /// the archive (`reanalyse`) is found as it was until it is filed, when what it reads takes the place of everything it
    /// had at once (`IndexStore.replaceReading`).
    /// It keeps its tags, which its row in the queue shows, and one in a folder in Incoming is given that folder's too.
    /// One outside the archive, as one left in Incoming, is read as an arrival, so an exact copy is handed over to its
    /// original (`IngestCoordinator`). One with no file to read where it is recorded, as one missing, or a copy an earlier
    /// version filed, is refused before anything changes (`IngestError.cannotReadAgain`). All of it is decided on the
    /// document as the write that queues it finds it, and recorded in History in that write, once: a request that queues
    /// nothing new, as one asked again while the first waits, records nothing. The job, or the one already queued for its
    /// file, which reads it as well.
    @discardableResult
    public func queueReadingAgain(_ docID: Int64, settings: AppSettings) async throws -> Int64 {
        let now = time.now()
        // Its status, its job and its event written together, so a file arriving at its path meanwhile, or the document
        // filed or ended, finds all of them, or none.
        return try await database.writer.write { [self] db in
            guard let read = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
            let inArchive = isInArchive(read)
            let readable: Set<DocumentStatus> = inArchive ? [.filed, .needsReview, .failed, .held, .processing]
                : [.undone, .held, .failed, .arrived, .processing]
            guard readable.contains(read.status), FileManager.default.fileExists(atPath: read.path) else {
                throw IngestError.cannotReadAgain(docID)
            }
            var doc = read
            if !inArchive || [.undone, .held].contains(read.status) {
                doc.status = .processing
                doc.updatedAt = now
                try doc.updateChanges(db, from: read)
            }
            let folderTags = inArchive ? [] : tags(for: read.url, given: [], settings: settings)
            let queued = try JobStore.enqueue(db, path: read.path, kind: inArchive ? .reanalyse : .ingest, docID: docID,
                                              payload: Self.readingAgain(tags: Self.keptTags(read.labels) + folderTags, asked: inArchive ? doc : nil),
                                              givesWay: false, at: now)
            if queued.isNew { try HistoryStore.insert(db, .retry, at: now, actor: .user, doc: docID, summary: "Read again: \(read.filename)") }
            return queued.id
        }
    }

    /// Whether document `docID` is still the original an exact copy is handed over to (`takesCopy`).
    public func takesCopy(of docID: Int64) async throws -> Bool {
        try await database.reader.read { db in try DocumentRecord.fetchOne(db, key: docID) }.map(takesCopy) ?? false
    }

    /// Whether `document` is the original an exact copy is handed over to: in the archive as itself, read again or not,
    /// its file there, as `queueReadingAgain` reads one in the archive; not one undone, or gone from the archive.
    func takesCopy(_ document: DocumentRecord) -> Bool {
        DocumentStatus.takesCopies.contains(document.status) && isInArchive(document)
            && FileManager.default.fileExists(atPath: document.path)
    }

    /// Queues document `docID`, the original an exact copy came of, to be read again in its place, as `queueReadingAgain`
    /// queues a document in the archive, in the write that finds it there still as itself, its file in the archive: one
    /// undone, or gone from the archive, since the copy was handed over to it is not read again for it
    /// (`IngestCoordinator.handOver`). Whether it was queued.
    public func queueReadingAgain(forCopyOf docID: Int64) async throws -> Bool {
        let now = time.now()
        return try await database.writer.write { [self] db in
            guard let read = try DocumentRecord.fetchOne(db, key: docID), takesCopy(read) else { return false }
            var doc = read
            if doc.status == .held {
                doc.status = .processing
                doc.updatedAt = now
                try doc.updateChanges(db, from: read)
            }
            _ = try JobStore.enqueue(db, path: doc.path, kind: .reanalyse, docID: docID,
                                     payload: Self.readingAgain(tags: Self.keptTags(doc.labels), asked: doc), givesWay: false, at: now)
            return true
        }
    }

    /// Queues every document of the archive that waits for nothing the user decided to be read again from the start, as
    /// `queueReadingAgain` reads one in the archive: filed, waiting for the user or set aside after failing, but not
    /// one left for later, nor one undone, missing or a copy. Each gives way to every file that arrives
    /// (`JobRecord.givesWay`), and to the user's own request to read one again. One already queued to be read is read
    /// once (`JobStore.enqueue`). Decided, queued and recorded once in History, under no document, in one transaction.
    /// The documents queued now, in the order they were added; none, and nothing recorded, when every document is
    /// queued already, or the archive has none.
    public func queueReadingAllAgain(settings: AppSettings) async throws -> [Int64] {
        let profile = try settings.modelProfile()
        let (archive, now) = (archive, time.now())
        return try await database.writer.write { db in
            let statuses = [DocumentStatus.filed, .needsReview, .failed].map(\.rawValue)
            // What queueing needs of each, not its stored text and what it was read from.
            let documents = try Row.fetchAll(db, DocumentRecord.filter(statuses.contains(Column("status")))
                .select(Column("id"), Column("path"), Column("labels_json")).order(Column("id")))
                .filter { archive.holds($0["path"]) }
            let ids = try documents.compactMap { row -> Int64? in
                let (id, path): (Int64, String) = (row["id"], row["path"])
                let labels = JSON.decode([DocumentLabel].self, from: row["labels_json"] as String?)
                var payload = Self.readingAgain(tags: Self.keptTags(labels), asked: nil)
                payload.rereading = Rereading(before: labels ?? [], path: path, changes: [], tags: nil)
                return try JobStore.enqueue(db, path: path, kind: .reanalyse, docID: id, payload: payload, givesWay: true, at: now).isNew ? id : nil
            }
            guard !ids.isEmpty else { return [] }
            try HistoryStore.insert(db, .retry, at: now, actor: .user,
                                    summary: "Read every document again with the profile “\(profile.name)”: " + Format.count(ids.count, "document"),
                                    payload: ReadingAllAgainPayload(profile: settings.profile, documents: ids))
            return ids
        }
    }

    /// The tags a document with `labels` keeps when it is read again, as its row in the queue shows them.
    private static func keptTags(_ labels: [DocumentLabel]?) -> [GivenTag] {
        (labels ?? []).filter(\.kind.isUsersOwn).map { GivenTag(label: $0, source: .document) }
    }

    /// What a job reading a document again is queued with, as it starts at hashing: the tags it keeps or is given, and,
    /// for one of the archive, `asked`, its labels and place as they are when it is asked for (`Rereading`).
    private static func readingAgain(tags: [GivenTag], asked: DocumentRecord?) -> JobPayload {
        var payload = JobPayload()
        payload.tags = tags.isEmpty ? nil : tags
        payload.rereading = asked.map { Rereading(before: $0.labels ?? [], path: $0.path, changes: [], tags: nil) }
        return payload
    }

    /// Asks the model about a document and keeps what it says: the labels on the document and in the search index
    /// straight away, with the tags it has, and a history event with what it was labelled with, or why it was not, and
    /// what gave its tags (`given`, the tags its job was queued with). A document the model gives no valid answer keeps
    /// the labels it had: its tags, or what an earlier reading gave it.
    public func analyse(docID: Int64, jobID: Int64?, content: ExtractedContent, given: [GivenTag], settings: AppSettings,
                        trace: TraceContext) async throws -> AnalysisOutcome {
        let (read, rereading) = try await reading(docID: docID, content: content, given: given, settings: settings, trace: trace)
        var outcome = read
        if let labels = outcome.labels {
            // Where the user changed nothing since the reading began: what the user did meanwhile is kept.
            outcome.labels = try await index.saveReading(labels, before: rereading.before, docID: docID)
        }
        let event = Self.readingEvent(read, rereading: rereading)
        try await history.record(event.kind, doc: docID, job: jobID, trace: trace.traceID, summary: event.summary, payload: event.payload)
        return outcome
    }

    /// Reads a document already read once again with the model, as `analyse` does, and saves nothing: what it reads takes
    /// the place of everything the document has once it is filed (`replaceReading`), but what the user changed since it
    /// was asked for, as `asked` says it was then; the job keeps what that needs until then (`Rereading`).
    public func reread(docID: Int64, content: ExtractedContent, given: [GivenTag], asked: Rereading, settings: AppSettings,
                       trace: TraceContext) async throws -> (outcome: AnalysisOutcome, rereading: Rereading) {
        let read = try await reading(docID: docID, content: content, given: given, settings: settings, trace: trace)
        return (read.outcome, Rereading(before: asked.before, path: asked.path, changes: read.rereading.changes, tags: read.rereading.tags))
    }

    /// Reads a document with the model (`read`), with the tags it has as the reading begins, and says in its trace why it
    /// waits for the user, when it does; with the labels it had then and where it was, a kind or a name the user changes
    /// meanwhile staying as the user left it, and what gave each of its tags (`given`, the tags its job was queued with).
    private func reading(docID: Int64, content: ExtractedContent, given: [GivenTag], settings: AppSettings,
                         trace: TraceContext) async throws -> (outcome: AnalysisOutcome, rereading: Rereading) {
        guard let document = try await documents.document(id: docID) else { throw IngestError.documentNotFound(docID) }
        let before = document.labels ?? []
        let reading = try await read(content, tags: before.filter(\.kind.isUsersOwn), settings: settings, trace: trace)
        let problems = reading.outcome.analysis.problems
        if !problems.isEmpty {
            // Why it waits for the user, which the steps before it, each done as it should be, do not say.
            await trace.record(.review, status: .warn, startedAt: Date(), durationMs: 0, output: ["problems": problems],
                               error: "Waits for you: " + DocumentAnalysis.said(problems))
        }
        let sources = GivenTag.sources(of: reading.tags, given: given)
        return (reading.outcome, Rereading(before: before, path: document.path, changes: reading.changes, tags: sources.isEmpty ? nil : sources))
    }

    /// Puts what reading document `docID` again gave it, `outcome`, in the place of everything it had, in the transaction
    /// of `db` that records its filing under `filename` (`IndexStore.replaceReading`), with its text, `content`, and its
    /// meaning, and records the reading in History there too, before the filing. The labels saved.
    @discardableResult
    func replaceReading(_ db: Database, docID: Int64, filename: String, content: ExtractedContent, outcome: AnalysisOutcome,
                        rereading: Rereading, jobID: Int64?, traceID: Int64?, at now: Date) throws -> [DocumentLabel] {
        let embedding = outcome.embedding.flatMap { vector in
            outcome.embeddingModel.map {
                TextEmbedding(model: $0, vector: vector, sourceText: embeddingText(content, senders: outcome.labels?.values(.sender) ?? []))
            }
        }
        let labels = try IndexStore.replaceReading(db, docID: docID, filename: filename, content: content, read: outcome.labels,
                                                   before: rereading.before, embedding: embedding, at: now)
        let event = Self.readingEvent(outcome, rereading: rereading)
        try HistoryStore.insert(db, event.kind, at: now, doc: docID, job: jobID, trace: traceID, summary: event.summary, payload: event.payload)
        return labels
    }

    /// The text a document's embedding is made of, as its job keeps it with the embedding (`IndexStore.upsertEmbedding`).
    func embeddingText(_ content: ExtractedContent, senders: [String]) -> String {
        content.embeddingSummary(senders: senders, maxChars: config.analysis.embeddingSummaryChars,
                                 identifiersLimit: config.analysis.embeddingIdentifiersLimit)
    }
}

extension PipelineServices {
    /// What History records of a reading, `outcome`: what it was labelled with, or why it was not, and what gave its tags.
    struct ReadingEvent {
        var kind: EventKind
        var summary: String
        var payload: any Encodable & Sendable
    }

    /// What History records of a reading, `outcome`, its labels as the model gave them: the model's labels, or, without
    /// them, why it was not read; and what gave each of its tags (`Rereading.tags`).
    static func readingEvent(_ outcome: AnalysisOutcome, rereading: Rereading) -> ReadingEvent {
        let note = GivenTag.note(rereading.tags ?? []).map { "; " + $0 } ?? ""
        let problems = outcome.analysis.problems
        guard let labels = outcome.labels else {
            return ReadingEvent(kind: .error, summary: "Not read: " + DocumentAnalysis.said(problems) + note, payload: outcome.analysis)
        }
        return ReadingEvent(kind: .analysed, summary: readingSummary(labels.filter { !$0.kind.isUsersOwn }, problems: problems) + note,
                            payload: AnalysedPayload(analysis: outcome.analysis, changes: rereading.changes, tags: rereading.tags))
    }

    /// What History says of a reading that gave the model's labels `read`: their values, or that it found nothing worth a
    /// label; and, when the document waits for the user, why. One that waits with nothing read, as a damaged file, a blank
    /// scan or a kind of file no extractor reads, is never said to have had nothing worth a label: nothing of it could be
    /// read.
    static func readingSummary(_ read: [DocumentLabel], problems: [String]) -> String {
        let waits = problems.isEmpty ? nil : "waits for you: " + DocumentAnalysis.said(problems)
        let labels = read.isEmpty ? (waits == nil ? "Nothing worth a label" : "Nothing could be read of it")
            : read.map(\.value).joined(separator: " · ")
        return ([labels] + [waits].compactMap { $0 }).joined(separator: "; ")
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

/// What History keeps of the user's reading every document of the archive again (`PipelineServices.queueReadingAllAgain`):
/// the profile they are read with, by its id, and the documents queued.
public struct ReadingAllAgainPayload: Sendable, Codable, Hashable {
    public var profile: String
    public var documents: [Int64]

    public init(profile: String, documents: [Int64]) {
        self.profile = profile
        self.documents = documents
    }
}

/// What the history keeps of a reading: how the document was read, which of the model's labels became others, and what
/// gave each of its tags.
public struct AnalysedPayload: Sendable, Codable, Hashable {
    public var analysis: DocumentAnalysis
    public var changes: [LabelChange]
    /// Absent for a document without tags, as in every reading recorded before there were any.
    public var tags: [GivenTag]?
}
