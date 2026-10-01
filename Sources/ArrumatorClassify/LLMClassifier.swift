import ArrumatorCore
import Foundation

public struct ModelCall: Sendable, Codable, Hashable {
    public var model: String
    public var attempt: Int
    public var reason: String
    public var system: String
    public var user: String
    public var schema: JSONValue
    public var options: [String: JSONValue]
    public var response: String?
    public var metrics: OllamaMetrics?
    public var error: String?
}

public struct ModelAnswer<Answer: Sendable & Hashable>: Sendable, Hashable {
    public var answer: Answer
    public var model: String
    public var calls: [ModelCall]
}

public enum ModelAnswerError: Error, LocalizedError {
    case exhausted([ModelCall])

    /// Every call made before giving up, for the trace.
    public var calls: [ModelCall] {
        switch self {
        case let .exhausted(calls): calls
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .exhausted(calls):
            "No valid answer after \(calls.count) model calls" + (calls.last?.error.map { ": \($0)" } ?? "")
        }
    }
}

/// Asks the local model for a schema-constrained answer, repairs invalid answers, then falls back to the next model.
/// Every call (prompt, raw response, counters) is returned for the trace.
public struct LLMClassifier: Sendable {
    public let gate: InferenceGate
    public let models: ModelManager
    public let effort: Effort

    public init(gate: InferenceGate, models: ModelManager, effort: Effort) {
        self.gate = gate
        self.models = models
        self.effort = effort
    }

    /// How much the model is given to answer with: its sampling and length of answer, whether a model that can think
    /// does, how often an invalid answer goes back to it, and how long one answer may take.
    public struct Effort: Sendable, Hashable {
        public var options: AnalysisConfig.LLMOptions
        public var think: Bool
        public var repairAttempts: Int
        /// Seconds; nil for `ollama.timeouts.chat`.
        public var timeout: Double?

        public init(options: AnalysisConfig.LLMOptions, think: Bool, repairAttempts: Int, timeout: Double?) {
            self.options = options
            self.think = think
            self.repairAttempts = repairAttempts
            self.timeout = timeout
        }

        /// As documents are read (`analysis`).
        public static func documents(_ analysis: AnalysisConfig) -> Effort {
            Effort(options: analysis.llmOptions, think: analysis.think, repairAttempts: analysis.repairAttempts, timeout: nil)
        }

        /// As a search task's request is read at `preset`, sampled as documents are.
        public static func task(_ preset: EffortPreset, analysis: AnalysisConfig) -> Effort {
            Effort(options: preset.options(over: analysis.llmOptions), think: preset.think, repairAttempts: preset.repairAttempts,
                   timeout: preset.timeout)
        }
    }

    public struct Tier: Sendable, Hashable {
        public var model: String
        public var numCtx: Int
        public var keepAlive: String
        public init(model: String, numCtx: Int, keepAlive: String) {
            self.model = model
            self.numCtx = numCtx
            self.keepAlive = keepAlive
        }

        /// The tiers in order, each model once: a profile may use one model for every role.
        public static func distinct(_ tiers: [Tier]) -> [Tier] {
            tiers.reduce(into: []) { acc, t in if !acc.contains(where: { $0.model == t.model }) { acc.append(t) } }
        }
    }

    public func ask<Answer: Sendable & Hashable>(system: String, user: String, schema: JSONValue, tiers: [Tier],
                                                 repairPrompt: @Sendable (String) throws -> String,
                                                 validate: @Sendable (String) throws -> Answer) async throws -> ModelAnswer<Answer> {
        var calls: [ModelCall] = []
        for (tierIndex, tier) in tiers.enumerated() {
            let llm = effort.options
            let options: [String: JSONValue] = [
                "temperature": .number(llm.temperature), "top_k": .number(Double(llm.topK)),
                "top_p": .number(llm.topP), "num_predict": .number(Double(llm.numPredict)),
                "seed": .number(Double(llm.seed)), "num_ctx": .number(Double(tier.numCtx)),
            ]
            // A model that cannot think is not told whether to.
            let thinking = (try? await models.capabilities(of: tier.model).supportsThinking) ?? false
            var messages: [OllamaMessage] = [.system(system), .user(user)]
            for attempt in 0...effort.repairAttempts {
                var call = ModelCall(model: tier.model, attempt: attempt,
                                     reason: tierIndex == 0 ? (attempt == 0 ? "primary" : "repair") : "fallback",
                                     system: system, user: messages.last?.content ?? user, schema: schema, options: options)
                let request = OllamaChatRequest(model: tier.model, messages: messages, format: schema, options: options,
                                                keepAlive: tier.keepAlive, think: thinking ? effort.think : nil, timeout: effort.timeout)
                let response: OllamaChatResponse
                do {
                    response = try await gate.chat(request)
                } catch let error as OllamaError where error.isTransient {
                    throw error
                } catch {
                    call.error = error.localizedDescription
                    calls.append(call)
                    if case OllamaError.modelNotFound = error, tierIndex == tiers.count - 1 { throw error }
                    break
                }
                call.response = response.message.content
                call.metrics = response.metrics
                do {
                    let answer = try validate(response.message.content)
                    calls.append(call)
                    return ModelAnswer(answer: answer, model: tier.model, calls: calls)
                } catch {
                    // An answer cut off at its length limit is invalid for that reason, whatever is wrong with what came.
                    let error = response.reachedLengthLimit ? AnswerValidationError.cutOff(effort.options.numPredict) : error
                    call.error = error.localizedDescription
                    calls.append(call)
                    Log.warning(.classify, "Invalid model answer", ["model": tier.model, "attempt": String(attempt),
                                                                    "error": error.localizedDescription])
                    messages.append(.assistant(response.message.content))
                    messages.append(.user(try repairPrompt(error.localizedDescription)))
                }
            }
        }
        throw ModelAnswerError.exhausted(calls)
    }
}
