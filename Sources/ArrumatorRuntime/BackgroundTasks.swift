import Foundation

/// Whether the runtime's work runs, as the app shows it (`ArrumatorRuntime.workUpdates()`).
public enum RuntimeWork: Sendable, Equatable {
    /// Nothing runs: the runtime has not been started, its archive is being read first, or it stopped.
    case idle
    /// The work runs: the watchers, the queues, the record files' writer and maintenance.
    case running
    /// Nothing runs, as the index is not rebuilt from its archive, as when a record file that cannot be read refused
    /// its rebuild, until it is (`ArrumatorRuntime.rebuildIndex()`).
    case refused
    /// The archive's folder is not there, as on a disk not connected: the archive is away. Nothing is filed into it or
    /// written into its record files, and Incoming waits; once the same folder is back, the work goes on by itself.
    case away
}

/// The runtime's background work: the step that starts it, the named tasks that step starts, and whether the runtime
/// stopped. A runtime runs once: once stopped, nothing starts again, and a step begun before the stop starts nothing
/// more after it (`ArrumatorRuntime.start()`, `stop()`). A switch of archives stops it so that, if the switch fails, it
/// can start again (`reopen()`), unless it was meanwhile stopped for good.
actor BackgroundTasks {
    /// Nothing starts: while the runtime stops, and after it stopped.
    private var closed = false
    private var stoppedForGood = false
    /// Whether the step that starts the runtime reads the archive first, and whether it has.
    private var stepReads = false
    private var wasRead = false
    private var step: Task<Void, any Error>?
    /// The last step let go of itself, as its index was not rebuilt from its archive (`refused(as:)`).
    private(set) var startWasRefused = false
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Whether the work runs, and those told of every change to it.
    private var work = RuntimeWork.idle
    /// Whether the step that starts the runtime began the work.
    private var running = false
    private var workFollowers: [UUID: AsyncStream<RuntimeWork>.Continuation] = [:]

    /// The step that starts the runtime: `body`, begun now, the first time; the same step after that, until the runtime
    /// is stopped; nil while it is.
    func starting(reading: Bool, _ body: @escaping @Sendable () async throws -> Void) -> Task<Void, any Error>? {
        guard !closed else { return nil }
        if let step { return step }
        let begun = Task { try await body() }
        step = begun
        stepReads = reading
        wasRead = false
        startWasRefused = false
        set(.idle)
        return begun
    }

    /// The step that starts the runtime started nothing, as the index is not rebuilt, or the archive is away (`work`):
    /// it is let go, so the next start begins one of its own. Called from within that step, which is the runtime's only
    /// one until a stop, after which it is cancelled and nothing is let go.
    func refused(as work: RuntimeWork) {
        guard !closed else { return }
        step = nil
        stepReads = false
        wasRead = false
        startWasRefused = true
        set(work)
    }

    /// The step that starts the runtime started the work. Called from within that step, after a stop of which nothing
    /// it started runs.
    func began() {
        guard !closed else { return }
        running = true
        set(.running)
    }

    /// The archive's folder is not there (`away`), or is back: the work, or the start, waits while it is away, and goes
    /// on as it was once it is back.
    func away(_ isAway: Bool) {
        guard !closed else { return }
        if isAway {
            set(.away)
        } else if work == .away {
            set(running ? .running : .idle)
        }
    }

    /// Whether the work runs, as begun by a step, and the runtime is not stopped.
    var isWorking: Bool { running && !closed }

    /// Whether the work is started: a step began it and was not let go, and the runtime is not stopped.
    var isStarted: Bool { !closed && step != nil }

    /// Whether the work runs now, then each time that changes, for as long as the stream is read.
    func workUpdates() -> AsyncStream<RuntimeWork> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RuntimeWork>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(work)
        workFollowers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.forget(id) } }
        return stream
    }

    private func forget(_ id: UUID) { workFollowers[id] = nil }

    private func set(_ work: RuntimeWork) {
        guard work != self.work else { return }
        self.work = work
        for follower in workFollowers.values { follower.yield(work) }
    }

    /// The step that starts the runtime has read the archive.
    func opened() { wasRead = true }

    /// Runs `body` as the task named `name`, unless the runtime is stopped.
    func run(_ name: String, _ body: @escaping @Sendable () async -> Void) {
        guard !closed else { return }
        tasks[name]?.cancel()
        tasks[name] = Task(priority: .utility) { await body() }
    }

    /// The tasks begun by `joining(_:_:)` that have not ended.
    private var underWay: Set<String> = []

    /// The task named `name` under way, or `body` begun as it, unless the runtime is stopped: asked for again while it
    /// runs, it is joined, never begun beside it or cancelled for a new one, as a button pressed twice asks
    /// (`ArrumatorRuntime.startOllama()`). A stop cancels it and waits for it, as every task (`close`, `ended()`).
    func joining(_ name: String, _ body: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        guard !closed else { return nil }
        if underWay.contains(name), let task = tasks[name] { return task }
        underWay.insert(name)
        let task = Task(priority: .userInitiated) { [weak self] in
            await body()
            await self?.joinedEnded(name)
        }
        tasks[name] = task
        return task
    }

    private func joinedEnded(_ name: String) { underWay.remove(name) }

    /// Stops, for good or until `reopen()`: cancels the step that starts the runtime, which is given back for the caller
    /// to wait for, with what was under way, and every task, which `ended()` waits for. A second stop meanwhile, as when
    /// the app quits while it switches archives, is given the same step, and waits for it too.
    func close(forGood: Bool) -> (starting: Task<Void, any Error>?, halted: ArrumatorRuntime.Halted) {
        closed = true
        if forGood { stoppedForGood = true }
        step?.cancel()
        for task in tasks.values { task.cancel() }
        running = false
        set(.idle)
        return (step, ArrumatorRuntime.Halted(started: step != nil, unread: stepReads && !wasRead))
    }

    /// Lets the runtime start again, with a step of its own, after a stop that was not for good; whether it may.
    func reopen() -> Bool {
        guard !stoppedForGood else { return false }
        closed = false
        step = nil
        return true
    }

    /// Keeps the runtime stopped for good, as after a switch that was made.
    func closeForGood() {
        closed = true
        stoppedForGood = true
    }

    /// Waits until every task `close(forGood:)` cancelled has ended, such as the settings being applied, which would
    /// otherwise start a watcher after the runtime stopped.
    func ended() async {
        while let (name, task) = tasks.first.map({ ($0.key, $0.value) }) {
            awaiting = name
            await task.value
            tasks[name] = nil
        }
        awaiting = nil
    }

    /// The task `ended()` waits for, while it waits: what a test watches for before it lets that task end.
    private(set) var awaiting: String?
}
