import Foundation

/// Which jobs a command works through (`IngestCoordinator.drain`); the app and `arrumatorcli run` work through all of them.
public enum Draining: Sendable, Equatable {
    /// Those that come in their turn, as the files a command files or reads again, and never one that gives way
    /// (`JobRecord.givesWay`: reading documents again for search after a rebuild, or the whole archive at once), which
    /// may take hours, and which the app or `run` works through.
    case inTurn
    /// Those that give way too, as reading the whole archive again from a command asks (`review retry --all`), until the
    /// first that waits for Ollama, rather than take every job in turn while it is away, each waiting its
    /// `ollama.retryDelays`.
    case everything
}

/// How the worker waits when it has taken no job.
extension IngestCoordinator {
    /// How long the worker waits when it has taken no job: while paused, until the doorbell rings, as resuming, and every
    /// change of the settings, rings it (`ArrumatorRuntime.setPaused`, `apply`), and while the archive is away, until it
    /// is told the archive is back (`archive(isAway:)`); while the Mac's power keeps it waiting, `power.recheckSeconds`;
    /// while the archive's folder is not there, or the queue cannot be read, as long as a job waits when a stage finds
    /// the folder gone (`ingest.retryDelays`, its last); otherwise until the next job is due, or work given up on has had
    /// its time, and while another process holds a job, `ingest.heldElsewhereRecheckSeconds` at most (`IdleWait`).
    func idleWait(paused: Bool, power: Bool, archiveThere: Bool, queueUnread: Bool) async -> Double? {
        // Away, it waits to be told the archive is back (`archive(isAway:)`), which rings.
        if paused || archiveAway { return nil }
        if power { return services.config.power.recheckSeconds }
        if !archiveThere || queueUnread { return services.config.ingest.retryDelays.last }
        let next = [await earliestDue(), nextOverdue].compactMap { $0 }.min()
        return IdleWait.seconds(untilDue: next, heldElsewhere: await heldElsewhere(),
                                recheck: services.config.ingest.heldElsewhereRecheckSeconds, now: services.time.now())
    }

    /// Whether another process holds jobs; a queue that cannot be read says nothing of it.
    private func heldElsewhere() async -> Bool {
        do { return try await services.jobs.heldElsewhere(claiming: services.claims) } catch {
            Log.error(.ingest, "Could not read the job queue", ["error": error.localizedDescription])
            return false
        }
    }
}
