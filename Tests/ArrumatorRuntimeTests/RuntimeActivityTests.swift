@testable import ArrumatorCore
import ArrumatorRuntime
import Foundation
import Testing

/// What the app shows of what the runtime is doing (`RuntimeActivity`), decided below the interface: each answer is the
/// first of its order that applies, the same wherever it is shown.
@Suite struct RuntimeActivityTests {
    static let running = RuntimeActivity(onboarded: true, paused: false, work: .running, ingest: .idle, taskQueue: .idle,
                                         conversation: .idle, ollama: .ready(version: "0.12"), needsYou: 0, unreadableRecords: [])
    static let filing = IngestStatus(queued: 2, reindexing: 0, current: IngestStatus.Current(job: 1, path: "/Incoming/bill.pdf", stage: .analysing,
                                                                                       since: Date(timeIntervalSince1970: 0), reader: "qwen3.5:9b"),
                                     waitingForOllama: false, powerPauseReason: nil)
    static let reading = SearchTaskQueueStatus(reading: SearchTaskQueueStatus.Reading(task: 1, model: "qwen3.5:9b", since: Date(timeIntervalSince1970: 0)),
                                               queued: 0, waitingForOllama: false)

    static func with(_ change: (inout RuntimeActivity) -> Void) -> RuntimeActivity {
        var activity = running
        change(&activity)
        return activity
    }

    @Test func anArchiveThatIsAwayHoldsFilingUpBeforeAPauseOrOllamaAndIsMarkedAProblem() {
        let away = Self.with {
            $0.work = .away
            $0.paused = true
            $0.ollama = .stopped
        }
        #expect(away.holdup == .archiveAway, "the archive away is why nothing is filed, before the pause: \(String(describing: away.holdup))")
        #expect(away.now == .held(.archiveAway), "and what the app is doing now")
        #expect(away.mark == .problem, "and the menu bar marks it as a problem to see to")
        #expect(Self.with { $0.work = .refused }.holdup == .archiveNotRead, "an index not rebuilt from its archive is said so")
        #expect(Self.with { $0.work = .idle }.holdup == .waitingForFolders, "and work not started yet waits for the folders")
    }

    @Test func anAppNotSetUpSaysSoBeforeAnythingElseHoldsFilingUp() {
        let notSetUp = Self.with {
            $0.onboarded = false
            $0.work = .idle
            $0.paused = true
            $0.ollama = .unreachable("studio.local")
            $0.ingest.queued = 3
        }
        #expect(notSetUp.holdup == .notSetUp,
                "before the app is set up nothing is filed, whatever else holds it up, and a window says so: \(String(describing: notSetUp.holdup))")
        #expect(notSetUp.now == .held(.notSetUp), "and what the app is doing now, not files queued or Ollama")
        #expect(Self.with { $0.onboarded = false }.holdup == .notSetUp, "also with Ollama ready and nothing paused")
        #expect(Self.with { $0.onboarded = false }.mark == .idle, "setting up is no problem for the menu bar to mark")
    }

    @Test func aRecordFileThatCannotBeReadIsSaidWhileFilingGoesOnAfterWhatHoldsFilingUp() {
        let broken = Self.with { $0.unreadableRecords = ["/Archive/_documents.md"] }
        #expect(broken.holdup == nil && broken.attention == .recordsUnreadable(["/Archive/_documents.md"]),
                "filing goes on, and the foot of the window says which record file cannot be read")
        let pausedToo = Self.with {
            $0.unreadableRecords = ["/Archive/_documents.md"]
            $0.paused = true
        }
        #expect(pausedToo.attention == .held(.paused), "what holds filing up is said first")
        #expect(Self.running.attention == nil, "and nothing is said while nothing calls for it")
    }

    @Test func aPauseComesBeforeThePowerSourceAndOllama() {
        let paused = Self.with {
            $0.paused = true
            $0.ingest.powerPauseReason = "on battery"
        }
        #expect(paused.holdup == .paused && paused.now == .held(.paused) && paused.mark == .paused, "paused, whatever else holds it up")
        let power = Self.with { $0.ingest.powerPauseReason = "on battery" }
        #expect(power.holdup == .power("on battery") && power.now == .held(.power("on battery")), "then the power source, saying why")
    }

    @Test func ollamaNotReadyHoldsFilingUpButWhatIsHappeningNowWaitsForItOnlyWhenSomethingDoes() {
        let starting = Self.with { $0.ollama = .starting }
        #expect(starting.holdup == .ollama(.starting), "Ollama not ready yet holds filing up")
        #expect(starting.now == .idle && starting.mark == .idle, "but nothing waits for it, and starting is no problem")
        let waiting = Self.with {
            $0.ollama = .unreachable("studio.local")
            $0.conversation.waitingForOllama = true
        }
        #expect(waiting.now == .waitingForOllama && waiting.mark == .problem, "a question waiting for a server away is said, and marked")
    }

    @Test func aDocumentBeingFiledComesBeforeTheTasksAndFilesQueued() {
        let busy = Self.with {
            $0.ingest = Self.filing
            $0.taskQueue = Self.reading
            $0.needsYou = 3
        }
        #expect(busy.now == .filing(path: "/Incoming/bill.pdf", work: JobWork(stage: .analysing, model: "qwen3.5:9b", since: Date(timeIntervalSince1970: 0))),
                "the document in hand first, with the model reading it")
        #expect(busy.mark == .filing, "and the icon says a document is being filed, before what waits for the user")
        #expect(busy.tasksWork == .readingRequest(model: "qwen3.5:9b"), "what a task is at work on is seen from any page")
        let tasks = Self.with { $0.taskQueue = Self.reading }
        #expect(tasks.now == .tasks(.readingRequest(model: "qwen3.5:9b")), "with no document in hand, what the tasks do")
        #expect(Self.with { $0.ingest.queued = 4 }.now == .queued(4), "else the files queued")
        #expect(Self.running.now == .idle && Self.with { $0.needsYou = 1 }.mark == .needsYou, "else idle, marked when the user is needed")
    }

    @Test func aQuestionTriedAgainWaitsForOllamaUntilTheModelBegins() {
        let answering = ConversationQueueStatus.Answering(task: 1, turn: 2, model: "qwen3.5:9b", since: Date(timeIntervalSince1970: 0),
                                                          progress: .notBegun)
        let waiting = Self.with { $0.conversation = ConversationQueueStatus(answering: answering, queued: 0, waitingForOllama: true) }
        #expect(waiting.tasksWork == .waitingForOllama(until: nil), "not answering before the model's first words")
        var begun = answering
        begun.progress = AnswerProgress(text: "", thinking: true)
        let thinking = Self.with { $0.conversation = ConversationQueueStatus(answering: begun, queued: 0, waitingForOllama: true) }
        #expect(thinking.tasksWork == .answering(model: "qwen3.5:9b"), "and answering once they come")
    }

    /// QA 2026-10-04, CNV-6: between its tries a question waiting for Ollama was not said to be waiting at all.
    @Test func aQuestionPutOffWhileOllamaIsAwayWaitsForItUntilItIsTriedAgain() {
        let retry = Date(timeIntervalSince1970: 30)
        let waiting = Self.with { $0.conversation = ConversationQueueStatus(answering: nil, queued: 1, queuedTasks: [1], waitingForOllama: true, retryAt: retry) }
        #expect(waiting.tasksWork == .waitingForOllama(until: retry), "it waits for Ollama, tried again then")
        #expect(Self.with { $0.conversation = ConversationQueueStatus(answering: nil, queued: 0, waitingForOllama: false) }.tasksWork == nil,
                "and with nothing in the queue, the tasks are at work on nothing")
    }
}
