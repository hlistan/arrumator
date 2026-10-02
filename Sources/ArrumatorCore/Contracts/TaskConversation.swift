import Foundation

/// Where a question about a search task's documents is.
public enum TurnState: String, Sendable, Codable, CaseIterable {
    /// Waiting for the model to answer it.
    case queued
    /// The model is answering it.
    case answering
    /// Answered; `problem` says why the answer is incomplete, if it is.
    case answered
    /// Not answered; `problem` says why.
    case failed

    /// Still in the queue.
    public var isActive: Bool { self == .queued || self == .answering }
}

/// What an answer found outside its task's set when it was asked to find more: the request it wrote, read as a task's
/// request is, what that was read as, and the documents found that were not in the set then, nor taken out of it; or why
/// none could be found. The set changes only when the user adds them.
public struct TurnFinding: Sendable, Codable, Hashable {
    public var request: String
    public var plan: SearchPlan?
    public var documents: [Int64]
    public var problem: String?

    public init(request: String, plan: SearchPlan?, documents: [Int64], problem: String?) {
        self.request = request
        self.plan = plan
        self.documents = documents
        self.problem = problem
    }
}

/// A question about a search task's documents, and its answer.
public struct TaskTurn: Sendable, Codable, Hashable, Identifiable {
    public var id: Int64
    public var task: Int64
    public var question: String
    public var state: TurnState
    /// The answer, in Markdown; what came of it before it was cut off or stopped, too.
    public var answer: String?
    /// The documents the answer draws on, each one it was shown.
    public var sources: [Int64]
    public var finding: TurnFinding?
    /// The model that answered it last.
    public var model: String?
    public var problem: String?
    /// The trace of the last time it was answered; nil before, and after a rebuild.
    public var lastTrace: Int64?
    public var asked: Date
    public var answered: Date?

    public init(id: Int64, task: Int64, question: String, state: TurnState, answer: String?, sources: [Int64], finding: TurnFinding?,
                model: String?, problem: String?, lastTrace: Int64?, asked: Date, answered: Date?) {
        self.id = id
        self.task = task
        self.question = question
        self.state = state
        self.answer = answer
        self.sources = sources
        self.finding = finding
        self.model = model
        self.problem = problem
        self.lastTrace = lastTrace
        self.asked = asked
        self.answered = answered
    }
}

/// One item of a task's conversation as it is read (`TaskConversationStore.conversation(task:)`): a question with its
/// answer, or, between them, a change made to the task's set or to how it is read, as History recorded it, so the
/// conversation shows what each answer could draw on.
public struct ConversationItem: Sendable, Codable, Hashable, Identifiable {
    /// When the question was asked, or the change made.
    public var at: Date
    /// The question and its answer; nil for a change.
    public var turn: TaskTurn?
    /// The change, in History's words; nil for a question.
    public var change: String?

    public init(at: Date, turn: TaskTurn?, change: String?) {
        self.at = at
        self.turn = turn
        self.change = change
    }

    /// The question's number, which stays as it is answered; a change by when it was made and what it says.
    public var id: String { turn.map { "turn \($0.id)" } ?? "change \(at.timeIntervalSince1970) \(change ?? "")" }
}

/// One document as an answer is shown it: its number, name, date and labels, and its text, cut to
/// `conversation.documentChars`, or none when it is only listed.
public struct ContextDocument: Sendable, Codable, Hashable {
    public var id: Int64
    public var name: String
    public var date: String?
    public var labels: [DocumentLabel]
    public var text: String?

    public init(id: Int64, name: String, date: String?, labels: [DocumentLabel], text: String?) {
        self.id = id
        self.name = name
        self.date = date
        self.labels = labels
        self.text = text
    }
}

/// An earlier question and its answer, as an answer is shown the conversation so far.
public struct Exchange: Sendable, Codable, Hashable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// What an answer is shown (`TaskContextBuilder`): the documents of the set the question concerns most with their text,
/// then others by name alone, how many are not shown at all, and the conversation so far, the oldest exchange first.
public struct TaskContext: Sendable, Codable, Hashable {
    public var documents: [ContextDocument]
    public var unlisted: Int
    public var conversation: [Exchange]

    public init(documents: [ContextDocument], unlisted: Int, conversation: [Exchange]) {
        self.documents = documents
        self.unlisted = unlisted
        self.conversation = conversation
    }

    /// The documents shown with their text.
    public var read: [ContextDocument] { documents.filter { $0.text != nil } }
    /// The documents shown by name alone.
    public var listed: [ContextDocument] { documents.filter { $0.text == nil } }
}

/// An answer the model gave, checked: its text, the documents it draws on, a request for documents outside the set when
/// it was asked to find more, the model, and why it is incomplete, if it is.
public struct TaskAnswer: Sendable, Codable, Hashable {
    public var text: String
    public var sources: [Int64]
    public var find: String?
    public var model: String
    public var problem: String?

    public init(text: String, sources: [Int64], find: String?, model: String, problem: String?) {
        self.text = text
        self.sources = sources
        self.find = find
        self.model = model
        self.problem = problem
    }
}

/// An answer as it is written: what has come of it so far, and whether the model is still thinking, before it writes.
public struct AnswerProgress: Sendable, Hashable {
    public var text: String
    public var thinking: Bool
    /// The model has begun: something of the answer, or of its thinking, has come. Until then the question waits for the
    /// model, which may be loading, busy reading documents, or away.
    public var begun: Bool

    public init(text: String, thinking: Bool, begun: Bool = true) {
        self.text = text
        self.thinking = thinking
        self.begun = begun
    }

    /// Nothing has come from the model yet.
    public static let notBegun = AnswerProgress(text: "", thinking: false, begun: false)
}

/// Answers a question about a search task's documents from what it is shown of them. Implemented by
/// `ArrumatorClassify.TaskAnswerer`.
public protocol TaskQuestionAnswering: Sendable {
    /// `effort` is how much the model thinks before it answers (`conversation.efforts`), and `profile` the model profile
    /// whose chat model answers: the task's own, else the one Settings uses. `today` is the ISO day it is asked on.
    /// `progress` is given the answer as it is written. An answer cut off at its length limit is returned with what came
    /// of it, saying so; a model that cannot be reached throws, so the question waits; one that is missing, an answer
    /// that took longer than the effort allows and one never valid throw, so the question fails, saying why.
    func answer(_ question: String, context: TaskContext, effort: TaskEffort, profile: ModelProfile, today: String,
                config: PipelineConfig, trace: TraceContext,
                progress: @escaping @Sendable (AnswerProgress) async -> Void) async throws -> TaskAnswer
}
