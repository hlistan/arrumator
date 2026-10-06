import Foundation
import GRDB
import Synchronization
import UniformTypeIdentifiers

/// Runs ingest jobs one at a time through hashing → extracting → analysing → filing, in the order they were queued
/// (`JobStore.nextDue`). Every transition is persisted, so a job stopped part way, by quitting, a crash or a forced
/// quit, keeps its stage and its place, and carries on from its last finished stage first at the next start.
public actor IngestCoordinator {
    let services: PipelineServices
    private var worker: Task<Void, Never>?
    /// Whether the archive is away (`archive(isAway:)`).
    public private(set) var archiveAway = false
    /// Until when no job is read for its text, as the last one found Ollama away and waits until then to try again
    /// (`handleFailure`): every other job needs Ollama too, so none is read meanwhile only to wait at its model's step;
    /// only a file that came and is not hashed yet is taken, as a copy to hand over, and waits before its text
    /// (`JobStore.beforeTheModel`, `waitsForOllama`). The status says it (`IngestStatus.retryAt`).
    var ollamaRetryAt: Date? {
        didSet { status.retryAt = ollamaRetryAt }
    }
    private let doorbell = Doorbell()
    /// Whether the worker waits, having looked at its queue and found nothing it may take, as when it is paused or the
    /// archive is away: what a test waits for before it asserts that nothing was taken.
    var waits: Bool { doorbell.isWaitedOn }
    /// What deadlines gave up on while working on each job and that still runs (`LeftRunning`), and since when: a job
    /// is not started again while any of it goes on, so abandoned parses of one file never stack up; each that ends
    /// rings the doorbell. Work that has not ended after `ingest.abandonedWorkSeconds` never will be waited for: its
    /// job is taken up and fails, saying why (`overdue`). Kept by this coordinator alone: work an earlier runtime of the
    /// process gave up on, as before a switch of archives, is unknown to it.
    private var leftRunning: [Int64: (work: LeftRunning, since: Date)] = [:]
    /// The jobs whose abandoned work outlasted `ingest.abandonedWorkSeconds`, to fail when they are next taken.
    private var overdue: Set<Int64> = []
    private var statusContinuations: [UUID: AsyncStream<IngestStatus>.Continuation] = [:]
    public internal(set) var status = IngestStatus.idle {
        didSet { if status != oldValue { for c in statusContinuations.values { c.yield(status) } } }
    }

    /// What reading a file's text found, as History says it: how much text, from what. The language is the model's label
    /// to give: the detector's guess, which a mixed page misleads, is not repeated.
    static func extractedSummary(_ content: ExtractedContent) -> String {
        content.text.isEmpty ? "No text in \(content.kind.described)"
            : "Read \(Format.count(content.text.count, "character")) of text from \(content.kind.described)"
    }

    public init(services: PipelineServices) {
        self.services = services
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

    /// Starts the worker, unless it runs: the worker is claimed before anything is awaited, so a second start never
    /// makes a second worker. A job stopped part way needs nothing done to it: it is due, and was queued before anything
    /// that arrived after it, so the worker takes it up first.
    public func start() async {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.logResumingJobs()
            await self?.runLoop()
        }
        doorbell.ring()
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
        // A stopped worker waits for nothing, Ollama included; the next start looks again.
        (status.waitingForOllama, ollamaRetryAt) = (false, nil)
    }

    public func wake() { doorbell.ring() }

    /// The archive's folder is away, as on a disk not connected, or back. While it is away no job is begun, and the one
    /// in hand stops at its next stage, waiting without spending an attempt (`handleFailure`): nothing of Incoming is read
    /// or sent to the model. Its coming back wakes the worker.
    public func archive(isAway: Bool) {
        archiveAway = isAway
        if !isAway { doorbell.ring() }
    }

    /// Throws what the archive's folder missing throws, so the job waits for it, when the archive is away (`archive(isAway:)`).
    func checkArchiveThere() throws {
        if archiveAway { throw FileOperationError.folderMissing(services.archive.path) }
    }

    /// Takes what the Incoming watcher found (`IncomingWatcher.arrivals()`): a file that has stopped changing is queued
    /// (`enqueue`), and one it stopped waiting for is recorded in History with why, so the user sees why it stays in
    /// Incoming. That one is not queued; the watcher takes it up again once it can be opened or it changes. One still
    /// changing after `watcher.stabilityMaxWaitSeconds` is recorded once too; the watcher waits for it still.
    public func receive(_ arrival: IncomingArrival) async {
        switch arrival {
        case let .stable(url):
            await enqueue(url)
        case let .unopenable(url, why):
            let path = url.spelledOnDisk.path
            let summary = switch why {
            case .unreadable: "\(url.lastPathComponent) in Incoming cannot be opened; it is taken once it can be"
            case let .tooManyItems(limit):
                "\(url.lastPathComponent) in Incoming holds more than \(Format.count(limit, "item")), too many for one document (watcher.maxPackageItems)"
            }
            await record(.error, summary: summary, path: path)
        case let .stillChanging(url):
            let minutes = Format.count(Int((services.config.watcher.stabilityMaxWaitSeconds / 60).rounded(.up)), "minute")
            await record(.error, summary: "\(url.lastPathComponent) in Incoming has not stopped changing in \(minutes); it is taken once it stops",
                         path: url.spelledOnDisk.path)
        }
    }

    /// Called by the Incoming watcher for each stable file, and by `arrumatorcli ingest`, which may give it `tags` of
    /// its own. The file is taken as the document it belongs to (`PipelineServices.arrival`: the package a path inside
    /// one names), at its path in the one form a path is queued and looked up in (`URL.spelledOnDisk`), so whoever names
    /// it, through a link or in another case, names one job and one document; what is not taken, as a link or a package
    /// of too many items, is recorded in History with why. A document left where it is (`stays`) is not queued again.
    /// The tags the file is given are decided now, from where it is in Incoming (`PipelineServices.tags`), and kept with
    /// its job.
    @discardableResult
    public func enqueue(_ named: URL, tags: [String] = []) async -> Int64? {
        let url: URL
        do { url = try services.arrival(named, settings: await services.settings.current) } catch {
            await record(.error, summary: error.localizedDescription, path: named.spelledOnDisk.path)
            return nil
        }
        let path = url.path
        // A file in the archive is never an arrival, which would be a second document of a document's own file, or send
        // to the Trash, as a copy, one the user put there, which is read where it is, or one an earlier version set
        // aside beside its original: a document is read again as such (`ReviewActions.retry`).
        if services.archive.holds(path) {
            Log.debug(.ingest, "Ignoring a file in the archive", ["path": path])
            return nil
        }
        do {
            let known = try await services.documents.document(path: path)
            if let known, try await stays(known, at: url) {
                Log.debug(.ingest, "Ignoring held document", ["path": path, "doc": String(known.id ?? 0)])
                return nil
            }
            if let known, [.held, .undone].contains(known.status) { try await replaced(known) }
            // A file put where a document was left in Incoming, as an editor saving it, is that document arriving again.
            let again = known.flatMap { isLeftInIncoming($0) ? $0.id : nil }
            if let again { try await services.index.forgetReading(docID: again) }
            var payload = JobPayload()
            let given = services.tags(for: url, given: tags, settings: await services.settings.current)
            payload.tags = given.isEmpty ? nil : given
            let queued = try await services.jobs.enqueue(path: path, kind: .ingest, docID: again, payload: payload)
            // A file already queued arrives once: a rescan, or a request that asks no more, records nothing again.
            if queued.isNew {
                let summary = ([url.lastPathComponent] + [GivenTag.note(given)].compactMap { $0 }).joined(separator: " · ")
                try await services.history.record(.arrived, job: queued.id, summary: summary, payload: ArrivedPayload(path: path, tags: payload.tags))
                Log.info(.ingest, "Queued", ["path": path, "job": String(queued.id), "tags": given.map(\.label.value).joined(separator: ", ")])
            } else if !queued.tagsAdded.isEmpty {
                Log.info(.ingest, "Tags added to a queued file", ["job": String(queued.id), "tags": queued.tagsAdded.map(\.label.value).joined(separator: ", ")])
            }
            await refreshQueueCount()
            doorbell.ring()
            return queued.id
        } catch {
            Log.error(.ingest, "Could not queue file", ["path": path, "error": error.localizedDescription])
            return nil
        }
    }

    /// Processes due jobs until none are left that this worker may take, or the task that drains them is cancelled, as
    /// Ctrl-C cancels a command (CLI and tests): a job another process has in hand, as the app beside `arrumatorcli`,
    /// is left to it, and the job in hand when the task is cancelled carries on at the next start. Which jobs it takes,
    /// `draining` says: by default only those that come in their turn. Once a job finds Ollama away, it takes only the
    /// files that came and are not hashed yet, each then waiting before its text, and ends: no other is taken until that
    /// one is tried again (`ollamaRetryAt`), which a command does not wait for. Says which jobs it recorded a failure of
    /// at their last attempt in it: an attempt it spent and kept, its last, though its file then waits to be set aside, or
    /// one it spent before the job is tried again, or the job it ended failed; not one whose last attempt in it was filed,
    /// was read again from the start, as a file changed, or ended waiting with no failure kept, nor one another process
    /// failed.
    @discardableResult
    public func drain(_ draining: Draining = .inTurn) async -> Set<Int64> {
        var failed: Set<Int64> = []
        while !Task.isCancelled, case let .taken(job) = await nextDue(givingWay: draining == .everything) {
            // A job taken again in this drain, as one due again after it failed, ends as its last attempt ends.
            guard let id = job.id else { continue }
            if await process(job) { failed.insert(id) } else { failed.remove(id) }
        }
        await refreshQueueCount()
        return failed
    }

    /// The jobs work given up on still runs for, which are not started again until it has ended.
    func stillRunning() -> Set<Int64> {
        let limit = services.time.now().addingTimeInterval(-services.config.ingest.abandonedWorkSeconds)
        leftRunning = leftRunning.filter { $0.value.work.isRunning }
        for (id, left) in leftRunning where left.since <= limit {
            overdue.insert(id)
            leftRunning[id] = nil
        }
        return Set(leftRunning.keys)
    }

    /// When the earliest work given up on outlasts `ingest.abandonedWorkSeconds`, so the worker looks again then.
    var nextOverdue: Date? {
        leftRunning.values.map { $0.since.addingTimeInterval(services.config.ingest.abandonedWorkSeconds) }.min()
    }

    /// What the worker found when it looked for a job.
    private enum Look: Equatable {
        case taken(JobRecord)
        case none
        /// The queue could not be read, which is logged.
        case unreadable
    }

    /// The next job due now, taken for this worker (`JobStore.nextDue`), one that gives way only with `givingWay`; while
    /// the last one waits for Ollama (`ollamaRetryAt`), only one whose next stage needs no model, as a copy to hand over
    /// (`JobStore.beforeTheModel`). The wait is forgotten once its time has come: the job taken then is tried, and no time
    /// is said for it, while the status says the worker waits for Ollama until it answers.
    private func nextDue(givingWay: Bool = true) async -> Look {
        if let until = ollamaRetryAt, services.time.now() >= until { ollamaRetryAt = nil }
        do {
            return try await services.jobs.nextDue(claiming: services.claims, excluding: stillRunning(), givingWay: givingWay,
                                                   beforeTheModel: ollamaRetryAt != nil)
                .map(Look.taken) ?? .none
        } catch {
            Log.error(.ingest, "Could not read the job queue", ["error": error.localizedDescription])
            return .unreadable
        }
    }

    // MARK: Loop

    private func runLoop() async {
        while !Task.isCancelled {
            let settings = await services.settings.current
            let powerReason = services.power().pauseReason(settings: settings, config: services.config.power)
            status.powerPauseReason = powerReason
            let archiveThere = FileManager.default.fileExists(atPath: services.archive.path)
            var look = Look.none
            if !settings.paused, powerReason == nil, !archiveAway, archiveThere {
                look = await nextDue()
                if case let .taken(job) = look {
                    await process(job)
                    continue
                }
            }
            await refreshQueueCount()
            await doorbell.wait(timeout: await idleWait(paused: settings.paused, power: powerReason != nil,
                                                        archiveThere: archiveThere, queueUnread: look == .unreadable),
                                time: services.time)
        }
    }

    private func refreshQueueCount() async {
        do {
            let counts = try await services.jobs.counts()
            (status.queued, status.reindexing, status.readingAgain) = (counts.queued, counts.reindexing, counts.readingAgain)
            // Nothing left waits, for Ollama or anything else, as when the job that found it away was cancelled, a
            // document left for later meanwhile: no wait is said, nor kept, for what is gone.
            if counts.queued + counts.reindexing + counts.readingAgain == 0 { (status.waitingForOllama, ollamaRetryAt) = (false, nil) }
        } catch {
            Log.error(.ingest, "Could not count the job queue", ["error": error.localizedDescription])
        }
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

    /// Works on `initial`, a job taken for this worker (`nextDue`), as far as it goes now, then lets it go; says whether it
    /// recorded a failure of it (`handleFailure`).
    @discardableResult
    private func process(_ initial: JobRecord) async -> Bool {
        var job = initial
        var failed = false
        let takenWhileAway = ollamaRetryAt != nil
        // A job that waits for its model looks for it first, and waits on, with no trace and no attempt, while it is
        // not installed.
        if let model = (try? job.payload)?.waitingForModel, await stillMissing(model) {
            job.nextRunAt = services.time.now().addingTimeInterval(services.config.ingest.modelRecheckSeconds)
            do { try await services.jobs.update(job) } catch {
                Log.error(.ingest, "Could not put a job back to wait for its model", ["job": String(job.id ?? 0), "error": error.localizedDescription])
            }
            await Task { [services] in await Self.letGo(initial, services: services) }.value
            return false
        }
        let settings = await services.settings.current
        // The model that reads the file: the one `DocumentAnalyzer` reads with, from these settings. A profile that is
        // gone names none, and its reading fails saying so.
        let reader = try? settings.modelProfile().chatModel
        status.current = job.id.map {
            IngestStatus.Current(job: $0, path: job.sourcePath, stage: job.state, since: services.time.now(), reader: reader, tags: job.tags)
        }
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
        var payload = JobPayload()
        do {
            payload = try job.payload
            payload.traceID = trace.traceID
            payload.waitingForModel = nil
            let left = LeftRunning(ended: { [doorbell] in doorbell.ring() })
            defer { if let id = job.id, left.isRunning { leftRunning[id] = (left, services.time.now()) } }
            if let id = job.id, overdue.remove(id) != nil {
                throw IngestError.workLeftRunning(seconds: services.config.ingest.abandonedWorkSeconds)
            }
            try await LeftRunning.$current.withValue(left) {
                try await runStages(&job, payload: &payload, settings: settings, trace: trace)
            }
            // A job taken while Ollama is away says nothing of it: it ends before the model, or waits before its text is
            // read (`waitsForOllama`), which its trace ends saying; any other that ends says Ollama answers.
            if !takenWhileAway { (status.waitingForOllama, ollamaRetryAt) = (false, nil) }
            // A copy is no document: its trace is reached from its event in its original's History (`handOver`).
            await finish(trace, JobOutcome(ended: job.state), docID: job.docId)
        } catch IngestError.claimLost {
            // Cancelled meanwhile, or taken by a request that does more: nothing more of it is this worker's to save.
            Log.info(.ingest, "Job no longer this worker's; left as it is", ["job": String(job.id ?? 0)])
            await finish(trace, .cancelled, docID: job.docId)
        } catch {
            failed = await handleFailure(&job, payload: payload, error: error, trace: trace, takenWhileAway: takenWhileAway)
        }
        // Let go of in a task of its own, as a stopped worker's database accesses are cancelled, and before the worker
        // looks for its next job, which may be this one again.
        await Task { [services] in await Self.letGo(initial, services: services) }.value
        // A stopped worker reads nothing more: the database cancels a stopped task's reads, which is no error to log.
        if !Task.isCancelled { await refreshQueueCount() }
        return failed
    }

    /// Lets go of the claim `job` was taken with (`JobStore.release`), whatever stopped the worker. A job that has not
    /// ended waits in its place for the next worker.
    private static func letGo(_ job: JobRecord, services: PipelineServices) async {
        do { try await services.jobs.release(job, claims: services.claims) } catch {
            Log.error(.ingest, "Could not let go of a job", ["job": String(job.id ?? 0), "error": error.localizedDescription])
        }
    }

    /// Saves the job at `state` with `payload`. Tags a request gave it meanwhile (`JobStore.enqueue`) come back with the
    /// save, and are given to its document, or to the original of a copy, once it has one.
    func save(_ job: inout JobRecord, _ payload: inout JobPayload, state: JobState, trace: TraceContext) async throws {
        job.state = state
        try job.setPayload(payload)
        let saved = try await services.jobs.update(job)
        job = saved.job
        if !saved.tagsAdded.isEmpty {
            payload.tags = (payload.tags ?? []) + saved.tagsAdded
            if let docID = payload.copyOf ?? job.docId {
                payload.tags = try await services.giveTags(payload.tags ?? [], docID: docID, trace: trace)
            }
            try job.setPayload(payload)
        }
        if status.current?.stage != state {
            status.current?.stage = state
            status.current?.since = services.time.now()
        }
        status.current?.tags = job.tags
    }

    private func runStages(_ job: inout JobRecord, payload: inout JobPayload, settings: AppSettings,
                           trace: TraceContext) async throws {
        if job.kind == .reindex {
            try await reindex(&job, payload: &payload, settings: settings, trace: trace)
            return
        }
        guard let source = try await source(&job, payload: &payload, trace: trace) else { return }
        // A job that carries on from a later stage may have been given tags while it waited (`JobStore.enqueue`).
        if [.extracting, .analysing, .filing].contains(job.state), let docID = job.docId, let given = payload.tags,
           given.contains(where: \.isNew) {
            payload.tags = try await services.giveTags(given, docID: docID, trace: trace)
        }
        if job.state == .pending || job.state == .hashing {
            try checkArchiveThere()
            try await save(&job, &payload, state: .hashing, trace: trace)
            // A copy whose hand-over was decided (`copyOf`), gone to the Trash before a stop: what is left of handing it over
            // is done now, whatever its original became meanwhile, and whatever file is at its path now (`handOver`).
            if let id = payload.copyOf, !isStill(source, payload: payload), let original = try await services.documents.document(id: id) {
                try await handOver(source, to: original, job: &job, payload: &payload, trace: trace)
                return
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                try await save(&job, &payload, state: .cancelled, trace: trace)
                try await end(job.docId, as: .missing)
                try await services.history.record(.missing, doc: job.docId, job: job.id, trace: trace.traceID,
                                                  summary: "\(source.lastPathComponent) disappeared before processing")
                return
            }
            let (fingerprint, sha) = try await trace.measure(.hash, input: ["path": source.path],
                                                             output: { (r: (FileFingerprint, String)) in ["sha256": r.1, "size": String(r.0.size)] }) {
                (try FileFingerprint.of(source), try await HashService.sha256Concurrently(of: source))
            }
            payload.sha256 = sha
            payload.size = fingerprint.size
            payload.mtime = fingerprint.modified
            payload.inode = fingerprint.inode
            // A copy of a document undone or gone from the archive before it is handed over is a document of its own
            // (`handOver`), as is one of no original any more, though a stop came after it was found one.
            if let original = try await original(of: source, sha256: sha, job: job, trace: trace),
               try await handOver(source, to: original, job: &job, payload: &payload, trace: trace) {
                return
            }
            payload.copyOf = nil
            let document = try await ensureDocument(for: job, source: source, sha: sha, fingerprint: fingerprint)
            job.docId = document.id
            // The tags are the document's from when it is one, read or not.
            if let docID = document.id, let given = payload.tags {
                payload.tags = try await services.giveTags(given, docID: docID, trace: trace)
            }
            try await save(&job, &payload, state: .extracting, trace: trace)
        }
        guard let docID = job.docId, let sha = payload.sha256 else { throw IngestError.documentNotPersisted }
        if try await waitsForOllama(&job, payload: &payload, trace: trace) { return }

        if job.state == .extracting {
            try checkArchiveThere()
            let context = try services.config.extractionContext(settings: settings, whenOllamaIsAway: .wait)
            let content = try await services.extractor.extract(source, sha256: sha, context: context, trace: trace)
            payload.content = content
            // A document read again keeps what it had until it is filed (`fileDocument`).
            if job.kind != .reanalyse { try await storeExtraction(docID: docID, content: content) }
            try await services.history.record(.extracted, doc: docID, job: job.id, trace: trace.traceID,
                                              summary: Self.extractedSummary(content),
                                              payload: ["warnings": content.warnings.map(\.code.rawValue).joined(separator: ",")])
            try await save(&job, &payload, state: .analysing, trace: trace)
        }
        guard let content = payload.content else { throw IngestError.contentUnavailable(docID) }

        if job.state == .analysing {
            try checkArchiveThere()
            try await read(job, payload: &payload, docID: docID, content: content, settings: settings, trace: trace)
            try await save(&job, &payload, state: .filing, trace: trace)
        }
        guard let outcome = payload.outcome, job.kind != .reanalyse || payload.rereading != nil else { throw IngestError.analysisMissing(docID) }

        if job.state == .filing {
            try checkArchiveThere()
            try await fileDocument(&job, payload: &payload, docID: docID, content: content, outcome: outcome,
                                   settings: settings, trace: trace)
        }
    }

    /// Files the document under the name the model gave it: a new arrival at the top of the archive, a document read
    /// again where it is, one the user put in the archive left as it is. A document the model could not read waits
    /// for the user there. What a document read again was read as takes the place of everything it had in the
    /// transaction that records its filing (`PipelineServices.replaceReading`), so it is found as it was until then.
    ///
    /// The job's destination is recorded in the transaction that records the filing, so a job that stopped after it,
    /// on an error or a crash, finds it filed and finishes what is left instead of filing it again. Where the file is
    /// moved is kept with the job before it is moved (`JobPayload.plannedPath`), so a job cut off between the move and
    /// its record, as by a crash, finds the file there, by its identity or its bytes, and records it there.
    private func fileDocument(_ job: inout JobRecord, payload: inout JobPayload, docID: Int64, content: ExtractedContent,
                              outcome: AnalysisOutcome, settings: AppSettings, trace: TraceContext) async throws {
        guard let document = try await services.documents.document(id: docID) else { throw IngestError.documentNotFound(docID) }
        var analysis = outcome.analysis
        let status: DocumentStatus = analysis.problems.isEmpty ? .filed : .needsReview
        let filedRecord: DocumentRecord
        if let target = payload.targetPath, document.path == target, FileManager.default.fileExists(atPath: target) {
            Log.info(.ingest, "Filing already completed before the job stopped", ["doc": String(docID)])
            filedRecord = document
        } else {
            var keepsItsName = false
            if let rereading = payload.rereading {
                guard let filing = filing(document, rereading: rereading, analysis: analysis) else {
                    Log.info(.ingest, "No longer to be read again; left as it is", ["job": String(job.id ?? 0)])
                    try await save(&job, &payload, state: .cancelled, trace: trace)
                    return
                }
                (analysis, keepsItsName) = filing
            }
            let movedTo = try await movedBefore(document, planned: payload.plannedPath)
            guard movedTo != nil || FileManager.default.fileExists(atPath: document.path) else { throw IngestError.sourceMissing(document.path) }
            if movedTo != nil { Log.info(.ingest, "Recording a move made before the job stopped", ["doc": String(docID)]) }
            let directory = job.kind == .ingest ? services.archive : document.url.deletingLastPathComponent()
            let (unfiledJob, unfiledPayload, now, jobs) = (job, payload, services.time.now(), services.jobs)
            let plannedPath = Mutex<String?>(nil)
            let movedOnly = Mutex(false)
            // A failure after the plan was kept keeps it with the job's payload too, which the failure saves.
            defer { if let planned = plannedPath.withLock({ $0 }) { payload.plannedPath = planned } }
            filedRecord = try await services.filer.file(
                document, archive: services.archive, analysis: analysis, status: status, directory: directory,
                inPlace: job.kind == .adopt || keepsItsName,
                fingerprint: payload.fingerprint, actor: .system, settings: settings, trace: trace, event: nil,
                keeping: FilingKeeper(planning: { path in
                    var planned = unfiledPayload
                    planned.plannedPath = path
                    var plannedJob = unfiledJob
                    try plannedJob.setPayload(planned)
                    try await jobs.update(plannedJob)
                    plannedPath.withLock { $0 = path }
                },
                recording: { [services] db, filed in
                    var filedPayload = unfiledPayload
                    filedPayload.targetPath = filed.path
                    var filedJob = unfiledJob
                    try filedJob.setPayload(filedPayload)
                    // The file has moved: its record commits even when the job is no longer this worker's, which then
                    // saves nothing more of the job (`IngestError.claimLost` at its next save). A document read again
                    // whose job is no longer this worker's, as one left for later meanwhile, is left as the user left
                    // it: where it was when it has not moved, and else only where its file now is.
                    do { try JobStore.save(filedJob, at: now, in: db) } catch let IngestError.claimLost(id) {
                        guard unfiledPayload.rereading != nil else { return .filed }
                        guard filed.path != document.path else { throw IngestError.claimLost(id) }
                        movedOnly.withLock { $0 = true }
                        return .movedOnly
                    }
                    if let rereading = unfiledPayload.rereading {
                        try services.replaceReading(db, docID: docID, filename: filed.filename, content: content, outcome: outcome,
                                                    rereading: rereading, jobID: unfiledJob.id, traceID: unfiledPayload.traceID, at: now)
                    }
                    return .filed
                }), movedTo: movedTo)
            // Set aside while it was moved: nothing of the reading is kept, nor more of the job (`claimLost`).
            if movedOnly.withLock({ $0 }) { throw IngestError.claimLost(job.id ?? 0) }
        }
        payload.targetPath = filedRecord.path
        let traceID = trace.traceID
        try await services.documents.update(docID) { $0.lastTraceId = traceID }
        if payload.rereading != nil {
            await replaced(docID: docID, outcome: outcome, trace: trace)
        } else if let embedding = outcome.embedding, let model = outcome.embeddingModel {
            try await index(docID: docID, content: content, senders: outcome.labels?.values(.sender) ?? [], vector: embedding,
                            model: model, trace: trace)
        }
        try await save(&job, &payload, state: status == .needsReview ? .needsReview : .done, trace: trace)
        Log.info(.ingest, status == .needsReview ? "Filed; waiting for the user" : "Filed", ["doc": String(docID), "path": filedRecord.path])
    }
}
