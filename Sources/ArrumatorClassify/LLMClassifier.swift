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
    public var errorDescription: String? {
        switch self {
        case let .exhausted(calls): "No valid answer after \(calls.count) model calls: \(calls.last?.error ?? "unknown")"
        }
    }
}

/// Asks the local model for a schema-constrained answer, repairs invalid answers, then falls back to the fast
/// model. Every call (prompt, raw response, counters) is returned for the trace.
public struct LLMClassifier: Sendable {
    public let gate: InferenceGate
    public let models: ModelManager
    public let config: ClassificationConfig

    public init(gate: InferenceGate, models: ModelManager, config: ClassificationConfig) {
        self.gate = gate
        self.models = models
        self.config = config
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
    }

    public func ask<Answer: Sendable & Hashable>(system: String, user: String, schema: JSONValue, tiers: [Tier],
                                                 repairPrompt: @Sendable (String) throws -> String,
                                                 validate: @Sendable (String) throws -> Answer) async throws -> ModelAnswer<Answer> {
        var calls: [ModelCall] = []
        for (tierIndex, tier) in tiers.enumerated() {
            let options: [String: JSONValue] = [
                "temperature": .number(config.llmOptions.temperature), "top_k": .number(Double(config.llmOptions.topK)),
                "top_p": .number(config.llmOptions.topP), "num_predict": .number(Double(config.llmOptions.numPredict)),
                "seed": .number(Double(config.llmOptions.seed)), "num_ctx": .number(Double(tier.numCtx)),
            ]
            let thinking = (try? await models.capabilities(of: tier.model).supportsThinking) ?? false
            var messages: [OllamaMessage] = [.system(system), .user(user)]
            for attempt in 0...config.repairAttempts {
                var call = ModelCall(model: tier.model, attempt: attempt,
                                     reason: tierIndex == 0 ? (attempt == 0 ? "primary" : "repair") : "fallback",
                                     system: system, user: messages.last?.content ?? user, schema: schema, options: options)
                let request = OllamaChatRequest(model: tier.model, messages: messages, format: schema, options: options,
                                                keepAlive: tier.keepAlive, think: thinking ? false : nil)
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
                    call.error = error.localizedDescription
                    calls.append(call)
                    Log.warning(.classify, "Invalid model answer", ["model": tier.model, "attempt": String(attempt),
                                                                    "error": error.localizedDescription])
                    messages.append(OllamaMessage(role: "assistant", content: response.message.content))
                    messages.append(.user(try repairPrompt(error.localizedDescription)))
                }
            }
        }
        throw ModelAnswerError.exhausted(calls)
    }
}
