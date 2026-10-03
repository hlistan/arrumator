import Foundation

/// What a failure does to a job: a stop is none; Ollama away, or the archive's folder gone, makes it wait without spending
/// an attempt; a model missing holds it; a refusal that will not change ends it at once, leaving its file in Incoming
/// (`leaveInIncoming`); a file changed after it was read goes back to the start (`readFromTheStart`); anything else is
/// tried again after `ingest.retryDelays`, and after `ingest.maxAttempts` the file is parked in the archive as failed.
extension IngestCoordinator {
    func handleFailure(_ job: inout JobRecord, payload: JobPayload, error: any Error, trace: TraceContext) async {
        // Stopping interrupts the job; that is no failure. Its saved stage lets it resume where it stopped.
        guard !Task.isCancelled else {
            Log.info(.ingest, "Job interrupted by stopping", ["job": String(job.id ?? 0), "stage": job.state.rawValue])
            return
        }
        let message = error.localizedDescription
        let config = services.config.ingest
        // Ollama away costs no attempt, however long it is away; a server that answers, but with a failure or not in time,
        // as it may for one image or one document alone, does, so the job ends rather than coming back for ever.
        let ollamaDown = await ollamaIsAway(error)
        let lastError = job.lastError
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
        if case FileOperationError.folderMissing = error {
            // The archive's folder is not there, as on a disk not attached: the job waits for it, as for Ollama, without
            // spending an attempt, and History says so once.
            job.nextRunAt = services.time.now().addingTimeInterval(config.retryDelays.last)
            await keep(job, event: lastError == message ? nil : .retry, summary: "Waiting for the archive: \(message)", trace: trace)
            await services.traces.finish(trace, outcome: "waiting", docID: job.docId)
            Log.warning(.ingest, "The archive's folder is not there; will retry", ["job": String(job.id ?? 0)])
            return
        }
        if Self.isFinal(error) {
            job.state = .failed
            await keep(job, event: nil, summary: message, trace: trace)
            await leaveInIncoming(job: job, payload: payload, message: message, trace: trace)
            await services.traces.finish(trace, outcome: "failed", docID: job.docId)
            Log.error(.ingest, "The Trash refused the file; it stays in Incoming", ["job": String(job.id ?? 0), "error": message])
            return
        }
        job.attempt += 1
        if job.attempt < config.maxAttempts, case FileOperationError.sourceChanged = error {
            await readFromTheStart(&job, payload: payload, trace: trace)
            return
        }
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

    /// Whether `error` says Ollama is away: it could not be reached, or it did not answer in time and does not answer a
    /// probe for its version either, which a server busy with one request it cannot finish does.
    private func ollamaIsAway(_ error: any Error) async -> Bool {
        guard let error = error as? OllamaError else { return false }
        if error.isAway { return true }
        guard error.timedOut else { return false }
        // A probe: its failure is the answer, whatever it is.
        return (try? await services.ollama.version()) == nil
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

    /// Sends a job whose file changed after it was hashed back to the start, as a new arrival: it is hashed, read and
    /// named again, so nothing read of what it was is filed as what it is (`FileOperationError.sourceChanged`). Its tags
    /// go with it; what was read of it does not, neither with the job nor with its document (`IndexStore.forgetReading`).
    /// Recorded once, and due at once, as nothing failed; it costs an attempt, so a file that changes at every reading
    /// ends as any job that keeps failing does.
    private func readFromTheStart(_ job: inout JobRecord, payload: JobPayload, trace: TraceContext) async {
        var fresh = JobPayload()
        fresh.tags = payload.tags
        job.setPayload(fresh)
        job.state = .pending
        job.nextRunAt = services.time.now()
        // The document is an arrival again: nothing read of what the file was stays with it, its tags aside.
        if let docID = job.docId {
            do { try await services.index.forgetReading(docID: docID) } catch {
                Log.error(.ingest, "Could not take back a reading", ["doc": String(docID), "error": error.localizedDescription])
            }
            await services.vectors.remove(docID: docID)
        }
        let name = URL(fileURLWithPath: job.sourcePath).lastPathComponent
        await keep(job, event: .retry, summary: "\(name) changed after it was read; it is read again from the start", trace: trace)
        await services.traces.finish(trace, outcome: "retry", docID: job.docId)
        Log.info(.ingest, "File changed after it was read; reading it again", ["job": String(job.id ?? 0)])
    }

    /// A refusal that will not change, however often it is tried: a Trash that will not take a file, moved to another
    /// volume or an exact copy. It is never tried again, nor parked by moving the file again (`leaveInIncoming`).
    static func isFinal(_ error: any Error) -> Bool {
        if case FileOperationError.sourceNotTrashed = error { return true }
        if case IngestError.notTrashed = error { return true }
        return false
    }

    /// Whether `known`, the document recorded at a path `enqueue` is asked to queue, stays where it is: one left for later
    /// or undone, which the user decides about; and one left in Incoming as failed (`leaveInIncoming`) while the file
    /// there is still that one (`FileFingerprint.matches`), as a file put in its place later is another.
    func stays(_ known: DocumentRecord, at url: URL) -> Bool {
        if [.held, .undone].contains(known.status) { return true }
        guard isLeftInIncoming(known), let recorded = known.fingerprint else { return false }
        return (try? FileFingerprint.of(url))?.matches(recorded) ?? false
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
            guard var document = known, let docID = document.id else {
                try await services.history.record(.failed, job: job.id, trace: trace.traceID, summary: message)
                return
            }
            var analysis = payload.outcome?.analysis ?? document.analysis ?? DocumentAnalysis()
            analysis.problems = (payload.outcome?.analysis.problems ?? []) + [Self.notFiled + message]
            document.status = .failed
            document.analysisJson = JSON.string(analysis)
            _ = try await services.documents.save(document)
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
        guard let docID, var document = try await services.documents.document(id: docID), document.status == .processing else { return }
        document.status = status
        document.duplicateOf = original
        _ = try await services.documents.save(document)
    }

    /// Records in History what concerns a file in Incoming and no document; one that cannot be recorded is logged.
    func record(_ kind: EventKind, summary: String, path: String) async {
        do { try await services.history.record(kind, summary: summary, payload: ["path": path]) } catch {
            Log.error(.ingest, "Could not record a file in Incoming", ["path": path, "error": error.localizedDescription])
        }
    }

    /// Moves a new file that could not be processed into the archive, where it waits for the user, so Incoming stays
    /// clean and nothing is lost; a document already in the archive stays where it is. One that cannot be moved there
    /// either stays in Incoming, failed, saying why (`leaveInIncoming`).
    private func parkFailedDocument(job: JobRecord, message: String, trace: TraceContext) async {
        do {
            let settings = await services.settings.current
            guard let docID = job.docId, let document = try await services.documents.document(id: docID) else {
                try await services.history.record(.failed, job: job.id, trace: trace.traceID, summary: message)
                return
            }
            let analysis = DocumentAnalysis(problems: ["Processing failed: \(message)"])
            if FileManager.default.fileExists(atPath: document.path), job.kind == .ingest {
                do {
                    _ = try await services.filer.file(document, archive: services.archive, analysis: analysis, status: .failed,
                                                      directory: services.archive,
                                                      inPlace: false, fingerprint: nil, actor: .system, settings: settings, trace: trace,
                                                      event: .failed, recording: nil)
                } catch where !(error is CancellationError) && FileManager.default.fileExists(atPath: document.path) {
                    await leaveInIncoming(job: job, payload: JobPayload(),
                                          message: "\(message); nor could it be moved into the archive: \(error.localizedDescription)", trace: trace)
                }
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
