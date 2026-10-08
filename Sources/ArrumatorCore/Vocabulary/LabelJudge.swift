import Foundation

/// Keeps the archive's labels one vocabulary without asking the user: each pair of labels that look alike
/// (`LabelStore.suggestions()`), the most alike first, is judged by the model (`LabelPairJudging`), and what it judged is
/// done at once (`LabelActions.decide`): the same, they are merged into the one more documents have; different, they are
/// kept apart, so the pair is never judged again. Each is recorded in History as the system's, with the trace of the
/// judgement, and is a rule the user can forget under What You Decided.
///
/// The worker runs while the runtime's work runs, one pair at a time, and waits for its doorbell, which the runtime rings
/// at every change recorded in History (`wake()`), the ingest queue at each of its changes and the settings at each of
/// theirs, as a pause ended from another process reaches the app after what it recorded in History, between pairs when
/// there is none to judge. It judges nothing while the
/// user has paused Arrumator, nor while the Mac's power keeps the queues waiting (`PowerState.pauseReason`), looked at
/// again after `power.recheckSeconds`, nor while files wait to be filed, to which it gives way, as it is work for the
/// whole archive (AGENTS.md §3, a queue's order). Ollama away, or the profile's model missing, the pair waits, as an item
/// of a queue does: under one trace its next attempt takes up (`TraceRecorder.start(_:resuming:)`), looked at again after
/// `ingest.retryDelays.last` seconds, or `ingest.modelRecheckSeconds` for a model. A pair is the same whichever of its
/// labels more documents have (`LabelSuggestion.pairID`), as that may turn while it waits; one decided meanwhile, so that
/// `decide` would no longer act on it (`LabelActions.isUndecided`), has its trace ended so, and one still waiting at a
/// stop has it ended as stopped. A pair the model gives no valid answer for, or that fails otherwise, is not asked again
/// until the next start, and is left out before the pairs are cut to their limit, so no pair holds up the rest.
public actor LabelJudge {
    public let services: PipelineServices
    public let judging: any LabelPairJudging
    nonisolated let doorbell = Doorbell()
    private var worker: Task<Void, Never>?
    /// Rings the doorbell at each change of the ingest queue, as a file filed ends its job without a change to History,
    /// and of the settings.
    private var follower: Task<Void, Never>?
    /// Pairs the model gave no valid answer for, or whose judging failed, by `LabelSuggestion.pairID`, which this run
    /// asks no more. One whose judgement a rule made meanwhile leaves unacted on is no longer among the pairs to judge.
    private var setAside: Set<String> = []
    /// Until when no pair is judged, as the last judging found Ollama away or its model missing.
    private var ollamaUntil: Date?
    /// The traces pairs left waiting for Ollama, by `LabelSuggestion.pairID`, each taken up only by its own pair's next
    /// attempt.
    private var left: [String: (pair: LabelSuggestion, trace: Int64)] = [:]

    public init(services: PipelineServices, judging: any LabelPairJudging) {
        self.services = services
        self.judging = judging
    }

    /// Starts the worker, which looks again at each change of `queue`, so once the files it gave way to are filed, it
    /// judges, and at each change of the settings, so once a pause is over, it judges; the pairs set aside are asked
    /// again. A second start does nothing.
    public func start(following queue: IngestCoordinator) async {
        await start { await queue.statusUpdates() }
    }

    /// `start(following:)`, following the queue's changes `statuses` gives. The worker is claimed before anything is
    /// awaited, so a second start, while the first subscribes, does nothing; the queue's status, given at once, has it
    /// look again once it follows the queue.
    func start(followingStatuses statuses: @escaping @Sendable () async -> AsyncStream<IngestStatus>) async {
        guard worker == nil else { return }
        setAside = []
        let run = Task { await self.run() }
        worker = run
        let (changes, settings) = (await statuses(), await services.settings.changes())
        // Stopped while it subscribed: there is no worker left to wake.
        guard worker == run, !run.isCancelled else { return }
        follower = Task { [doorbell] in
            await withDiscardingTaskGroup { group in
                group.addTask { for await _ in changes { doorbell.ring() } }
                group.addTask { for await _ in settings { doorbell.ring() } }
            }
        }
    }

    /// Stops the worker and waits until it has: a pair being judged is judged again at the next start, as nothing of it
    /// was done, and the trace of one that waited for Ollama ends as stopped, the next start judging it under one of its
    /// own.
    public func stop() async {
        follower?.cancel()
        worker?.cancel()
        await follower?.value
        await worker?.value
        (follower, worker) = (nil, nil)
        for waited in left.values {
            await services.traces.finish(TraceContext(traceID: waited.trace, sink: services.traces), outcome: Self.stoppedOutcome, docID: nil)
        }
        (left, ollamaUntil) = ([:], nil)
    }

    /// Something changed that may give a pair to judge, or let one be judged: a label, a rule, a file filed, a setting.
    public nonisolated func wake() { doorbell.ring() }

    /// What looking for a pair came to.
    enum Look: Equatable {
        /// A pair was judged, or tried: look for the next at once.
        case judged
        /// Nothing to judge now: wait for the doorbell, or at most this many seconds.
        case idle(Double?)
    }

    private func run() async {
        while !Task.isCancelled {
            let look = await judgeNext()
            if look == .judged { continue }
            if case let .idle(timeout) = look { await doorbell.wait(timeout: timeout, time: services.time) }
        }
    }

    /// Judges the first pair that waits, unless the user paused Arrumator, the Mac's power keeps the queues waiting,
    /// files wait to be filed, or Ollama is waited for.
    func judgeNext() async -> Look {
        let settings = await services.settings.current
        guard !settings.paused else { return .idle(nil) }
        guard services.power().pauseReason(settings: settings, config: services.config.power) == nil else {
            return .idle(services.config.power.recheckSeconds)
        }
        if let ollamaUntil {
            let wait = ollamaUntil.timeIntervalSince(services.time.now())
            if wait > 0 { return .idle(wait) }
        }
        let pair: LabelSuggestion
        do {
            guard try await services.jobs.counts().queued == 0 else { return .idle(nil) }
            try await endDecided()
            guard let first = try await services.labels.suggestions(settingAside: setAside).first else { return .idle(nil) }
            pair = first
        } catch {
            guard !(error is CancellationError || Task.isCancelled) else { return .idle(nil) }
            Log.error(.db, "Could not read which labels look alike", ["error": error.localizedDescription])
            return .idle(services.config.ingest.retryDelays.last)
        }
        return await judge(pair, settings: settings)
    }

    /// Ends the traces of pairs that waited for Ollama and were decided meanwhile: `decide` would no longer act on them.
    private func endDecided() async throws {
        let actions = LabelActions(database: services.database, time: services.time)
        for (key, waited) in left {
            guard try await !actions.isUndecided(waited.pair) else { continue }
            left[key] = nil
            await services.traces.finish(TraceContext(traceID: waited.trace, sink: services.traces), outcome: Self.decidedMeanwhileOutcome,
                                         docID: nil)
        }
    }

    private func judge(_ pair: LabelSuggestion, settings: AppSettings) async -> Look {
        var trace = TraceContext.disabled
        do {
            ollamaUntil = nil
            trace = try await services.startTrace(docID: nil, jobID: nil, attempt: 1, source: .labels, settings: settings,
                                                  resuming: left[pair.pairID]?.trace)
            left[pair.pairID] = nil
            let use = try await services.labels.use(of: pair, names: services.config.labels.vocabulary.judgeDocuments)
            let verdict = try await judging.judge(pair, use: use, profile: try settings.modelProfile(), config: services.config, trace: trace)
            guard let judgement = verdict.judgement else {
                setAside.insert(pair.pairID)
                await services.traces.finish(trace, outcome: Self.unansweredOutcome, docID: nil)
                return .judged
            }
            let done = try await LabelActions(database: services.database, time: services.time).decide(pair, judgement, trace: trace.traceID)
            await services.traces.finish(trace, outcome: done == nil ? Self.decidedMeanwhileOutcome : judgement.rawValue, docID: nil)
            return .judged
        } catch {
            return await failed(pair, trace: trace, error: error)
        }
    }

    /// What a failure to judge `pair` does: a stop leaves it for the next start; Ollama away or the model missing makes it
    /// wait, its trace left to be taken up; anything else sets it aside for this run.
    private func failed(_ pair: LabelSuggestion, trace: TraceContext, error: any Error) async -> Look {
        if Cancellation.stops(error) || Task.isCancelled {
            await services.traces.finish(trace, outcome: Self.stoppedOutcome, docID: nil)
            return .idle(nil)
        }
        let config = services.config.ingest
        let wait: Double? = if case OllamaError.modelNotFound = error { config.modelRecheckSeconds } else if await services.ollamaIsAway(error) {
            config.retryDelays.last
        } else { nil }
        if let wait {
            await services.traces.finish(trace, outcome: TraceRecorder.waitingOutcome, docID: nil)
            ollamaUntil = services.time.now().addingTimeInterval(wait)
            if let id = trace.traceID { left[pair.pairID] = (pair, id) }
            Log.info(.classify, "Labels that look alike wait for Ollama", ["error": error.localizedDescription])
            return .idle(wait)
        }
        setAside.insert(pair.pairID)
        await services.traces.finish(trace, outcome: Self.failedOutcome, docID: nil)
        Log.error(.classify, "Could not judge two labels that look alike", ["kind": pair.kind.rawValue, "error": error.localizedDescription])
        return .judged
    }

    /// How a judgement's trace ends, beside the judgement acted on (`LabelJudgement`'s raw value) and a wait for Ollama.
    static let unansweredOutcome = "unanswered"
    static let decidedMeanwhileOutcome = "decided-meanwhile"
    static let stoppedOutcome = "stopped"
    static let failedOutcome = "failed"
}
