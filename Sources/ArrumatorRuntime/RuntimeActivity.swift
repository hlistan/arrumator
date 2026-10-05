import ArrumatorCore
import Foundation

/// What the app shows of what a runtime is doing, worked out in one place from what its streams publish: why nothing is
/// filed, what is happening now, what the search tasks are at work on, and how the menu bar's icon marks it. Each answer
/// is the first of an order that applies, which the app only words and draws.
public struct RuntimeActivity: Sendable, Equatable {
    /// Whether the user has set the app up (`AppSettings.onboardingCompleted`): before that, nothing runs.
    public var onboarded: Bool
    public var paused: Bool
    public var work: RuntimeWork
    public var ingest: IngestStatus
    public var taskQueue: SearchTaskQueueStatus
    public var conversation: ConversationQueueStatus
    public var ollama: OllamaState
    /// How many documents wait for the user.
    public var needsYou: Int
    /// The record files History last said cannot be read, by their paths (`ArchiveRecords.unreadableRecorded`).
    public var unreadableRecords: [String]

    public init(onboarded: Bool, paused: Bool, work: RuntimeWork, ingest: IngestStatus, taskQueue: SearchTaskQueueStatus,
                conversation: ConversationQueueStatus, ollama: OllamaState, needsYou: Int, unreadableRecords: [String]) {
        self.onboarded = onboarded
        self.paused = paused
        self.work = work
        self.ingest = ingest
        self.taskQueue = taskQueue
        self.conversation = conversation
        self.ollama = ollama
        self.needsYou = needsYou
        self.unreadableRecords = unreadableRecords
    }

    /// Why nothing is filed now.
    public enum Holdup: Sendable, Equatable {
        /// The app is not set up (`AppSettings.onboardingCompleted`): nothing is watched or filed until it is.
        case notSetUp
        /// The work has not started: macOS may hold the folders behind its prompt for access.
        case waitingForFolders
        /// The index is not rebuilt from its archive (`RuntimeWork.refused`).
        case archiveNotRead
        /// The archive's folder is not there, as on a disk not connected (`RuntimeWork.away`).
        case archiveAway
        case paused
        /// Paused for the power source, saying why (`IngestStatus.powerPauseReason`).
        case power(String)
        /// Ollama is not ready, or the last document found it away.
        case ollama(OllamaState)
    }

    /// Why nothing is filed now, the first that applies: the app not set up, the work not running, filing paused, a
    /// pause for the power source, Ollama; nil while filing goes on.
    public var holdup: Holdup? {
        if let held = heldBeforeOllama { return held }
        if ingest.waitingForOllama || !ollama.isReady { return .ollama(ollama) }
        return nil
    }

    /// What holds filing up before Ollama is asked about.
    private var heldBeforeOllama: Holdup? {
        // Before the app is set up the runtime starts nothing, so nothing in Incoming is taken, whatever else holds.
        guard onboarded else { return .notSetUp }
        switch work {
        case .running: break
        case .idle: return .waitingForFolders
        case .refused: return .archiveNotRead
        case .away: return .archiveAway
        }
        if paused { return .paused }
        if let reason = ingest.powerPauseReason { return .power(reason) }
        return nil
    }

    /// What the user is to know at the foot of the window: why nothing is filed, or, while filing goes on, a record file
    /// that cannot be read, which nothing filed or changed meanwhile is written into until it is mended.
    public enum Attention: Sendable, Equatable {
        case held(Holdup)
        /// Record files that cannot be read, by their paths.
        case recordsUnreadable([String])
    }

    /// What the user is to know at the foot of the window, the first that applies: what holds filing up, then record files
    /// that cannot be read; nil while neither does.
    public var attention: Attention? {
        if let holdup { return .held(holdup) }
        return unreadableRecords.isEmpty ? nil : .recordsUnreadable(unreadableRecords)
    }

    /// What a search task is at work on, seen from any page.
    public enum TasksWork: Sendable, Equatable {
        /// A request is being read, by `model`.
        case readingRequest(model: String)
        /// A question waits for Ollama, which could not be reached: tried again at `until`, or being tried now, until the
        /// model begins, when nil.
        case waitingForOllama(until: Date?)
        /// A question is being answered, by `model`.
        case answering(model: String)

        /// Whether a request or a question is in hand, being read or answered, rather than waiting.
        public var inHand: Bool {
            if case .waitingForOllama = self { return false }
            return true
        }
    }

    /// What the search tasks are at work on: a request being read, else a question being answered or waiting for Ollama;
    /// nil while none is.
    public var tasksWork: TasksWork? {
        if let reading = taskQueue.reading { return .readingRequest(model: reading.model) }
        if let answering = conversation.answering {
            if conversation.waitingForOllama, !answering.progress.begun { return .waitingForOllama(until: nil) }
            return .answering(model: answering.model)
        }
        return conversation.waitingForOllama && conversation.queued > 0 ? .waitingForOllama(until: conversation.retryAt) : nil
    }

    /// What the app is doing now.
    public enum Now: Sendable, Equatable {
        case held(Holdup)
        /// A document, request or question waits for Ollama: until the first of them that found it away is tried again,
        /// or, when nil, while it is being tried.
        case waitingForOllama(until: Date?)
        /// The document at `path` is being worked on: at which stage, by which model, since when.
        case filing(path: String, work: JobWork)
        case tasks(TasksWork)
        /// Files wait in Incoming, none in hand.
        case queued(Int)
        case idle
    }

    /// What the app is doing now, the first that applies: what holds filing up before Ollama, the document being filed, a
    /// request being read or a question being answered, anything waiting for Ollama, files queued.
    public var now: Now {
        if let held = heldBeforeOllama { return .held(held) }
        // A document, a request or a question in hand is being worked on, Ollama answering or not yet known to.
        if let current = ingest.current { return .filing(path: current.path, work: current.work) }
        if let tasks = tasksWork, tasks.inHand { return .tasks(tasks) }
        // When it is tried again, unless something waiting is being tried now, which says none.
        let waits = [(ingest.waitingForOllama, ingest.retryAt), (taskQueue.waitingForOllama, taskQueue.retryAt),
                     (conversation.waitingForOllama, conversation.retryAt)].filter(\.0)
        if !waits.isEmpty { return .waitingForOllama(until: waits.contains { $0.1 == nil } ? nil : waits.compactMap(\.1).min()) }
        return ingest.queued > 0 ? .queued(ingest.queued) : .idle
    }

    /// How the menu bar's icon marks the app's state.
    public enum Mark: Sendable, Equatable {
        /// Something stops filing that the user must see to: Ollama in trouble, an archive not read or away.
        case problem
        case paused
        case filing
        case needsYou
        case idle
    }

    /// How the menu bar's icon marks the app's state, the first that applies: a problem, paused, a document being filed,
    /// documents waiting for the user.
    public var mark: Mark {
        if onboarded, work == .refused || work == .away { return .problem }
        if paused { return .paused }
        switch ollama {
        case .unhealthy, .notInstalled, .unreachable: return .problem
        case .unknown, .stopped, .starting, .ready: break
        }
        if ingest.current != nil { return .filing }
        return needsYou > 0 ? .needsYou : .idle
    }
}
