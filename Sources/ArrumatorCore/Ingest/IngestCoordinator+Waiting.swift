import Foundation

/// Which jobs a command works through (`IngestCoordinator.drain`); the app and `arrumatorcli run` work through all of them.
public enum Draining: Sendable, Equatable {
    /// Those that come in their turn, as the files a command files or reads again, and never one that gives way
    /// (`JobRecord.givesWay`: reading documents again for search after a rebuild, or the whole archive at once), which
    /// may take hours, and which the app or `run` works through.
    case inTurn
    /// Those that give way too, as reading the whole archive again from a command asks (`review retry --all`).
    case everything
}

/// How the worker waits when it has taken no job.
extension IngestCoordinator {
    /// Drains as `drain` does, then, while `job` is still to be done and no job is read for its text until the one that
    /// found Ollama away is tried again (`ollamaRetryAt`), waits until then and drains again: a file held behind one
    /// that found Ollama away, or one that found it away itself, is read once Ollama is back, as the app reads it,
    /// rather than left unread, as `arrumatorcli eval` reads each fixture. Waits as long as Ollama is away, until the
    /// task is cancelled.
    public func drain(waitingOutOllamaFor job: Int64) async {
        await drain()
        while !Task.isCancelled, let until = ollamaRetryAt, await stillToDo(job) {
            do { try await services.time.sleep(seconds: max(0, until.timeIntervalSince(services.time.now()))) } catch { return }
            await drain()
        }
    }

    /// Whether `job` is still in the queue, to be done; not when the queue cannot be read, which is logged.
    private func stillToDo(_ job: Int64) async -> Bool {
        do { return try await services.jobs.job(id: job)?.state.isActive == true } catch {
            Log.error(.ingest, "Could not read the job queue", ["error": error.localizedDescription])
            return false
        }
    }

    /// How long the worker waits when it has taken no job: while paused, until the doorbell rings, as resuming, and every
    /// change of the settings, rings it (`ArrumatorRuntime.setPaused`, `apply`), and while the archive is away, until it
    /// is told the archive is back (`archive(isAway:)`); while the Mac's power keeps it waiting, `power.recheckSeconds`;
    /// while the archive's folder is not there, or the queue cannot be read, as long as a job waits when a stage finds
    /// the folder gone (`ingest.retryDelays`, its last); while the last job waits for Ollama, until it is tried again
    /// (`ollamaRetryAt`); otherwise until the next job is due, or work given up on has had its time, and while another
    /// process holds a job, `ingest.heldElsewhereRecheckSeconds` at most (`IdleWait`).
    func idleWait(paused: Bool, power: Bool, archiveThere: Bool, queueUnread: Bool) async -> Double? {
        // Away, it waits to be told the archive is back (`archive(isAway:)`), which rings.
        if paused || archiveAway { return nil }
        if power { return services.config.power.recheckSeconds }
        if !archiveThere || queueUnread { return services.config.ingest.retryDelays.last }
        if let until = ollamaRetryAt, services.time.now() < until { return until.timeIntervalSince(services.time.now()) }
        let next = [await earliestDue(), nextOverdue].compactMap { $0 }.min()
        return IdleWait.seconds(untilDue: next, heldElsewhere: await heldElsewhere(),
                                recheck: services.config.ingest.heldElsewhereRecheckSeconds, now: services.time.now())
    }

    /// Whether `job`, about to be read for its text, waits instead, as it would only wait for Ollama too (QA 2026-10-05,
    /// RA-1): while Ollama is away, it waits in its place until the job that found Ollama away is tried again, and
    /// History says nothing of it. Only a job taken while Ollama is away comes here then (`JobStore.beforeTheModel`).
    func waitsForOllama(_ job: inout JobRecord, payload: inout JobPayload, trace: TraceContext) async throws -> Bool {
        guard let until = ollamaRetryAt else { return false }
        job.nextRunAt = until
        try await save(&job, &payload, state: job.state, trace: trace)
        return true
    }

    /// Ends `trace` saying how its job ended, or what it waits for.
    func finish(_ trace: TraceContext, _ outcome: JobOutcome, docID: Int64?) async {
        await services.traces.finish(trace, outcome: outcome.rawValue, docID: docID)
    }

    /// Whether another process holds jobs; a queue that cannot be read says nothing of it.
    private func heldElsewhere() async -> Bool {
        do { return try await services.jobs.heldElsewhere(claiming: services.claims) } catch {
            Log.error(.ingest, "Could not read the job queue", ["error": error.localizedDescription])
            return false
        }
    }
}
