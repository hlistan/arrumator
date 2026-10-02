import ArrumatorCore
import Foundation

/// Answerer double: answers each question with the reply it is set up with for it, else with `fallback`, by the chat
/// model of the profile it is given, or throws `error`. It streams the reply a word at a time before it returns, records
/// a step as the model's answerer does, and remembers what it was asked with: the question, the context, the effort and
/// the profile. `during` runs once the first word is written, as the user acting while an answer is written.
public struct StubAnswerer: TaskQuestionAnswering {
    /// What a question is answered with.
    public struct Reply: Sendable, Hashable {
        public var text: String
        public var sources: [Int64]
        public var find: String?
        public var problem: String?

        public init(text: String, sources: [Int64] = [], find: String? = nil, problem: String? = nil) {
            self.text = text
            self.sources = sources
            self.find = find
            self.problem = problem
        }
    }

    public actor Calls {
        public private(set) var questions: [String] = []
        public private(set) var contexts: [TaskContext] = []
        public private(set) var readings: [StubInterpreter.Reading] = []
        public private(set) var days: [String] = []
        func asked(_ question: String, context: TaskContext, reading: StubInterpreter.Reading, today: String) {
            questions.append(question)
            contexts.append(context)
            readings.append(reading)
            days.append(today)
        }
    }

    public let replies: [String: Reply]
    public let fallback: Reply
    public let error: (any Error & Sendable)?
    public let during: (@Sendable (String) async throws -> Void)?
    public let calls = Calls()

    public init(replies: [String: Reply] = [:], fallback: Reply = Reply(text: StubAnswerer.answer), error: (any Error & Sendable)? = nil,
                during: (@Sendable (String) async throws -> Void)? = nil) {
        self.replies = replies
        self.fallback = fallback
        self.error = error
        self.during = during
    }

    /// What a question is answered with when nothing else is set up for it.
    public static let answer = "The documents say so."

    public func answer(_ question: String, context: TaskContext, effort: TaskEffort, profile: ModelProfile, today: String,
                       config: PipelineConfig, trace: TraceContext,
                       progress: @escaping @Sendable (AnswerProgress) async -> Void) async throws -> TaskAnswer {
        await calls.asked(question, context: context, reading: StubInterpreter.Reading(effort: effort, profile: profile), today: today)
        if let error { throw error }
        let reply = replies[question] ?? fallback
        var written = ""
        for (index, word) in reply.text.split(separator: " ").enumerated() {
            written += (index == 0 ? "" : " ") + word
            await progress(AnswerProgress(text: written, thinking: false))
            if index == 0 { try await during?(question) }
            try Task.checkCancellation()
        }
        await trace.record(.answer, startedAt: TestTime.start, output: reply.text)
        return TaskAnswer(text: reply.text, sources: reply.sources, find: reply.find, model: profile.chatModel, problem: reply.problem)
    }
}
