import Foundation

/// How a job's trace ends (`TraceRecord.outcome`): the state the job ended in, or what it waits for.
enum JobOutcome: String {
    case done, duplicate, needsReview, failed, cancelled
    /// It waits for Ollama, or for the archive's folder, to come back.
    case waiting
    /// It waits for its model to be installed.
    case waitingForModel
    /// It failed, and is tried again.
    case retry

    /// The outcome of a job whose stages have run to `state`: one still active carries on later, as one that waits.
    init(ended state: JobState) {
        switch state {
        case .done: self = .done
        case .duplicate: self = .duplicate
        case .needsReview: self = .needsReview
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        case .pending, .hashing, .extracting, .analysing, .filing: self = .waiting
        }
    }
}

/// What a failure does to a job: a stop is none; Ollama away, the archive's folder gone or a model not installed makes it
/// wait without spending an attempt; a refusal that will not change ends it at once, leaving its file in Incoming
/// (`leaveInIncoming`); a file changed after it was read goes back to the start (`readFromTheStart`); anything else is
/// tried again after `ingest.retryDelays`, and after `ingest.maxAttempts` the file is parked in the archive as failed.
extension IngestCoordinator {
    /// Handles `error`, which ended `job`'s attempt; `takenWhileAway` says the job was taken while Ollama is away, as only
    /// one whose next stage needs no model is (`JobStore.beforeTheModel`), so its failure says nothing of Ollama. Says
    /// whether it recorded a failure of the job: an attempt spent and kept, or the job ended failed; not a stop, nor a
    /// wait for Ollama, the archive's folder or a model before an attempt is spent, nor a file read again from the start,
    /// nor a job no longer this worker's, as one cancelled while its failure is saved (`keep`), whose trace ends there.
    func handleFailure(_ job: inout JobRecord, payload: JobPayload, error: any Error, trace: TraceContext, takenWhileAway: Bool) async -> Bool {
        do {
            return try await recordFailure(&job, payload: payload, error: error, trace: trace, takenWhileAway: takenWhileAway)
        } catch {
            // `keep` found the job no longer this worker's, cancelled or taken over meanwhile: nothing more is done of it.
            await lost(job, trace)
            return false
        }
    }

    /// `handleFailure`, which throws `IngestError.claimLost` once the job is found no longer this worker's.
    private func recordFailure(_ job: inout JobRecord, payload: JobPayload, error: any Error, trace: TraceContext,
                               takenWhileAway: Bool) async throws -> Bool {
        // Stopping interrupts the job; that is no failure. Its saved stage lets it resume where it stopped.
        guard !Task.isCancelled else {
            Log.info(.ingest, "Job interrupted by stopping", ["job": String(job.id ?? 0), "stage": job.state.rawValue])
            return false
        }
        // A job no longer this worker's, cancelled or taken over meanwhile, is not this worker's to fail: the first write
        // of every path below saves the job only while its claim holds (`keep`), so nothing of it, its document or its
        // file is changed, and `handleFailure` ends it there.
        let message = error.localizedDescription
        let config = services.config.ingest
        // Ollama away costs no attempt, however long it is away; a server that answers, but with a failure or not in time,
        // as it may for one image or one document alone, does, so the job ends rather than coming back for ever.
        let ollamaDown = await services.ollamaIsAway(error)
        // A failure of anything else says Ollama answered, but for a job taken while Ollama is away, which never asks it.
        if !takenWhileAway {
            status.waitingForOllama = ollamaDown
            if !ollamaDown { ollamaRetryAt = nil }
        }
        let lastError = job.lastError
        job.lastError = message
        if case IngestError.unreadablePayload = error {
            // Trying again cannot read it either: the job ends, its payload kept as it is to show why, and its document
            // with it, which waits for the user in Needs You; the file a rescan finds again is queued afresh.
            job.state = .failed
            try await keep(job, event: .failed, summary: message, trace: trace)
            do { try await end(job.docId, as: .failed) } catch {
                Log.error(.ingest, "Could not record a document whose job failed", ["job": String(job.id ?? 0), "error": error.localizedDescription])
            }
            await finish(trace, .failed, docID: job.docId)
            Log.error(.ingest, "A job's payload cannot be read; the job failed", ["job": String(job.id ?? 0)])
            return true
        }
        // The failure path throws nothing: a payload that cannot be written keeps the one the job had, which is logged.
        do { try job.setPayload(payload) } catch {
            Log.error(.ingest, "Could not keep what a failed job had done", ["job": String(job.id ?? 0), "error": error.localizedDescription])
        }
        if case let OllamaError.modelNotFound(model) = error {
            try await waitForModel(&job, model: model, payload: payload, lastError: lastError, trace: trace)
            return false
        }
        if ollamaDown {
            job.nextRunAt = services.time.now().addingTimeInterval(config.retryDelays.last)
            // No other job is read for its text meanwhile, as each would only wait for Ollama too (`JobStore.beforeTheModel`).
            ollamaRetryAt = job.nextRunAt
            try await keep(job, event: lastError == message ? nil : .retry, summary: "Waiting for Ollama: \(message)", trace: trace)
            await finish(trace, .waiting, docID: job.docId)
            Log.warning(.ingest, "Ollama unavailable; will retry", ["job": String(job.id ?? 0), "error": message])
            return false
        }
        if case FileOperationError.folderMissing = error {
            // The archive's folder is not there, as on a disk not attached: the job waits for it, as for Ollama, without
            // spending an attempt, and History says so once.
            job.nextRunAt = services.time.now().addingTimeInterval(config.retryDelays.last)
            try await keep(job, event: lastError == message ? nil : .retry, summary: "Waiting for the archive: \(message)", trace: trace)
            await finish(trace, .waiting, docID: job.docId)
            Log.warning(.ingest, "The archive's folder is not there; will retry", ["job": String(job.id ?? 0)])
            return false
        }
        if Self.isFinal(error) {
            job.state = .failed
            try await keep(job, event: nil, summary: message, trace: trace)
            await leaveInIncoming(job: job, payload: payload, message: message, trace: trace)
            await finish(trace, .failed, docID: job.docId)
            Log.error(.ingest, "The Trash refused the file; it stays in Incoming", ["job": String(job.id ?? 0), "error": message])
            return true
        }
        job.attempt += 1
        if job.attempt < config.maxAttempts, case FileOperationError.sourceChanged = error {
            try await readFromTheStart(&job, payload: payload, trace: trace)
            return false
        }
        if job.attempt < config.maxAttempts {
            job.nextRunAt = services.time.now().addingTimeInterval(config.retryDelays.clamped(job.attempt - 1))
            try await keep(job, event: .retry, summary: "Attempt \(job.attempt) failed: \(message)", trace: trace)
            await finish(trace, .retry, docID: job.docId)
            Log.warning(.ingest, "Stage failed; retrying", ["job": String(job.id ?? 0), "stage": job.state.rawValue,
                                                            "attempt": String(job.attempt), "error": message])
            return true
        }
        return try await setAside(&job, message: message, lastError: lastError, trace: trace)
    }

    /// Fails a job that has spent its attempts, setting its file aside in the archive (`parkFailedDocument`), or waits for
    /// the archive's folder to do so: a failure recorded either way, once its last attempt is kept. Throws
    /// `IngestError.claimLost` when the job is no longer this worker's before that, or before its file is set aside; one
    /// lost after it changes nothing of the failure recorded.
    private func setAside(_ job: inout JobRecord, message: String, lastError: String?, trace: TraceContext) async throws -> Bool {
        let config = services.config.ingest
        // The attempt is saved while the claim holds, before the file is parked; the move itself is made only if the
        // claim still holds when it is (`parkFailedDocument`).
        try await keep(job, event: nil, summary: message, trace: trace)
        switch await parkFailedDocument(job: job, message: message, trace: trace) {
        case .parked: break
        case .lost:
            throw IngestError.claimLost(job.id ?? 0)
        case .archiveAway:
            // The archive's folder is not there to park the file in: the job waits for it, as a stage does, and is tried
            // once more when it is back, then parked; History says so once.
            job.nextRunAt = services.time.now().addingTimeInterval(config.retryDelays.last)
            // The failure is kept; a job taken over meanwhile waits for nothing of this worker's, and its trace says so.
            do {
                try await keep(job, event: lastError == message ? nil : .retry, summary: "Waiting for the archive to set aside: \(message)",
                               trace: trace)
                await finish(trace, .waiting, docID: job.docId)
            } catch {
                await finish(trace, .cancelled, docID: job.docId)
            }
            Log.warning(.ingest, "The archive's folder is not there to park a failed file; will retry", ["job": String(job.id ?? 0)])
            return true
        }
        job.state = .failed
        // The file is set aside as failed, which History records: the failure stands, whoever has the job now.
        try? await keep(job, event: nil, summary: message, trace: trace)
        await finish(trace, .failed, docID: job.docId)
        Log.error(.ingest, "Job failed", ["job": String(job.id ?? 0), "error": message])
        return true
    }

    /// The model is not installed: the job waits at its stage for it to be, spending no attempt, and looks again every
    /// `ingest.modelRecheckSeconds` whether the server lists it (`stillMissing`), with no trace or attempt until it does;
    /// the Incoming queue says what to do, and History says so once.
    private func waitForModel(_ job: inout JobRecord, model: String, payload: JobPayload, lastError: String?, trace: TraceContext) async throws {
        var waiting = payload
        waiting.waitingForModel = model
        do { try job.setPayload(waiting) } catch {
            Log.error(.ingest, "Could not keep which model a job waits for", ["job": String(job.id ?? 0), "error": error.localizedDescription])
        }
        job.lastError = Self.install(model)
        job.nextRunAt = services.time.now().addingTimeInterval(services.config.ingest.modelRecheckSeconds)
        try await keep(job, event: lastError == job.lastError ? nil : .error, summary: "Model missing: \(Self.install(model))", trace: trace)
        await finish(trace, .waitingForModel, docID: job.docId)
        Log.error(.ingest, "Model missing; the job waits for it", ["job": String(job.id ?? 0)])
    }

    /// What a job waiting for `model` says in the queue: what to do.
    static func install(_ model: String) -> String {
        "\(model) is not installed in Ollama: download it in Settings › Models, or with arrumatorcli models pull \(model)"
    }

    /// Whether `model`, which a job waits for, is still not installed: not among the models the server lists. A server
    /// that cannot list them says nothing either way, and the job is taken up, to wait for Ollama as a stage does.
    func stillMissing(_ model: String) async -> Bool {
        guard let installed = try? await services.ollama.tags() else { return false }
        let wanted = ModelManager.normalized(model)
        return !installed.contains { ModelManager.normalized($0.name) == wanted }
    }

    /// Saves what a failure did to a job and records it in the history. Both are already the failure path: what cannot be
    /// saved is logged, and the job, unchanged in the queue, is taken again in its turn. Throws `IngestError.claimLost`
    /// alone, when the job was cancelled or taken over meanwhile, and nothing more is done of its failure
    /// (`handleFailure`).
    private func keep(_ job: JobRecord, event: EventKind?, summary: String, trace: TraceContext) async throws {
        do { try await services.jobs.update(job) } catch IngestError.claimLost {
            throw IngestError.claimLost(job.id ?? 0)
        } catch {
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

    /// Ends a failure of a job no longer this worker's, found where its outcome was to be saved: nothing more is done.
    private func lost(_ job: JobRecord, _ trace: TraceContext) async {
        Log.info(.ingest, "Job no longer this worker's; its failure changes nothing", ["job": String(job.id ?? 0)])
        await finish(trace, .cancelled, docID: job.docId)
    }

    /// Sends a job whose file changed after it was hashed back to the start, as a new arrival: it is hashed, read and
    /// named again, so nothing read of what it was is filed as what it is (`FileOperationError.sourceChanged`). Its tags
    /// go with it; what was read of it does not, neither with the job nor with its document (`IndexStore.forgetReading`),
    /// but for a document in the archive read again, which keeps what it had until it is filed. Recorded once, and due at
    /// once, as nothing failed; it costs an attempt, so a file that changes at every reading ends as any job that keeps
    /// failing does.
    private func readFromTheStart(_ job: inout JobRecord, payload: JobPayload, trace: TraceContext) async throws {
        var fresh = JobPayload()
        fresh.tags = payload.tags
        // What a document read again had when it was asked for stays what the user's changes are told by.
        fresh.rereading = payload.rereading
        do { try job.setPayload(fresh) } catch {
            Log.error(.ingest, "Could not keep what a failed job had done", ["job": String(job.id ?? 0), "error": error.localizedDescription])
        }
        job.state = .pending
        job.nextRunAt = services.time.now()
        let name = URL(fileURLWithPath: job.sourcePath).lastPathComponent
        try await keep(job, event: .retry, summary: "\(name) changed after it was read; it is read again from the start", trace: trace)
        // The document is an arrival again: nothing read of what the file was stays with it, its tags aside.
        if let docID = job.docId, job.kind != .reanalyse {
            do { try await services.index.forgetReading(docID: docID) } catch {
                Log.error(.ingest, "Could not take back a reading", ["doc": String(docID), "error": error.localizedDescription])
            }
            await services.vectors.remove(docID: docID)
        }
        await finish(trace, .retry, docID: job.docId)
        Log.info(.ingest, "File changed after it was read; reading it again", ["job": String(job.id ?? 0)])
    }

    /// A refusal that will not change, however often it is tried: a Trash that will not take a file, moved to another
    /// volume or an exact copy. It is never tried again, nor parked by moving the file again (`leaveInIncoming`).
    static func isFinal(_ error: any Error) -> Bool {
        if case FileOperationError.sourceNotTrashed = error { return true }
        if case IngestError.notTrashed = error { return true }
        if case IngestError.workLeftRunning = error { return true }
        return false
    }

    /// Whether `known`, the document recorded at a path `enqueue` is asked to queue, stays where it is, while the file
    /// there is still that document, as one put in its place later is another: one left for later or undone, which the
    /// user decides about, the file being that one by its fingerprint or, as after an undo across volumes, by its bytes;
    /// and one left in Incoming as failed (`leaveInIncoming`), by its fingerprint (`FileFingerprint.matches`).
    func stays(_ known: DocumentRecord, at url: URL) async throws -> Bool {
        let now = try? FileFingerprint.of(url)
        let same = known.fingerprint.flatMap { recorded in now.map { $0.matches(recorded) } } ?? false
        if [.held, .undone].contains(known.status) {
            if same { return true }
            guard now != nil else { return false }
            return try await HashService.sha256Concurrently(of: url) == known.sha256
        }
        return isLeftInIncoming(known) && same
    }

    /// Ends `known`, a document left for later or undone in Incoming, whose file is no longer there: another file came
    /// in its place, which is taken as an arrival of its own. History says so.
    func replaced(_ known: DocumentRecord) async throws {
        guard let docID = known.id else { return }
        try await services.documents.update(docID) { $0.status = .missing }
        try await services.history.record(.missing, doc: docID, summary: "\(known.filename) is no longer in Incoming; the file there now is another")
    }

    /// Whether `document` was left in Incoming, not filed (`leaveInIncoming`): failed, and its file outside the archive
    /// (`PipelineServices.isInArchive`). Told by its status and where it is, never by how its problem is worded.
    func isLeftInIncoming(_ document: DocumentRecord) -> Bool {
        document.status == .failed && !services.isInArchive(document)
    }

    /// What the problem of a document left in Incoming begins with: wording only, which nothing reads back.
    static let notFiled = "Not filed: "

    /// Leaves a file the app cannot move out of Incoming where it is, failed, waiting for the user in Needs You with why
    /// (`DocumentStatus.failed`, "Could not be processed": not left for later, which is the user's to say), and records
    /// that once: a refusal that will not change (`isFinal`) is never tried again nor parked by moving it, and a rescan
    /// leaves the file alone while it is that file (`stays`). What the model read of it in this job is kept with it, and
    /// its problems are this job's, never those of an earlier one. A file that is no document yet, as an exact copy,
    /// becomes one, so it is shown and left alone the same way, and **Read Again** hands it over to its original once
    /// the Trash takes it (`PipelineServices.queueReadingAgain`).
    private func leaveInIncoming(job: JobRecord, payload: JobPayload, message: String, trace: TraceContext) async {
        do {
            let source = URL(fileURLWithPath: job.sourcePath)
            var known: DocumentRecord?
            if let docID = job.docId { known = try await services.documents.document(id: docID) }
            if known == nil, let sha = payload.sha256, FileManager.default.fileExists(atPath: source.path) {
                known = try await ensureDocument(for: job, source: source, sha: sha, fingerprint: try FileFingerprint.of(source))
            }
            guard let document = known, let docID = document.id else {
                try await services.history.record(.failed, job: job.id, trace: trace.traceID, summary: message)
                return
            }
            let read = payload.outcome?.analysis
            try await services.documents.update(docID) { document in
                var analysis = read ?? document.analysis ?? DocumentAnalysis()
                analysis.problems = (read?.problems ?? []) + [Self.notFiled + message]
                document.status = .failed
                document.analysisJson = try JSON.string(analysis)
            }
            try await services.history.record(.failed, doc: docID, job: job.id, trace: trace.traceID,
                                              summary: "\(document.originalFilename) stays in Incoming: \(message)")
        } catch {
            Log.error(.ingest, "Could not record a file left in Incoming", ["job": String(job.id ?? 0), "error": error.localizedDescription])
        }
    }

    /// Ends the document a job's file was, when the file is no longer one to file: gone (`missing`), or found an exact
    /// copy of `original` (`duplicate`). What a reading of it had found was taken back when it went back to the start
    /// (`readFromTheStart`).
    func end(_ docID: Int64?, as status: DocumentStatus, of original: Int64? = nil) async throws {
        guard let docID, try await services.documents.document(id: docID) != nil else { return }
        try await services.documents.update(docID) { document in
            guard document.status == .processing else { return }
            document.status = status
            document.duplicateOf = original
        }
    }

    /// Records in History what concerns a file in Incoming and no document; one that cannot be recorded is logged.
    func record(_ kind: EventKind, summary: String, path: String) async {
        do { try await services.history.record(kind, summary: summary, payload: ["path": path]) } catch {
            Log.error(.ingest, "Could not record a file in Incoming", ["path": path, "error": error.localizedDescription])
        }
    }

    /// Moves a new file that could not be processed into the archive, where it waits for the user, so Incoming stays
    /// clean and nothing is lost; a document already in the archive stays where it is. One that cannot be moved there
    /// either stays in Incoming, failed, saying why (`leaveInIncoming`); one that cannot be parked for the archive's folder
    /// not being there is not parked, and waits for it; one whose job is no longer this worker's when it would be moved is
    /// not moved. A failure to record what was done
    /// is recorded in History, with the job, so the user sees it.
    private func parkFailedDocument(job: JobRecord, message: String, trace: TraceContext) async -> Parking {
        do {
            let settings = await services.settings.current
            guard let docID = job.docId, let document = try await services.documents.document(id: docID) else {
                // Recorded in the write that checks the job's claim still holds, as below.
                let now = services.time.now()
                do {
                    try await services.database.writer.write { db in
                        _ = try JobStore.save(job, at: now, in: db)
                        try HistoryStore.insert(db, .failed, at: now, job: job.id, trace: trace.traceID, summary: message)
                    }
                } catch IngestError.claimLost { return .lost }
                return .parked
            }
            let analysis = DocumentAnalysis(problems: ["Processing failed: \(message)"])
            if FileManager.default.fileExists(atPath: document.path), job.kind == .ingest {
                let jobs = services.jobs
                // The file is moved only while the job's claim holds, checked in a write just before the move.
                let checked = FilingKeeper(planning: { _ in try await jobs.update(job) }, recording: { _, _ in .filed })
                do {
                    _ = try await services.filer.file(document, archive: services.archive, analysis: analysis, status: .failed,
                                                      directory: services.archive,
                                                      inPlace: false, fingerprint: nil, actor: .system, settings: settings, trace: trace,
                                                      event: .failed, keeping: checked)
                } catch FileOperationError.folderMissing {
                    return .archiveAway
                } catch IngestError.claimLost {
                    return .lost
                } catch where !(error is CancellationError) && FileManager.default.fileExists(atPath: document.path) {
                    await leaveInIncoming(job: job, payload: JobPayload(),
                                          message: "\(message); nor could it be moved into the archive: \(error.localizedDescription)", trace: trace)
                }
            } else {
                // The document is marked failed, and History says so, in the write that checks the job's claim still
                // holds, as a file is filed (`DocumentFiler`): one the user left for later before it stays as the user
                // left it, as leaving it for later cancels the job in its own write (`ReviewActions.hold`). A filed
                // document read again for search after a rebuild (`reindex`) stays as its record says, filed, held or
                // undone, whose reading for search alone failed: History says so.
                let now = services.time.now()
                let analysisJSON = try JSON.string(analysis)
                let summary = "\(document.originalFilename): \(message)"
                do {
                    try await services.database.writer.write { db in
                        _ = try JobStore.save(job, at: now, in: db)
                        if job.kind != .reindex {
                            guard let read = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
                            var failed = read
                            failed.status = .failed
                            failed.analysisJson = analysisJSON
                            failed.updatedAt = now
                            try failed.updateChanges(db, from: read)
                        }
                        try HistoryStore.insert(db, .failed, at: now, doc: docID, job: job.id, trace: trace.traceID, summary: summary)
                    }
                } catch IngestError.claimLost { return .lost }
            }
        } catch {
            Log.error(.ingest, "Could not park failed document", ["job": String(job.id ?? 0), "error": error.localizedDescription])
            let name = URL(fileURLWithPath: job.sourcePath).lastPathComponent
            do {
                try await services.history.record(.failed, doc: job.docId, job: job.id, trace: trace.traceID,
                                                  summary: "\(name) failed (\(message)), and that could not be recorded with it: \(error.localizedDescription)")
            } catch {
                Log.error(.ingest, "Could not record a failed document either", ["job": String(job.id ?? 0), "error": error.localizedDescription])
            }
        }
        return .parked
    }

    /// What setting a failed file aside came to.
    enum Parking {
        /// Set aside, or left where it is saying why: done with.
        case parked
        /// The archive's folder is not there to set it aside in.
        case archiveAway
        /// The job is no longer this worker's: nothing was moved.
        case lost
    }
}
