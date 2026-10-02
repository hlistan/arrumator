import Foundation
import GRDB
import UniformTypeIdentifiers

/// Runs ingest jobs one at a time through hashing → extracting → analysing → filing, in the order they were queued
/// (`JobStore.nextDue`). Every transition is persisted, so a job stopped part way, by quitting, a crash or a forced
/// quit, keeps its stage and its place, and carries on from its last finished stage first at the next start.
public actor IngestCoordinator {
    private let services: PipelineServices
    private var worker: Task<Void, Never>?
    private let kick: AsyncStream<Void>.Continuation
    private let kicks: AsyncStream<Void>
    private var statusContinuations: [UUID: AsyncStream<IngestStatus>.Continuation] = [:]
    public private(set) var status = IngestStatus.idle {
        didSet { if status != oldValue { for c in statusContinuations.values { c.yield(status) } } }
    }

    /// Floor for loop sleeps so a job due "now" does not spin.
    static let minimumWait = 0.2

    public init(services: PipelineServices) {
        self.services = services
        (kicks, kick) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func statusUpdates() -> AsyncStream<IngestStatus> {
        let id = UUID()
        let (stream, c) = AsyncStream<IngestStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(status)
        statusContinuations[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.removeStatus(id) } }
        return stream
    }

    private func removeStatus(_ id: UUID) { statusContinuations[id] = nil }

    // MARK: Control

    /// Starts the worker. A job stopped part way needs nothing done to it: it is due, and was queued before anything
    /// that arrived after it, so the worker takes it up first.
    public func start() async {
        guard worker == nil else { return }
        await logResumingJobs()
        worker = Task { [weak self] in await self?.runLoop() }
        kick.yield()
    }

    /// Stops the worker and waits until it has, so no job is still running once this returns. A job in hand is
    /// interrupted, which is no failure: nothing more is saved of it, so it keeps the stage it is at, with what its
    /// finished stages saved, and carries on from there the next time the worker starts, before the jobs queued after
    /// it. Filing that has begun is finished first (`DocumentFiler.file`), so a stop never leaves a file moved without
    /// its record.
    public func stop() async {
        guard let worker else { return }
        worker.cancel()
        await worker.value
        self.worker = nil
    }

    public func wake() { kick.yield() }

    /// Called by the Incoming watcher for each stable file, and by `arrumatorcli ingest`, which may give it `tags` of
    /// its own. The tags the file is given are decided now, from where it is in Incoming (`PipelineServices.tags`), and
    /// kept with its job.
    @discardableResult
    public func enqueue(_ url: URL, tags: [String] = []) async -> Int64? {
        let path = url.standardizedFileURL.path
        do {
            if let known = try await services.documents.document(path: path),
               [.held, .undone].contains(known.status) {
                Log.debug(.ingest, "Ignoring held document", ["path": path, "doc": String(known.id ?? 0)])
                return nil
            }
            var payload = JobPayload()
            let given = services.tags(for: url, given: tags, settings: await services.settings.current)
            payload.tags = given.isEmpty ? nil : given
            let id = try await services.jobs.enqueue(path: path, kind: .ingest, payload: payload)
            let summary = ([url.lastPathComponent] + [GivenTag.note(given)].compactMap { $0 }).joined(separator: " · ")
            try await services.history.record(.arrived, job: id, summary: summary, payload: ArrivedPayload(path: path, tags: payload.tags))
            Log.info(.ingest, "Queued", ["path": path, "job": id.map(String.init) ?? "-", "tags": given.map(\.label.value).joined(separator: ", ")])
            await refreshQueueCount()
            kick.yield()
            return id
        } catch {
            Log.error(.ingest, "Could not queue file", ["path": path, "error": error.localizedDescription])
            return nil
        }
    }

    /// Processes due jobs until none are left (CLI and tests).
    public func drain() async {
        while let job = await nextDue() {
            await process(job)
        }
        await refreshQueueCount()
    }

    /// The next job due now; a job queue that cannot be read is logged, and waited out like an empty one.
    private func nextDue() async -> JobRecord? {
        do { return try await services.jobs.nextDue() } catch {
            Log.error(.ingest, "Could not read the job queue", ["error": error.localizedDescription])
            return nil
        }
    }

    // MARK: Loop

    private func runLoop() async {
        while !Task.isCancelled {
            let settings = await services.settings.current
            let powerReason = PowerState.current().pauseReason(settings: settings, config: services.config.power)
            status.powerPauseReason = powerReason
            if !settings.paused, powerReason == nil, FileManager.default.fileExists(atPath: settings.archiveURL.path) {
                if let job = await nextDue() {
                    await process(job)
                    continue
                }
            }
            await refreshQueueCount()
            var wait = await earliestDue().map { $0.timeIntervalSince(services.time.now()) }
            if powerReason != nil { wait = services.config.power.recheckSeconds }
            await waitForKick(timeout: wait.map { max(Self.minimumWait, $0) })
        }
    }

    /// When the next active job is due; a queue that cannot be read waits for the next kick.
    private func earliestDue() async -> Date? {
        do { return try await services.jobs.earliestDue() } catch {
            Log.error(.ingest, "Could not read the job queue", ["error": error.localizedDescription])
            return nil
        }
    }

    private func waitForKick(timeout: Double?) async {
        let kicks = kicks
        let time = services.time
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var it = kicks.makeAsyncIterator()
                _ = await it.next()
            }
            if let timeout {
                // Woken early by cancellation, the loop checks it and ends.
                group.addTask { try? await time.sleep(seconds: timeout) }
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func refreshQueueCount() async {
        let active: [JobRecord]
        do { active = try await services.jobs.active() } catch {
            Log.error(.ingest, "Could not count the job queue", ["error": error.localizedDescription])
            return
        }
        status.queued = active.filter { $0.kind != .reindex }.count
        status.reindexing = active.filter { $0.kind == .reindex }.count
    }

    /// Logs the jobs that carry on from a stage begun before the worker last stopped: what quitting, a crash or a failure
    /// that waits to be tried again left part way. They are taken in their turn, by when they were queued.
    private func logResumingJobs() async {
        do {
            for job in try await services.jobs.active() where job.state != .pending {
                Log.info(.ingest, "Carries on where it stopped", ["job": String(job.id ?? 0), "stage": job.state.rawValue,
                                                                  "attempt": String(job.attempt)])
            }
        } catch {
            Log.error(.ingest, "Could not read the job queue", ["error": error.localizedDescription])
        }
    }

    // MARK: Job processing

    private func process(_ initial: JobRecord) async {
        var job = initial
        let settings = await services.settings.current
        status.current = job.id.map { IngestStatus.Current(job: $0, path: job.sourcePath, stage: job.state, tags: job.tags) }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Filing \(URL(fileURLWithPath: job.sourcePath).lastPathComponent)")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            status.current = nil
        }
        let trace: TraceContext
        do {
            trace = try await services.startTrace(docID: job.docId, jobID: job.id, attempt: job.attempt, source: .ingest,
                                                  settings: settings)
        } catch {
            Log.error(.db, "Could not start trace", ["error": error.localizedDescription])
            trace = .disabled
        }
        var payload = job.payload
        payload.traceID = trace.traceID
        do {
            try await runStages(&job, payload: &payload, settings: settings, trace: trace)
            status.waitingForOllama = false
            // A copy is no document: its trace is reached from its event in its original's History (`handOver`).
            await services.traces.finish(trace, outcome: job.state.rawValue, docID: job.docId)
        } catch {
            await handleFailure(&job, payload: payload, error: error, trace: trace)
        }
        // A stopped worker reads nothing more: the database cancels a stopped task's reads, which is no error to log.
        if !Task.isCancelled { await refreshQueueCount() }
    }

    private func save(_ job: inout JobRecord, _ payload: JobPayload, state: JobState) async throws {
        job.state = state
        job.setPayload(payload)
        try await services.jobs.update(job)
        status.current?.stage = state
        status.current?.tags = job.tags
    }

    private func runStages(_ job: inout JobRecord, payload: inout JobPayload, settings: AppSettings,
                           trace: TraceContext) async throws {
        if job.kind == .reindex {
            try await reindex(&job, payload: payload, settings: settings, trace: trace)
            return
        }
        let source = URL(fileURLWithPath: job.sourcePath)
        // A document read again comes with what earlier stages found of it, and starts at the first stage it lacks: its
        // text is extracted again only when none was kept.
        if job.state == .pending, let docID = job.docId, payload.sha256 != nil {
            if let given = payload.tags { payload.tags = try await services.giveTags(given, docID: docID, trace: trace) }
            try await save(&job, payload, state: payload.content == nil ? .extracting : .analysing)
        }
        if job.state == .pending || job.state == .hashing {
            try await save(&job, payload, state: .hashing)
            guard FileManager.default.fileExists(atPath: source.path) else {
                // A copy that went to the Trash before a stop: what is left of handing it over is done now.
                if let id = payload.copyOf, let original = try await services.documents.document(id: id) {
                    try await handOver(source, to: original, job: &job, payload: &payload, settings: settings, trace: trace)
                    return
                }
                try await save(&job, payload, state: .cancelled)
                try await services.history.record(.missing, doc: job.docId, job: job.id, trace: trace.traceID,
                                                  summary: "\(source.lastPathComponent) disappeared before processing")
                return
            }
            let (fingerprint, sha) = try await trace.measure(.hash, input: ["path": source.path],
                                                             output: { (r: (FileFingerprint, String)) in ["sha256": r.1, "size": String(r.0.size)] }) {
                (try FileFingerprint.of(source), try HashService.sha256(of: source))
            }
            payload.sha256 = sha
            payload.size = fingerprint.size
            payload.mtime = fingerprint.modified
            payload.inode = fingerprint.inode
            if let original = try await original(of: source, sha256: sha, job: job, trace: trace) {
                try await handOver(source, to: original, job: &job, payload: &payload, settings: settings, trace: trace)
                return
            }
            let document = try await ensureDocument(for: job, source: source, sha: sha, fingerprint: fingerprint)
            job.docId = document.id
            // The tags are the document's from when it is one, read or not.
            if let docID = document.id, let given = payload.tags {
                payload.tags = try await services.giveTags(given, docID: docID, trace: trace)
            }
            try await save(&job, payload, state: .extracting)
        }
        guard let docID = job.docId, let sha = payload.sha256 else { throw IngestError.documentNotPersisted }

        if job.state == .extracting {
            let context = try services.config.extractionContext(settings: settings)
            let content = try await services.extractor.extract(source, sha256: sha, context: context, trace: trace)
            payload.content = content
            try await storeExtraction(docID: docID, content: content)
            try await services.history.record(.extracted, doc: docID, job: job.id, trace: trace.traceID,
                                              summary: "\(content.kind.rawValue), \(content.text.count) chars, \(content.language.primary)",
                                              payload: ["warnings": content.warnings.map(\.code.rawValue).joined(separator: ",")])
            try await save(&job, payload, state: .analysing)
        }
        guard let content = payload.content else { throw IngestError.contentUnavailable(docID) }

        if job.state == .analysing {
            payload.outcome = try await services.analyse(docID: docID, jobID: job.id, content: content, given: payload.tags ?? [],
                                                         settings: settings, trace: trace)
            try await save(&job, payload, state: .filing)
        }
        guard let outcome = payload.outcome else { throw IngestError.invalidState("analysis missing") }

        if job.state == .filing {
            try await fileDocument(&job, payload: &payload, docID: docID, content: content, outcome: outcome,
                                   settings: settings, trace: trace)
        }
    }

    private func ensureDocument(for job: JobRecord, source: URL, sha: String, fingerprint: FileFingerprint) async throws -> DocumentRecord {
        if let id = job.docId, let existing = try await services.documents.document(id: id) { return existing }
        // A type the file system cannot tell is plain data, as UTType calls it.
        let uttype = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier) ?? UTType.data.identifier
        let record = DocumentRecord.arrived(path: source.path, sha256: sha, size: fingerprint.size, uttype: uttype,
                                            inode: fingerprint.inode, modified: fingerprint.modified, now: services.time.now())
        return try await services.documents.save(record)
    }

    /// Reads a filed document's text and computes its embedding again, asking the model nothing and moving nothing:
    /// what a document needs for search after the index was rebuilt from the archive. Its labels come from its record.
    private func reindex(_ job: inout JobRecord, payload: JobPayload, settings: AppSettings, trace: TraceContext) async throws {
        guard let docID = job.docId, let document = try await services.documents.document(id: docID),
              FileManager.default.fileExists(atPath: document.path) else {
            try await save(&job, payload, state: .cancelled)
            return
        }
        try await save(&job, payload, state: .extracting)
        let context = try services.config.extractionContext(settings: settings)
        let content = try await services.extractor.extract(document.url, sha256: document.sha256, context: context, trace: trace)
        try await storeExtraction(docID: docID, content: content)
        let senders = document.labels(.sender)
        if let (vector, model) = try await services.analyzer.embedding(for: content, senders: senders, settings: settings,
                                                                        config: services.config, trace: trace) {
            try await index(docID: docID, content: content, senders: senders, vector: vector, model: model, trace: trace)
        }
        try await save(&job, payload, state: .done)
    }

    private func index(docID: Int64, content: ExtractedContent, senders: [String], vector: [Float], model: String,
                       trace: TraceContext) async throws {
        let text = content.embeddingSummary(senders: senders, maxChars: services.config.analysis.embeddingSummaryChars,
                                            identifiersLimit: services.config.analysis.embeddingIdentifiersLimit)
        try await trace.measure(.index, input: ["model": model]) {
            try await services.index.upsertEmbedding(docID: docID, model: model, vector: vector, sourceText: text)
            await services.vectors.upsert(docID: docID, vector: vector, model: model)
        }
    }

    private func storeExtraction(docID: Int64, content: ExtractedContent) async throws {
        guard var doc = try await services.documents.document(id: docID) else { throw IngestError.documentNotFound(docID) }
        doc.pageCount = content.pageCount
        doc.extractedAt = services.time.now()
        doc.contentJson = DocumentStore.storedContentJSON(content)
        _ = try await services.documents.save(doc)
        try await services.index.upsertText(docID: docID, filename: doc.filename, body: content.text, summary: content.visual?.description,
                                            metadata: content.metadata,
                                            extractorVersion: "\(content.extractorName)/\(content.extractorVersion)",
                                            labels: doc.labels ?? [])
    }

    /// Files the document under the name the model gave it: a new arrival at the top of the archive, a document read
    /// again where it is, one the user put in the archive left as it is. A document the model could not read waits
    /// for the user there.
    ///
    /// The job's destination is recorded in the transaction that records the filing, so a job that stopped after it,
    /// on an error or a crash, finds it filed and finishes what is left instead of filing it again.
    private func fileDocument(_ job: inout JobRecord, payload: inout JobPayload, docID: Int64, content: ExtractedContent,
                              outcome: AnalysisOutcome, settings: AppSettings, trace: TraceContext) async throws {
        guard let document = try await services.documents.document(id: docID) else { throw IngestError.documentNotFound(docID) }
        let analysis = outcome.analysis
        let status: DocumentStatus = analysis.problems.isEmpty ? .filed : .needsReview
        let filedRecord: DocumentRecord
        if let target = payload.targetPath, document.path == target, FileManager.default.fileExists(atPath: target) {
            Log.info(.ingest, "Filing already completed before the job stopped", ["doc": String(docID)])
            filedRecord = document
        } else {
            guard FileManager.default.fileExists(atPath: document.path) else { throw IngestError.sourceMissing(document.path) }
            let directory = job.kind == .ingest ? services.layout(settings).root : document.url.deletingLastPathComponent()
            let (unfiledJob, unfiledPayload, now) = (job, payload, services.time.now())
            filedRecord = try await services.filer.file(
                document, source: content.source, analysis: analysis, status: status, directory: directory,
                inPlace: job.kind == .adopt, actor: .system, settings: settings, trace: trace, event: nil,
                recording: { db, filed in
                    var filedPayload = unfiledPayload
                    filedPayload.targetPath = filed.path
                    var filedJob = unfiledJob
                    filedJob.setPayload(filedPayload)
                    filedJob.updatedAt = now
                    try filedJob.update(db)
                })
        }
        payload.targetPath = filedRecord.path
        if var doc = try await services.documents.document(id: docID) {
            doc.lastTraceId = trace.traceID
            _ = try await services.documents.save(doc)
        }
        if let embedding = outcome.embedding, let model = outcome.embeddingModel {
            try await index(docID: docID, content: content, senders: outcome.labels?.values(.sender) ?? [], vector: embedding,
                            model: model, trace: trace)
        }
        try await save(&job, payload, state: status == .needsReview ? .needsReview : .done)
        Log.info(.ingest, status == .needsReview ? "Filed; waiting for the user" : "Filed", ["doc": String(docID), "path": filedRecord.path])
    }

    // MARK: Failures

    private func handleFailure(_ job: inout JobRecord, payload: JobPayload, error: any Error, trace: TraceContext) async {
        // Stopping interrupts the job; that is no failure. Its saved stage lets it resume where it stopped.
        guard !Task.isCancelled else {
            Log.info(.ingest, "Job interrupted by stopping", ["job": String(job.id ?? 0), "stage": job.state.rawValue])
            return
        }
        let message = error.localizedDescription
        let config = services.config.ingest
        let ollamaDown = (error as? OllamaError).map { $0.isTransient } ?? false
        job.lastError = message
        job.setPayload(payload)
        if case OllamaError.modelNotFound = error {
            job.state = .held
            await keep(job, event: .error, summary: "Model missing: \(message)", trace: trace)
            await services.traces.finish(trace, outcome: "held", docID: job.docId)
            Log.error(.ingest, "Model missing; job held", ["job": String(job.id ?? 0), "error": message])
            return
        }
        if ollamaDown {
            status.waitingForOllama = true
            job.nextRunAt = services.time.now().addingTimeInterval(config.retryDelays.last)
            await keep(job, event: .retry, summary: "Waiting for Ollama: \(message)", trace: trace)
            await services.traces.finish(trace, outcome: "waiting", docID: job.docId)
            Log.warning(.ingest, "Ollama unavailable; will retry", ["job": String(job.id ?? 0), "error": message])
            return
        }
        job.attempt += 1
        if job.attempt < config.maxAttempts {
            job.nextRunAt = services.time.now().addingTimeInterval(config.retryDelays.clamped(job.attempt - 1))
            await keep(job, event: .retry, summary: "Attempt \(job.attempt) failed: \(message)", trace: trace)
            await services.traces.finish(trace, outcome: "retry", docID: job.docId)
            Log.warning(.ingest, "Stage failed; retrying", ["job": String(job.id ?? 0), "stage": job.state.rawValue,
                                                            "attempt": String(job.attempt), "error": message])
            return
        }
        job.state = .failed
        await keep(job, event: nil, summary: message, trace: trace)
        await parkFailedDocument(job: job, message: message, trace: trace)
        await services.traces.finish(trace, outcome: "failed", docID: job.docId)
        Log.error(.ingest, "Job failed", ["job": String(job.id ?? 0), "error": message])
    }

    /// Saves what a failure did to a job and records it in the history. Both are already the failure path, so neither
    /// throws: what cannot be saved is logged, and the job, unchanged in the queue, is taken again in its turn.
    private func keep(_ job: JobRecord, event: EventKind?, summary: String, trace: TraceContext) async {
        do { try await services.jobs.update(job) } catch {
            Log.error(.ingest, "Could not save a failed job", ["job": String(job.id ?? 0), "error": error.localizedDescription])
        }
        guard let event else { return }
        do {
            try await services.history.record(event, doc: job.docId, job: job.id, trace: trace.traceID, summary: summary)
        } catch {
            Log.error(.ingest, "Could not record a failure in the history", ["job": String(job.id ?? 0), "event": event.rawValue,
                                                                             "error": error.localizedDescription])
        }
    }

    /// Moves a new file that could not be processed into the archive, where it waits for the user, so Incoming stays
    /// clean and nothing is lost; a document already in the archive stays where it is.
    private func parkFailedDocument(job: JobRecord, message: String, trace: TraceContext) async {
        do {
            let settings = await services.settings.current
            guard let docID = job.docId, let document = try await services.documents.document(id: docID) else {
                try await services.history.record(.failed, job: job.id, trace: trace.traceID, summary: message)
                return
            }
            let analysis = DocumentAnalysis(problems: ["Processing failed: \(message)"])
            if FileManager.default.fileExists(atPath: document.path), job.kind == .ingest {
                _ = try await services.filer.file(document, source: document.unreadSource, analysis: analysis, status: .failed,
                                                  directory: services.layout(settings).root, inPlace: false, actor: .system,
                                                  settings: settings, trace: trace, event: .failed, recording: nil)
            } else {
                var failed = document
                failed.status = .failed
                failed.analysisJson = JSON.string(analysis)
                _ = try await services.documents.save(failed)
                try await services.history.record(.failed, doc: docID, job: job.id, trace: trace.traceID,
                                                  summary: "\(document.originalFilename): \(message)")
            }
        } catch {
            Log.error(.ingest, "Could not park failed document", ["job": String(job.id ?? 0), "error": error.localizedDescription])
        }
    }
}

// MARK: Exact copies

extension IngestCoordinator {
    /// The document in the archive the file at `source` is an exact copy of: the oldest with its SHA-256
    /// (`DocumentStore.existing`) whose file, another than `source`, still has it, as the trace's `dedupe` step records;
    /// nil when there is none, and for a file the user put into the archive (`adopt`), which is a document of its own.
    /// Its file is hashed again, as it may have been changed since it was filed: a file the archive no longer holds the
    /// same bytes of is no copy.
    private func original(of source: URL, sha256: String, job: JobRecord, trace: TraceContext) async throws -> DocumentRecord? {
        guard job.kind != .adopt else { return nil }
        let documents = services.documents
        return try await trace.measure(.dedupe, input: ["sha256": sha256],
                                       output: { (d: DocumentRecord?) in ["copyOf": d?.id.map(String.init) ?? "none"] }) {
            guard let found = try await documents.existing(sha256: sha256, excluding: job.docId),
                  found.url.resolvingSymlinksInPath() != source.resolvingSymlinksInPath(),
                  FileManager.default.fileExists(atPath: found.path), try HashService.sha256(of: found.url) == sha256 else { return nil }
            return found
        }
    }

    /// Hands a file that is an exact copy of `original` over to it, rather than making a second document of the same
    /// bytes: the original is given the tags the file was queued with (`PipelineServices.giveTags`), the file goes to
    /// the Trash, never deleted, and the original is read again from the start, as the file would have been
    /// (`PipelineServices.queueReadingAgain`), so a copy put into Incoming reads its document again with the profile in
    /// use. History records this once, under the original. The original is kept with the job first, so a stop part way
    /// finishes the rest at the next start, the copy in the Trash already or not; a copy the Trash refuses fails the
    /// job before its original is read, and stays where it is.
    private func handOver(_ copy: URL, to original: DocumentRecord, job: inout JobRecord, payload: inout JobPayload,
                          settings: AppSettings, trace: TraceContext) async throws {
        guard let originalID = original.id else { throw IngestError.documentNotPersisted }
        payload.copyOf = originalID
        try await save(&job, payload, state: .hashing)
        if let given = payload.tags { payload.tags = try await services.giveTags(given, docID: originalID, trace: trace) }
        var trashed: URL?
        if FileManager.default.fileExists(atPath: copy.path) {
            do { trashed = try services.trash.trash(copy) } catch {
                throw IngestError.notTrashed(copy.path, reason: error.localizedDescription)
            }
        }
        let current = try await services.documents.document(id: originalID) ?? original
        try await services.queueReadingAgain(current, content: nil, settings: settings)
        let tags = payload.tags ?? []
        let summary = ["\(copy.lastPathComponent) is a copy of \(original.filename), which is read again",
                       trashed.map { _ in "the copy is in the Trash" }, GivenTag.note(tags)].compactMap { $0 }.joined(separator: "; ")
        try await services.history.record(.duplicate, doc: originalID, job: job.id, trace: trace.traceID, summary: summary,
                                          payload: CopyPayload(copy: copy.path, trashed: trashed?.path, tags: tags.isEmpty ? nil : tags))
        try await save(&job, payload, state: .duplicate)
        Log.info(.ingest, "A copy of a document in the archive; its original is read again",
                 ["copy": copy.path, "doc": String(originalID), "trashed": trashed?.path ?? "-"])
    }
}

/// What History keeps of a file that was an exact copy of a document in the archive, whose event is the original's: where
/// the copy was and where the Trash put it, and the tags it gave the original. Its keys are none that the events of
/// copies kept before (`original` and `path`, or `from`, `to` and `problems`) were written under.
public struct CopyPayload: Sendable, Codable, Hashable {
    /// The copy's path in Incoming.
    public var copy: String
    /// Where the Trash put it; absent when that cannot be told, as when a stop came after it went.
    public var trashed: String?
    /// The tags the copy gave its original, and what gave each; absent when it gave none.
    public var tags: [GivenTag]?

    public init(copy: String, trashed: String?, tags: [GivenTag]?) {
        self.copy = copy
        self.trashed = trashed
        self.tags = tags
    }
}
