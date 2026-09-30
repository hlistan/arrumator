import Foundation

/// Runs search tasks one at a time, the oldest first: the model reads each task's prompt into a plan
/// (`SearchPromptInterpreting`), the documents the plan asks for are found (`SearchPlanMatcher`), and the task keeps both,
/// ready to be looked over and exported. Each run is traced, and what it concluded is recorded in History.
///
/// A task survives a stop: one whose prompt was being read goes back into the queue at the next start. While Ollama
/// cannot be reached a task waits in the queue, as a document does (`ingest.retryDelays`); a model that is missing, or
/// an answer the model never got right, fails the task with the reason, and the user can ask again.
public actor SearchTaskQueue {
    private let services: PipelineServices
    private let interpreter: any SearchPromptInterpreting
    private var worker: Task<Void, Never>?
    private let kick: AsyncStream<Void>.Continuation
    private let kicks: AsyncStream<Void>

    public init(services: PipelineServices, interpreter: any SearchPromptInterpreting) {
        self.services = services
        self.interpreter = interpreter
        (kicks, kick) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
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
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.runLoop() }
        kick.yield()
    }

    /// Stops the worker and waits until it has. A task whose prompt is being read goes back into the queue at the next
    /// start.
    public func stop() async {
        guard let worker else { return }
        worker.cancel()
        await worker.value
        self.worker = nil
    }

    public func wake() { kick.yield() }

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
                await waitForKick(timeout: services.config.ingest.retryDelays.last)
                continue
            }
            let wait = await earliestDue().map { max(IngestCoordinator.minimumWait, $0.timeIntervalSince(services.time.now())) }
            await waitForKick(timeout: wait)
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

    // MARK: A task

    /// Runs a queued task; false when it could not be taken from the queue.
    private func run(_ queued: SearchTaskRecord) async -> Bool {
        guard let id = queued.id else { return false }
        let store = store
        let record: SearchTaskRecord
        do {
            // A task no longer queued, such as one removed meanwhile, is simply not run.
            guard let begun = try await store.begin(id) else { return true }
            record = begun
        } catch {
            Log.error(.search, "Could not start a search task", ["task": String(id), "error": error.localizedDescription])
            return false
        }
        let settings = await services.settings.current
        let trace: TraceContext
        do {
            trace = try await services.traces.start(TraceHeader(docID: nil, jobID: nil, attempt: 0, source: .task,
                                                                promptVersion: services.config.tasks.promptVersion,
                                                                models: try? services.config.models(for: settings.models),
                                                                settings: settings))
        } catch {
            Log.error(.db, "Could not start trace", ["error": error.localizedDescription])
            trace = .disabled
        }
        let outcome: String
        do {
            outcome = try await interpret(record, id: id, settings: settings, trace: trace)
        } catch let error as OllamaError where error.isTransient {
            // Stopping interrupts the task; that is no failure, and the next start takes it up again.
            guard !Task.isCancelled else { return true }
            outcome = "waiting"
            let until = services.time.now().addingTimeInterval(services.config.ingest.retryDelays.last)
            do { try await store.postpone(id, prompt: record.prompt, until: until) } catch {
                Log.error(.search, "Could not put a search task back in the queue", ["task": String(id), "error": error.localizedDescription])
            }
            Log.warning(.search, "Ollama unavailable; the search task waits", ["task": String(id), "error": error.localizedDescription])
        } catch {
            guard !Task.isCancelled else { return true }
            outcome = "failed"
            let failed = SearchInterpretation(plan: nil, model: nil, problem: error.localizedDescription)
            do { try await store.fail(id, prompt: record.prompt, interpretation: failed, trace: trace.traceID) } catch {
                Log.error(.search, "Could not record a failed search task", ["task": String(id), "error": error.localizedDescription])
            }
            Log.error(.search, "Search task failed", ["task": String(id), "error": error.localizedDescription])
        }
        await services.traces.finish(trace, outcome: outcome, docID: nil)
        return true
    }

    /// Reads the task's prompt and keeps what it found, or why it found nothing; the outcome the trace ends with.
    private func interpret(_ record: SearchTaskRecord, id: Int64, settings: AppSettings, trace: TraceContext) async throws -> String {
        let vocabulary = try await services.labels.usage()
        let today = services.time.now().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let interpretation = try await interpreter.interpret(record.prompt, vocabulary: vocabulary, today: today, settings: settings,
                                                             config: services.config, trace: trace)
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
