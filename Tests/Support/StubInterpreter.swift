import ArrumatorCore
import Foundation

/// Interpreter double: reads each prompt as the plan it is set up with for it, gives no plan with `problem` for any
/// other, or throws `error`. It records a step as the model's interpreter does, and remembers what it was asked, with
/// the effort and model it was read with, what it was told of the archive's labels and the day. `during` runs while a
/// prompt is read, as the user acting then.
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

    /// The effort a prompt was read with, and the model the task was given.
    public struct Reading: Sendable, Hashable {
        public var effort: TaskEffort
        public var model: String?

        public init(effort: TaskEffort, model: String?) {
            self.effort = effort
            self.model = model
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

    public static let model = "stub"
    public static let noAnswer = "the model gave no valid answer"

    public func interpret(_ prompt: String, effort: TaskEffort, model: String?, vocabulary: [LabelKind: [LabelUsage]], today: String,
                          settings: AppSettings, config: PipelineConfig, trace: TraceContext) async throws -> SearchInterpretation {
        await calls.read(prompt, reading: Reading(effort: effort, model: model), vocabulary: vocabulary, today: today)
        try await during?(prompt)
        if let error { throw error }
        let plan = plans[prompt]
        await trace.record(.interpret, status: plan == nil ? .error : .ok, startedAt: TestTime.start, output: plan)
        return SearchInterpretation(plan: plan, model: plan == nil ? nil : model ?? Self.model, problem: plan == nil ? problem : nil)
    }
}
