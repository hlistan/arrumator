import Foundation

/// What a queue the model works through keeps of the item in hand: which it is, the search task it belongs to, the work
/// on it once that has begun, and why the user ended it, if the user did. Set before the item is taken from the queue,
/// so the user ending it while it is taken is never missed.
struct InHand {
    let item: Int64
    let task: Int64
    var work: Task<String, any Error>?
    var ended: Ending?

    init(item: Int64, task: Int64) {
        self.item = item
        self.task = task
    }
}

/// Why the user ended the work on an item in hand.
enum Ending: Sendable {
    /// Stopped as it was worked on: what came of it is kept, saying so.
    case stopped
    /// Changed or removed meanwhile: nothing of the work is kept, as the item is in the queue again, or gone.
    case superseded
}

/// How the work on an item in hand ended.
enum WorkOutcome {
    /// It ran to its end: the outcome its trace ends with.
    case done(String)
    /// The user ended it (`ModelQueue.end`).
    case ended(Ending)
    /// The queue stopped: the item stays in hand, and goes back into the queue in its place when the queue starts again.
    case interrupted
    /// Ollama is away (`PipelineServices.ollamaIsAway`, as ingest decides it): it could not be reached, or did not answer
    /// in time and does not answer a probe either. The item waits for it, spending nothing, however long it is away.
    case away(OllamaError)
    /// Anything else, a server that answers with a failure among it: the item fails with the reason.
    case failed(any Error)
}

/// The machinery the queues of search tasks (`SearchTaskQueue`) and of questions (`TaskConversationQueue`) share: a worker
/// that runs while the queue is started, takes the item due first, one at a time, and waits for the doorbell or the next
/// item's time between them; the item in hand, which the user can end while it is worked on; and how that work ended.
///
/// The app and each `arrumatorcli` command share the index, and each works through the same queues. An item in hand keeps
/// the process working on it (`ProcessTag`, the `worker` column), so before it looks for an item, a queue puts back in
/// their place the items its own process left in hand, as when it last stopped, and those of a process that has ended,
/// as a command killed part way leaves them; one another process works on is left to it. What the work keeps depends on
/// its process still holding the item, so a change the user made meanwhile, which puts the item back in the queue,
/// is never written over by a reading of what it was before. One queue of each kind works on an index in a process.
protocol ModelQueue: Actor {
    associatedtype Item: Sendable
    var services: PipelineServices { get }
    var processes: any ProcessWatching { get }
    var doorbell: Doorbell { get }
    var worker: Task<Void, Never>? { get set }
    var inHand: InHand? { get set }
    /// What the queue is called in the log.
    nonisolated var name: String { get }

    /// Puts back in the queue the items in hand that no running process works on (`ProcessWatching.hasLeft`); how many.
    func recoverLeft() async throws -> Int
    func nextDue() async throws -> Item?
    func earliestDue() async throws -> Date?
    /// Works on `item`; false when it could not be taken from the queue.
    func run(_ item: Item) async -> Bool
    /// Counts again the items waiting, and tells the status's subscribers.
    func recount() async
}

extension ModelQueue {
    /// The tag items this queue takes keep.
    var tag: String { processes.current.description }

    /// Starts the worker, unless it runs: the worker is claimed before anything is awaited, so a second start neither
    /// makes a second worker nor puts back in the queue what the first has in hand.
    func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.work() }
        doorbell.ring()
    }

    /// Stops the worker and waits until it has; false when it was not running. The item in hand goes back into the queue,
    /// in its place, once the worker has stopped, as nothing of this process works on it any more: whatever runtime next
    /// opens the index takes it up, as one does after an archive switch, rather than leaving it in hand until this
    /// process ends.
    func stopWorker() async -> Bool {
        guard let worker else { return false }
        worker.cancel()
        await worker.value
        // Put back before the worker is let go: a start meanwhile finds it still set and waits, so it never takes an item
        // this then puts back while it is being read.
        await putBackLeft()
        self.worker = nil
        return true
    }

    /// Works through every item that is due until none is left (the command line and tests), or until one cannot be
    /// taken from the queue, which is logged, or until the task that drains it is cancelled, as Ctrl-C cancels a command;
    /// the items no running process works on first go back into the queue.
    func drainQueue() async {
        await putBackLeft()
        while !Task.isCancelled, let item = await next(), await run(item) {}
    }

    /// Ends the work on the item in hand when `matches` says it is the one, because the user `ending` it: its work is
    /// cancelled, and the queue keeps of it what `ending` says. Whether it was in hand.
    func end(because ending: Ending, where matches: (InHand) -> Bool) -> Bool {
        guard var hand = inHand, matches(hand) else { return false }
        hand.ended = ending
        inHand = hand
        hand.work?.cancel()
        return true
    }

    /// Runs `body`, the work on the item in hand, as a task the user can end (`end`) and the queue's stop cancels, and
    /// says how it ended. An item the user ended before its work began is not worked on.
    func attempt(_ body: @escaping @Sendable () async throws -> String) async -> WorkOutcome {
        if let ended = inHand?.ended { return .ended(ended) }
        let work = Task { try await body() }
        inHand?.work = work
        do {
            return .done(try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() })
        } catch {
            if let ended = inHand?.ended { return .ended(ended) }
            if Cancellation.stops(error) { return .interrupted }
            if let error = error as? OllamaError, await services.ollamaIsAway(error) { return .away(error) }
            return .failed(error)
        }
    }

    /// Starts the trace of an attempt, taking up `previous` when that attempt ended waiting for Ollama
    /// (`TraceRecorder.start(_:resuming:)`); a trace that cannot be started is logged, and the work goes on untraced.
    func startTrace(_ header: TraceHeader, resuming previous: Int64?) async -> TraceContext {
        do { return try await services.traces.start(header, resuming: previous) } catch {
            // Stopped before it began: the work that follows sees the stop too, and nothing failed.
            guard !Cancellation.stops(error) else { return .disabled }
            Log.error(.db, "Could not start trace", ["error": error.localizedDescription])
            return .disabled
        }
    }

    /// When an item that waits for Ollama is tried again.
    var retryAt: Date { services.time.now().addingTimeInterval(services.config.ingest.retryDelays.last) }

    // MARK: The worker

    private func work() async {
        while !Task.isCancelled {
            await putBackLeft()
            if let item = await next() {
                if await run(item) { continue }
                // The queue could not be written; it is tried again after a while rather than at once.
                await doorbell.wait(timeout: services.config.ingest.retryDelays.last, time: services.time)
                continue
            }
            let wait = await earliest().map { max(IngestCoordinator.minimumWait, $0.timeIntervalSince(services.time.now())) }
            await doorbell.wait(timeout: wait, time: services.time)
        }
    }

    private func putBackLeft() async {
        do {
            let recovered = try await recoverLeft()
            guard recovered > 0 else { return }
            Log.info(.search, "Back in the queue", ["queue": name, "items": String(recovered)])
            await recount()
        } catch {
            // Stopped before it began: nothing was put back, and the next look does it.
            guard !Cancellation.stops(error) else { return }
            Log.error(.search, "Could not put back in the queue what was left in hand", ["queue": name, "error": error.localizedDescription])
        }
    }

    private func next() async -> Item? {
        do { return try await nextDue() } catch {
            guard !Cancellation.stops(error) else { return nil }
            Log.error(.search, "Could not read the queue", ["queue": name, "error": error.localizedDescription])
            return nil
        }
    }

    private func earliest() async -> Date? {
        do { return try await earliestDue() } catch {
            guard !Cancellation.stops(error) else { return nil }
            Log.error(.search, "Could not read the queue", ["queue": name, "error": error.localizedDescription])
            return nil
        }
    }
}

extension ProcessWatching {
    /// Whether no running process works on an item in hand that keeps `worker`: none is named, the name is none, it is
    /// this process, which has nothing in hand when it looks, or it is a process that has ended.
    func hasLeft(_ worker: String?) -> Bool {
        guard let worker, let tag = ProcessTag(worker) else { return true }
        return tag == current || !isRunning(tag)
    }
}
