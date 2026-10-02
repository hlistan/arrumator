import ArrumatorCore
import Foundation

/// Interpreter double: reads each prompt as the plan it is set up with for it, by the chat model of the profile it is
/// given, gives no plan with `problem` for any other, or throws `error`. It records a step as the model's interpreter
/// does, and remembers what it was asked, with the effort and profile it was read with, what it was told of the
/// archive's labels and the day. `during` runs while a prompt is read, as the user acting then.
public struct StubInterpreter: SearchPromptInterpreting {
    public actor Calls {
        public private(set) var prompts: [String] = []
        public private(set) var readings: [Reading] = []
        public private(set) var vocabularies: [[LabelKind: [LabelUsage]]] = []
        public private(set) var days: [String] = []
        func read(_ prompt: String, reading: Reading, vocabulary: [LabelKind: [LabelUsage]], today: String) {
            prompts.append(prompt)
            readings.append(reading)
            vocabularies.append(vocabulary)
            days.append(today)
        }
    }

    /// The effort a prompt was read with, and the profile that read it.
    public struct Reading: Sendable, Hashable {
        public var effort: TaskEffort
        public var profile: ModelProfile

        public init(effort: TaskEffort, profile: ModelProfile) {
            self.effort = effort
            self.profile = profile
        }
    }

    public let plans: [String: SearchPlan]
    public let problem: String
    public let error: (any Error & Sendable)?
    public let during: (@Sendable (String) async throws -> Void)?
    public let calls = Calls()

    public init(plans: [String: SearchPlan], problem: String = StubInterpreter.noAnswer, error: (any Error & Sendable)? = nil,
                during: (@Sendable (String) async throws -> Void)? = nil) {
        self.plans = plans
        self.problem = problem
        self.error = error
        self.during = during
    }

    public static let noAnswer = "the model gave no valid answer"

    public func interpret(_ prompt: String, effort: TaskEffort, profile: ModelProfile, vocabulary: [LabelKind: [LabelUsage]], today: String,
                          config: PipelineConfig, trace: TraceContext) async throws -> SearchInterpretation {
        await calls.read(prompt, reading: Reading(effort: effort, profile: profile), vocabulary: vocabulary, today: today)
        try await during?(prompt)
        if let error { throw error }
        let plan = plans[prompt]
        await trace.record(.interpret, status: plan == nil ? .error : .ok, startedAt: TestTime.start, output: plan)
        return SearchInterpretation(plan: plan, model: plan == nil ? nil : profile.chatModel, problem: plan == nil ? problem : nil)
    }
}
