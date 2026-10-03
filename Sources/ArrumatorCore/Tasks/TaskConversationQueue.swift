import Foundation

/// What the conversation queue is doing, as the app shows it while a question waits or is answered
/// (`TaskConversationQueue.statusUpdates()`): live state, not a record. The answer as it is written is here until it is
/// kept with its question.
public struct ConversationQueueStatus: Sendable, Hashable {
    /// The question being answered now: whose task, by which model, since when on the queue's clock, and what has come
    /// of the answer so far.
    public struct Answering: Sendable, Hashable {
        public var task: Int64
        public var turn: Int64
        public var model: String
        public var since: Date
        public var progress: AnswerProgress
    }

    public var answering: Answering?
    /// Questions waiting to be answered, the one being answered not among them: those due and those waiting for Ollama.
    public var queued: Int
    /// Ollama could not be reached for the last answer: the questions waiting are tried again after the last of
    /// `ingest.retryDelays`. Until an answer reaches it, or nothing is left to answer.
    public var waitingForOllama: Bool
    /// When the question that found Ollama away is tried again, on the queue's clock; nil while nothing waits for it.
    public var retryAt: Date?

    public init(answering: Answering?, queued: Int, waitingForOllama: Bool, retryAt: Date? = nil) {
        self.answering = answering
        self.queued = queued
        self.waitingForOllama = waitingForOllama
        self.retryAt = retryAt
    }

    public static let idle = ConversationQueueStatus(answering: nil, queued: 0, waitingForOllama: false)

    /// Where `turn` is in the queue, as this status says; nil for a question no longer in it, answered or not, whatever a
    /// status not yet updated says.
    public func progress(of turn: TaskTurn) -> TurnProgress? {
        guard turn.state.isActive else { return nil }
        if let answering, answering.turn == turn.id {
            // Tried again while Ollama was away: it still waits for Ollama until the model begins.
            return waitingForOllama && !answering.progress.begun ? .waitingForOllama(until: nil) : .answering(answering)
        }
        if turn.state == .answering { return .answering(nil) }
        if waitingForOllama { return .waitingForOllama(until: retryAt) }
        return answering == nil ? .waiting : .waitingForTurn
    }

    /// The status without what has come of the answer so far: what a list of questions changes with, rather than with
    /// every word written.
    public var settled: ConversationQueueStatus {
        var settled = self
        settled.answering?.progress.text = ""
        return settled
    }
}

/// Where a question in the queue is (`ConversationQueueStatus.progress(of:)`), which the app shows with it.
public enum TurnProgress: Sendable, Hashable {
    /// It is being answered: by the model this queue names, since then, and what has come of it; nil when the question
    /// is stored as being answered but this queue does not answer it, as when the command line does.
    case answering(ConversationQueueStatus.Answering?)
    /// Next, as nothing is being answered.
    case waiting
    /// Behind the question being answered.
    case waitingForTurn
    /// Until Ollama can be reached: tried again at `until`, or being tried now when nil.
    case waitingForOllama(until: Date?)
}

/// Answers questions about search tasks' documents, one at a time, the first asked first, with the model of the task's
/// profile and at the task's effort (docs/how-it-works.md#talking-with-a-tasks-documents). Each answer is drawn from
/// the task's set as it is then (`TaskContextBuilder`) and streamed as it is written, on the status
/// (`statusUpdates()`), which the app follows. An answer that asks for more documents has its request read as a task's
/// request is, and the documents it finds outside the set are kept with the answer, to be added by the user.
///
/// A question survives a stop: one being answered goes back into the queue, in its place, and is answered first at the
/// next start; so does one a process that ended was answering (`ModelQueue`). While Ollama cannot be reached a question
/// waits in the queue, as a document does (`ingest.retryDelays`), its trace taken up again by each attempt; a profile
/// the settings no longer list, a model that is missing, a server that answers with a failure, an answer that took
/// longer than the task's effort allows, or one the model never got right, fails the question with the reason, keeping
/// what came of the answer, and the user can ask it again. The user can stop an answer as it is written (`stop(_:)`);
/// clearing the conversation, or removing its task, stops it too, keeping nothing (`forget(task:)`).
public actor TaskConversationQueue: ModelQueue {
    let services: PipelineServices
    let processes: any ProcessWatching
    private let answerer: any TaskQuestionAnswering
    private let interpreter: any SearchPromptInterpreting
    private let search: SearchService
    var worker: Task<Void, Never>?
    let doorbell = Doorbell()
    var inHand: InHand?
    nonisolated let name = "questions"
    private var statusContinuations: [UUID: AsyncStream<ConversationQueueStatus>.Continuation] = [:]
    public private(set) var status = ConversationQueueStatus.idle {
        didSet { if status != oldValue { for c in statusContinuations.values { c.yield(status) } } }
    }
    /// The counts of the questions waiting asked for so far, and the latest of them the status has (`publish`).
    private var countsAsked = 0
    private var countPublished = 0

    /// What a question the user stopped says.
    public static let stoppedProblem = "Stopped"

    public init(services: PipelineServices, answerer: any TaskQuestionAnswering, interpreter: any SearchPromptInterpreting,
                search: SearchService, processes: any ProcessWatching) {
        self.services = services
        self.answerer = answerer
        self.interpreter = interpreter
        self.search = search
        self.processes = processes
    }

    /// What the queue is doing, the current status first, then each change: a subscriber that joins while a question is
    /// answered is told so at once.
    public func statusUpdates() -> AsyncStream<ConversationQueueStatus> {
        let id = UUID()
        let (stream, c) = AsyncStream<ConversationQueueStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(status)
        statusContinuations[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.removeStatus(id) } }
        return stream
    }

    private func removeStatus(_ id: UUID) { statusContinuations[id] = nil }

    /// Counts again the questions waiting, makes `change` to the status, and publishes it at once. With nothing being
    /// answered and nothing waiting, the queue waits for nothing, Ollama included.
    private func publish(_ change: (inout ConversationQueueStatus) -> Void = { _ in }) async {
        countsAsked += 1
        let asked = countsAsked
        let queued: Int?
        do { queued = try await store.queuedCount() } catch {
            Log.error(.search, "Could not count the conversation queue", ["error": error.localizedDescription])
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
        if next.answering == nil, next.queued == 0 {
            next.waitingForOllama = false
            next.retryAt = nil
        }
        status = next
    }

    func recount() async { await publish() }

    private var store: TaskConversationStore { TaskConversationStore(database: services.database, time: services.time) }

    // MARK: Control

    /// Starts the worker, unless it runs (`ModelQueue.startWorker`), and counts the questions waiting.
    public func start() async {
        startWorker()
        await publish()
    }

    /// Stops the worker and waits until it has. A question being answered goes back into the queue, in its place, once
    /// it has; until the next start the queue answers nothing and waits for nothing.
    public func stop() async {
        guard await stopWorker() else { return }
        await publish {
            $0.answering = nil
            $0.waitingForOllama = false
            $0.retryAt = nil
        }
    }

    /// Tells the queue its questions changed: it looks for one that is due, and counts again those waiting.
    public func wake() async {
        doorbell.ring()
        await publish()
    }

    /// Answers every question that is due until none is left (the command line and tests), or until one cannot be taken
    /// from the queue, which is logged, or until the draining task is cancelled; first the questions no running process answers go back into the queue.
    public func drain() async {
        await drainQueue()
    }

    /// Stops answering `turn` if it is in hand, being taken from the queue or answered: what came of the answer is kept,
    /// saying it was stopped. Whether it was in hand.
    @discardableResult
    func stop(_ turn: Int64) -> Bool {
        end(because: .stopped) { $0.item == turn }
    }

    /// Stops answering a question of `task`, as when its conversation is cleared or the task removed: nothing of the
    /// answer is kept, as the question is gone.
    func forget(task: Int64) {
        _ = end(because: .superseded) { $0.task == task }
    }

    // MARK: The queue

    func recoverLeft() async throws -> Int { try await store.recoverLeft(processes) }
    func nextDue() async throws -> TaskTurnRecord? { try await store.nextDue() }
    func earliestDue() async throws -> Date? { try await store.earliestDue() }
    func heldElsewhere() async throws -> Bool { try await store.heldElsewhere(processes) }

    // MARK: A question

    /// Answers a queued question; false when it could not be taken from the queue. It is in hand from before it is
    /// taken, so the user stopping it meanwhile is never missed. Once it has run, the status says nothing is answered,
    /// and whether the queue waits for Ollama.
    func run(_ queued: TaskTurnRecord) async -> Bool {
        guard let id = queued.id else { return false }
        inHand = InHand(item: id, task: queued.taskId)
        defer { inHand = nil }
        let begun: (turn: TaskTurnRecord, task: SearchTaskRecord)
        do {
            // A question no longer queued, such as one whose conversation was cleared meanwhile, is simply not answered.
            guard let taken = try await store.begin(id, by: tag) else { return true }
            begun = taken
        } catch {
            Log.error(.search, "Could not start answering a question", ["turn": String(id), "error": error.localizedDescription])
            return false
        }
        let reached = await answer(begun.turn, task: begun.task, id: id)
        await publish {
            $0.answering = nil
            if let reached {
                $0.waitingForOllama = !reached
                if reached { $0.retryAt = nil }
            }
        }
        return true
    }

    /// Answers a question taken from the queue, with the status naming it, the model that answers it and what has come
    /// of the answer meanwhile, and keeps the answer or why there is none. Returns whether Ollama could be reached: nil
    /// when that was not learnt, as for a profile that is gone, which no model reads, or on stopping.
    private func answer(_ record: TaskTurnRecord, task: SearchTaskRecord, id: Int64) async -> Bool? {
        let store = store
        let tag = tag
        let settings = await services.settings.current
        // The profile that answers, the task's own or Settings'; one that is gone names no models, and fails the question.
        let profile = Result { try settings.modelProfile(task.profile) }
        let model = try? profile.get().chatModel
        if let model, let taskID = task.id {
            let since = services.time.now()
            await publish {
                $0.answering = ConversationQueueStatus.Answering(task: taskID, turn: id, model: model, since: since,
                                                                 progress: .notBegun)
            }
        }
        let trace = await startTrace(TraceHeader(docID: nil, jobID: nil, attempt: 0, source: .conversation,
                                                 promptVersion: services.config.conversation.promptVersion,
                                                 models: try? profile.get(), settings: settings), resuming: record.lastTraceId)
        let outcome: String
        let reached: Bool?
        switch await attempt({ try await self.respond(record, task: task, id: id, profile: try profile.get(), trace: trace) }) {
        case let .done(concluded):
            outcome = concluded
            reached = true
        case .ended(.stopped):
            outcome = Self.stopped
            reached = nil
            await keepFailed(id, by: tag, problem: Self.stoppedProblem, partial: written(id), model: model, trace: trace)
        case .ended(.superseded):
            // Its conversation was cleared, or its task removed: nothing is left to keep it with.
            outcome = SearchTaskQueue.superseded
            reached = nil
        case .interrupted:
            // Stopping the app interrupts the question; that is no failure, and the next start takes it up again.
            outcome = SearchTaskQueue.interrupted
            reached = nil
        case let .away(error):
            outcome = TraceRecorder.waitingOutcome
            reached = false
            let until = retryAt
            do { try await store.postpone(id, by: tag, until: until, trace: trace.traceID) } catch {
                Log.error(.search, "Could not put a question back in the queue", ["turn": String(id), "error": error.localizedDescription])
            }
            await publish { $0.retryAt = until }
            Log.warning(.search, "Ollama unavailable; the question waits", ["turn": String(id), "error": error.localizedDescription])
        case let .failed(error):
            outcome = TurnState.failed.rawValue
            // Ollama that answers with an error of its own, such as a model it does not have, can be reached.
            reached = error is OllamaError ? true : nil
            await keepFailed(id, by: tag, problem: error.localizedDescription, partial: written(id), model: model, trace: trace)
            Log.error(.search, "Question not answered", ["turn": String(id), "error": error.localizedDescription])
        }
        await services.traces.finish(trace, outcome: outcome, docID: nil)
        return reached
    }

    /// How the trace of an answer the user stopped ends.
    static let stopped = "stopped"

    /// What has come of the answer to `turn`, as the status brings it.
    private func written(_ turn: Int64) -> String? {
        status.answering?.turn == turn ? status.answering?.progress.text : nil
    }

    /// Records that the question was not answered, with what came of the answer.
    private func keepFailed(_ id: Int64, by tag: String, problem: String, partial: String?, model: String?, trace: TraceContext) async {
        do { try await store.fail(id, by: tag, problem: problem, partial: partial, model: model, trace: trace.traceID) } catch {
            Log.error(.search, "Could not record a question that was not answered", ["turn": String(id), "error": error.localizedDescription])
        }
    }

    /// Answers the question from the set as it is now, finds what it asks for outside the set if it asks, and keeps the
    /// answer; the outcome the trace ends with.
    private func respond(_ record: TaskTurnRecord, task: SearchTaskRecord, id: Int64, profile: ModelProfile,
                         trace: TraceContext) async throws -> String {
        guard let taskID = task.id else { return SearchTaskQueue.superseded }
        let members = try await services.database.reader.read { db in try SearchTaskStore.members(db, task: taskID) }
        let set = members.filter { $0.inclusion != .removed }.map(\.document)
        let earlier = try await store.turns(task: taskID).filter { $0.id < id }
        let builder = TaskContextBuilder(database: services.database, search: search, config: services.config)
        let chosen = try await trace.measure(.context, input: ContextInput(question: record.question, set: set.count),
                                             output: { ContextTrace($0) }) {
            try await builder.context(for: record.question, set: set, earlier: earlier)
        }
        let today = services.time.now().formatted(Date.ISO8601FormatStyle(timeZone: services.timeZone).year().month().day())
        let answer = try await answerer.answer(record.question, context: chosen.shown, effort: task.effort, profile: profile, today: today,
                                               config: services.config, trace: trace) { [weak self] progress in
            await self?.progressed(id, progress)
        }
        var finding: TurnFinding?
        if let request = answer.find {
            finding = try await find(request, task: task, members: Set(members.map(\.document)), profile: profile, today: today, trace: trace)
        }
        guard try await store.finish(id, by: tag, answer: answer, finding: finding, trace: trace.traceID) else {
            Log.info(.search, "A question was taken out of the queue while it was answered", ["turn": String(id)])
            return SearchTaskQueue.superseded
        }
        Log.info(.search, "Question answered", ["turn": String(id), "sources": String(answer.sources.count)])
        return TurnState.answered.rawValue
    }

    private func progressed(_ turn: Int64, _ progress: AnswerProgress) {
        guard status.answering?.turn == turn else { return }
        status.answering?.progress = progress
    }

    /// Reads `request` as a task's request is read, at the task's effort and by its profile, and finds the documents it
    /// asks for that are not in the set, nor taken out of it, the newest by their own date first, at most
    /// `conversation.maxSuggested`. A request that cannot be read says why, and so does Ollama going away meanwhile: the
    /// answer is kept all the same. Stopping is no failure, and the question is answered again.
    private func find(_ request: String, task: SearchTaskRecord, members: Set<Int64>, profile: ModelProfile, today: String,
                      trace: TraceContext) async throws -> TurnFinding {
        do {
            let vocabulary = try await services.labels.usage()
            let interpretation = try await interpreter.interpret(request, effort: task.effort, profile: profile, vocabulary: vocabulary,
                                                                 today: today, config: services.config, trace: trace)
            guard let plan = interpretation.plan else {
                return TurnFinding(request: request, plan: nil, documents: [], problem: interpretation.problem)
            }
            let matcher = SearchPlanMatcher(database: services.database, archive: services.archive,
                                            limit: services.config.tasks.maxDocuments)
            let found = try await trace.measure(.match, input: plan, output: { (ids: [Int64]) in ["documents": ids] }) {
                try await matcher.documents(plan)
            }
            let new = found.filter { !members.contains($0) }.prefix(services.config.conversation.maxSuggested)
            return TurnFinding(request: request, plan: plan, documents: Array(new), problem: nil)
        } catch {
            try Cancellation.rethrow(error)
            return TurnFinding(request: request, plan: nil, documents: [], problem: error.localizedDescription)
        }
    }
}

/// What choosing an answer's context is given: the question, and how many documents the set holds.
struct ContextInput: Encodable {
    var question: String
    var set: Int
}

/// What choosing an answer's context records: the documents shown with their text and by name, by number in the order
/// shown, how many were not shown at all, how much text was shown, how many earlier exchanges, and whether the question's
/// meaning ordered the documents as well as its words, or, when it did not, why.
struct ContextTrace: Encodable {
    var read: [Int64]
    var listed: [Int64]
    var unlisted: Int
    var characters: Int
    var exchanges: Int
    var semanticUsed: Bool
    var semanticUnavailableReason: String?

    init(_ chosen: TaskContextBuilder.ContextChoice) {
        let context = chosen.shown
        read = context.read.map(\.id)
        listed = context.listed.map(\.id)
        unlisted = context.unlisted
        characters = context.read.reduce(0) { $0 + ($1.text?.count ?? 0) }
        exchanges = context.conversation.count
        semanticUsed = chosen.semanticUsed
        semanticUnavailableReason = chosen.semanticUnavailableReason
    }
}
