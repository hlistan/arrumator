import ArrumatorCore
import Foundation

/// What the app shows of what a runtime is doing, worked out in one place from what its streams publish: why nothing is
/// filed, what is happening now, what the search tasks are at work on, and how the menu bar's icon marks it. Each answer
/// is the first of an order that applies, which the app only words and draws.
public struct RuntimeActivity: Sendable, Equatable {
    /// Whether the user has set the app up (`AppSettings.onboardingCompleted`): before that, nothing is expected to run.
    public var onboarded: Bool
    public var paused: Bool
    public var work: RuntimeWork
    public var ingest: IngestStatus
    public var taskQueue: SearchTaskQueueStatus
    public var conversation: ConversationQueueStatus
    public var ollama: OllamaState
    /// How many documents wait for the user.
    public var needsYou: Int

    public init(onboarded: Bool, paused: Bool, work: RuntimeWork, ingest: IngestStatus, taskQueue: SearchTaskQueueStatus,
                conversation: ConversationQueueStatus, ollama: OllamaState, needsYou: Int) {
        self.onboarded = onboarded
        self.paused = paused
        self.work = work
        self.ingest = ingest
        self.taskQueue = taskQueue
        self.conversation = conversation
        self.ollama = ollama
        self.needsYou = needsYou
    }

    /// Why nothing is filed now.
    public enum Holdup: Sendable, Equatable {
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

    /// Why nothing is filed now, the first that applies: the work not running (once the app is set up), filing paused,
    /// a pause for the power source, Ollama; nil while filing goes on.
    public var holdup: Holdup? {
        if let held = heldBeforeOllama { return held }
        if ingest.waitingForOllama || !ollama.isReady { return .ollama(ollama) }
        return nil
    }

    /// What holds filing up before Ollama is asked about.
    private var heldBeforeOllama: Holdup? {
        if onboarded {
            switch work {
            case .running: break
            case .idle: return .waitingForFolders
            case .refused: return .archiveNotRead
            case .away: return .archiveAway
            }
        }
        if paused { return .paused }
        if let reason = ingest.powerPauseReason { return .power(reason) }
        return nil
    }

    /// What a search task is at work on, seen from any page.
    public enum TasksWork: Sendable, Equatable {
        /// A request is being read, by `model`.
        case readingRequest(model: String)
        /// A question tried again while Ollama was away waits for it, until the model begins.
        case waitingForOllama
        /// A question is being answered, by `model`.
        case answering(model: String)
    }

    /// What the search tasks are at work on: a request being read, else a question being answered; nil while neither is.
    public var tasksWork: TasksWork? {
        if let reading = taskQueue.reading { return .readingRequest(model: reading.model) }
        guard let answering = conversation.answering else { return nil }
        if conversation.waitingForOllama, !answering.progress.begun { return .waitingForOllama }
        return .answering(model: answering.model)
    }

    /// What the app is doing now.
    public enum Now: Sendable, Equatable {
        case held(Holdup)
        /// A document, request or question waits for Ollama.
        case waitingForOllama
        /// The document at `path` is at `stage`.
        case filing(path: String, stage: JobState)
        case tasks(TasksWork)
        /// Files wait in Incoming, none in hand.
        case queued(Int)
        case idle
    }

    /// What the app is doing now, the first that applies: what holds filing up before Ollama, anything waiting for
    /// Ollama, the document being filed, what a search task is at work on, files queued.
    public var now: Now {
        if let held = heldBeforeOllama { return .held(held) }
        if ingest.waitingForOllama || taskQueue.waitingForOllama || conversation.waitingForOllama { return .waitingForOllama }
        if let current = ingest.current { return .filing(path: current.path, stage: current.stage) }
        if let tasks = tasksWork { return .tasks(tasks) }
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
