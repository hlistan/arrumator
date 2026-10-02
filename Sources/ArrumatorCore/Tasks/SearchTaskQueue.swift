import Foundation

/// What the search task queue is doing, as the app shows it while a request waits or is read
/// (`SearchTaskQueue.statusUpdates()`): live state, not a record. History keeps what each reading concluded, not that
/// one began.
public struct SearchTaskQueueStatus: Sendable, Hashable {
    /// The request being read now: whose task, by which model, and since when, on the queue's clock.
    public struct Reading: Sendable, Hashable {
        public var task: Int64
        public var model: String
        public var since: Date
    }

    public var reading: Reading?
    /// Tasks in the queue waiting to be read, the one being read not among them: those due and those waiting for Ollama.
    public var queued: Int
    /// Ollama could not be reached for the last reading: the tasks waiting are tried again after the last of
    /// `ingest.retryDelays`. Until a reading reaches it, or nothing is left to read.
    public var waitingForOllama: Bool

    public static let idle = SearchTaskQueueStatus(reading: nil, queued: 0, waitingForOllama: false)

    /// Where `task` is in the queue, as this status says; nil for a task no longer in it, ready or failed, whatever a
    /// status not yet updated says.
    public func progress(of task: SearchTask) -> SearchTaskProgress? {
        guard task.state.isActive else { return nil }
        if let reading, reading.task == task.id { return .reading(reading) }
        if task.state == .interpreting { return .reading(nil) }
        if waitingForOllama { return .waitingForOllama }
        return reading == nil ? .waiting : .waitingForTurn
    }
}

/// Where a task in the queue is (`SearchTaskQueueStatus.progress(of:)`), which the app shows on its row and its card.
public enum SearchTaskProgress: Sendable, Hashable {
    /// Its request is being read: by the model this queue names, since then; nil when the task is stored as being read
    /// but this queue does not read it, as when the command line does.
    case reading(SearchTaskQueueStatus.Reading?)
    /// Waiting until Ollama can be reached again.
    case waitingForOllama
    /// Waiting while another task's request is read first.
    case waitingForTurn
    /// Waiting to be read, next.
    case waiting

    /// Whether its request is being read, by this queue or elsewhere.
    public var isReading: Bool {
        switch self {
        case .reading: true
        case .waitingForOllama, .waitingForTurn, .waiting: false
        }
    }
}

/// Runs search tasks one at a time, the oldest first: the model reads each task's prompt into a plan
/// (`SearchPromptInterpreting`), with the task's effort and by its own model profile, else by the one Settings uses then,
/// the documents the plan asks for are found (`SearchPlanMatcher`), and the task keeps both, ready to be looked over and
/// exported. Each run is traced, stamped with the models of the profile that reads it, and what it concluded is
/// recorded in History. What the queue is doing meanwhile, which task it reads and by which model, how many wait, and
/// whether it waits for Ollama, is its status (`statusUpdates()`), which the app follows.
///
/// A task survives a stop: one whose prompt was being read goes back into the queue, in its place, and is read first at
/// the next start. While Ollama cannot be reached a task waits in the queue, as a document does (`ingest.retryDelays`);
/// a profile the settings no longer list, a model that is missing, an answer that took longer than the task's effort
/// allows, or one the model never got right, fails the task with the reason, and the user can give it another profile
/// or effort or ask again. No other profile reads a task in its place unasked.
public actor SearchTaskQueue {
    private let services: PipelineServices
    private let interpreter: any SearchPromptInterpreting
    private var worker: Task<Void, Never>?
    private let doorbell = Doorbell()
    private var statusContinuations: [UUID: AsyncStream<SearchTaskQueueStatus>.Continuation] = [:]
    public private(set) var status = SearchTaskQueueStatus.idle {
        didSet { if status != oldValue { for c in statusContinuations.values { c.yield(status) } } }
    }
    /// The counts of the tasks waiting asked for so far, and the latest of them the status has (`publish`).
    private var countsAsked = 0
    private var countPublished = 0

    public init(services: PipelineServices, interpreter: any SearchPromptInterpreting) {
        self.services = services
        self.interpreter = interpreter
    }

    /// What the queue is doing, the current status first, then each change: a subscriber that joins while a request is
    /// read is told so at once.
    public func statusUpdates() -> AsyncStream<SearchTaskQueueStatus> {
        let id = UUID()
        let (stream, c) = AsyncStream<SearchTaskQueueStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(status)
        statusContinuations[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.removeStatus(id) } }
        return stream
    }

    private func removeStatus(_ id: UUID) { statusContinuations[id] = nil }

    /// Counts again the tasks waiting, makes `change` to the status, and publishes it at once. With nothing being read
    /// and nothing waiting, the queue waits for nothing, Ollama included.
    private func publish(_ change: (inout SearchTaskQueueStatus) -> Void = { _ in }) async {
        countsAsked += 1
        let asked = countsAsked
        let queued: Int?
        do { queued = try await store.queuedCount() } catch {
            Log.error(.search, "Could not count the search task queue", ["error": error.localizedDescription])
            queued = nil
        }
        // Changed only now, after the count was awaited, so a change published meanwhile is not undone, nor a count
        // asked for later, which saw the queue later, replaced by this one.
        var next = status
        change(&next)
        if let queued, asked > countPublished {
            next.queued = queued
            countPublished = asked
        }
        if next.reading == nil, next.queued == 0 { next.waitingForOllama = false }
        status = next
    }

    private var store: SearchTaskStore { SearchTaskStore(database: services.database, config: services.config.tasks, time: services.time) }

    // MARK: Control

    public func start() async {
        do {
            let recovered = try await store.recoverInterrupted()
            if recovered > 0 { Log.info(.search, "Search tasks back in the queue", ["tasks": String(recovered)]) }
        } catch {
            Log.error(.search, "Could not recover search tasks", ["error": error.localizedDescription])
        }
        await publish()
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.runLoop() }
        doorbell.ring()
    }

    /// Stops the worker and waits until it has. A task whose prompt is being read goes back into the queue at the next
    /// start; until then the queue reads nothing and waits for nothing.
    public func stop() async {
        guard let worker else { return }
        worker.cancel()
        await worker.value
        self.worker = nil
        await publish {
            $0.reading = nil
            $0.waitingForOllama = false
        }
    }

    /// Tells the queue its tasks changed: it looks for one that is due, and counts again those waiting.
    public func wake() async {
        doorbell.ring()
        await publish()
    }

    /// Runs every task that is due until none is left (the command line and tests), or until one cannot be taken from
    /// the queue, which is logged.
    public func drain() async {
        while let task = await nextDue(), await run(task) {}
    }

    // MARK: Loop

    private func runLoop() async {
        while !Task.isCancelled {
            if let task = await nextDue() {
                if await run(task) { continue }
                // The queue could not be written; it is tried again after a while rather than at once.
                await doorbell.wait(timeout: services.config.ingest.retryDelays.last, time: services.time)
                continue
            }
            let wait = await earliestDue().map { max(IngestCoordinator.minimumWait, $0.timeIntervalSince(services.time.now())) }
            await doorbell.wait(timeout: wait, time: services.time)
        }
    }

    private func nextDue() async -> SearchTaskRecord? {
        do { return try await store.nextDue() } catch {
            Log.error(.search, "Could not read the search task queue", ["error": error.localizedDescription])
            return nil
        }
    }

    private func earliestDue() async -> Date? {
        do { return try await store.earliestDue() } catch {
            Log.error(.search, "Could not read the search task queue", ["error": error.localizedDescription])
            return nil
        }
    }

    // MARK: A task

    /// Runs a queued task; false when it could not be taken from the queue. Once it has run, the status says nothing is
    /// read, and whether the queue waits for Ollama.
    private func run(_ queued: SearchTaskRecord) async -> Bool {
        guard let id = queued.id else { return false }
        let record: SearchTaskRecord
        do {
            // A task no longer queued, such as one removed meanwhile, is simply not run.
            guard let begun = try await store.begin(id) else { return true }
            record = begun
        } catch {
            Log.error(.search, "Could not start a search task", ["task": String(id), "error": error.localizedDescription])
            return false
        }
        let reached = await read(record, id: id)
        await publish {
            $0.reading = nil
            if let reached { $0.waitingForOllama = !reached }
        }
        return true
    }

    /// Reads a task taken from the queue, with the status naming it and the model that reads it meanwhile, and keeps
    /// what the reading concluded. Returns whether Ollama could be reached: nil when that was not learnt, as for a
    /// profile that is gone, which no model reads, or on stopping.
    private func read(_ record: SearchTaskRecord, id: Int64) async -> Bool? {
        let store = store
        let settings = await services.settings.current
        // The profile that reads the task, its own or Settings'; one that is gone names no models, and fails the task.
        let profile = Result { try settings.modelProfile(record.profile) }
        if let model = try? profile.get().chatModel {
            let since = services.time.now()
            await publish { $0.reading = SearchTaskQueueStatus.Reading(task: id, model: model, since: since) }
        }
        let trace: TraceContext
        do {
            trace = try await services.traces.start(TraceHeader(docID: nil, jobID: nil, attempt: 0, source: .task,
                                                                promptVersion: services.config.tasks.promptVersion,
                                                                models: try? profile.get(), settings: settings))
        } catch {
            Log.error(.db, "Could not start trace", ["error": error.localizedDescription])
            trace = .disabled
        }
        let outcome: String
        let reached: Bool?
        do {
            outcome = try await interpret(record, id: id, profile: try profile.get(), trace: trace)
            reached = true
        } catch let error as OllamaError where error.isTransient {
            // Stopping interrupts the task; that is no failure, and the next start takes it up again.
            guard !Task.isCancelled else { return nil }
            outcome = "waiting"
            reached = false
            let until = services.time.now().addingTimeInterval(services.config.ingest.retryDelays.last)
            do { try await store.postpone(id, prompt: record.prompt, until: until) } catch {
                Log.error(.search, "Could not put a search task back in the queue", ["task": String(id), "error": error.localizedDescription])
            }
            Log.warning(.search, "Ollama unavailable; the search task waits", ["task": String(id), "error": error.localizedDescription])
        } catch {
            guard !Task.isCancelled else { return nil }
            outcome = "failed"
            // Ollama that answers with an error of its own, such as a model it does not have, can be reached.
            reached = error is OllamaError ? true : nil
            let failed = SearchInterpretation(plan: nil, model: nil, problem: error.localizedDescription)
            do { try await store.fail(id, prompt: record.prompt, interpretation: failed, trace: trace.traceID) } catch {
                Log.error(.search, "Could not record a failed search task", ["task": String(id), "error": error.localizedDescription])
            }
            Log.error(.search, "Search task failed", ["task": String(id), "error": error.localizedDescription])
        }
        await services.traces.finish(trace, outcome: outcome, docID: nil)
        return reached
    }

    /// Reads the task's prompt and keeps what it found, or why it found nothing; the outcome the trace ends with.
    private func interpret(_ record: SearchTaskRecord, id: Int64, profile: ModelProfile, trace: TraceContext) async throws -> String {
        let vocabulary = try await services.labels.usage()
        let today = services.time.now().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let interpretation = try await interpreter.interpret(record.prompt, effort: record.effort, profile: profile, vocabulary: vocabulary,
                                                             today: today, config: services.config, trace: trace)
        guard let plan = interpretation.plan else {
            try await store.fail(id, prompt: record.prompt, interpretation: interpretation, trace: trace.traceID)
            Log.warning(.search, "The model could not read a search task", ["task": String(id)])
            return SearchTaskState.failed.rawValue
        }
        let matcher = SearchPlanMatcher(database: services.database, limit: services.config.tasks.maxDocuments)
        let found = try await trace.measure(.match, input: plan, output: { (ids: [Int64]) in ["documents": ids] }) {
            try await matcher.documents(plan)
        }
        guard try await store.prepare(id, prompt: record.prompt, interpretation: interpretation, plan: plan, found: found,
                                      trace: trace.traceID) else {
            Log.info(.search, "A search task changed while it was read; it is read again", ["task": String(id)])
            return "superseded"
        }
        Log.info(.search, "Search task ready", ["task": String(id), "documents": String(found.count)])
        return SearchTaskState.ready.rawValue
    }
}
