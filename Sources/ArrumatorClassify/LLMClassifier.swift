import ArrumatorCore
import Foundation

/// One question to the model, as the trace keeps it.
public struct ModelCall: Sendable, Codable, Hashable {
    public var model: String
    public var attempt: Int
    public var reason: Reason
    public var system: String
    public var user: String
    public var schema: JSONValue
    public var options: [String: JSONValue]
    /// What the model was told about thinking (`think`); nil when nothing was sent and it thought as it does by default.
    public var think: OllamaThink?
    public var response: String?
    public var metrics: OllamaMetrics?
    public var error: String?

    /// Why the model was asked.
    public enum Reason: String, Sendable, Codable, Hashable {
        /// To read the document or request.
        case primary
        /// Again, told what was wrong with its last answer.
        case repair
    }
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
            "No valid answer after \(Format.count(calls.count, "model call"))" + (calls.last?.error.map { ": \($0)" } ?? "")
        }
    }
}

/// Asks the local model for a schema-constrained answer and sends an invalid one back, with what was wrong, as often as
/// the effort allows. One model answers: no other is asked in its place. Every call (prompt, what the model was told about
/// thinking, raw response, counters) is returned for the trace.
public struct LLMClassifier: Sendable {
    public let gate: InferenceGate
    public let models: ModelManager
    public let effort: Effort

    public init(gate: InferenceGate, models: ModelManager, effort: Effort) {
        self.gate = gate
        self.models = models
        self.effort = effort
    }

    /// How much the model is given to answer with: its sampling and length of answer, its context and how long it stays
    /// loaded, what a model that can think is told about thinking, how often an invalid answer goes back to it, and how
    /// long one answer may take.
    public struct Effort: Sendable, Hashable {
        public var options: AnalysisConfig.LLMOptions
        /// What the effort wants a model told about thinking; each model is sent it as it allows.
        public var think: OllamaThink
        public var repairAttempts: Int
        /// Seconds an answer may take, after which it is a failed answer, not asked for again; nil for
        /// `ollama.timeouts.chat`, after which it is asked for again as when the server is away.
        public var timeout: Double?
        /// The context the model is asked with (`num_ctx`).
        public var numCtx: Int
        /// How long the model stays loaded after the answer (`keep_alive`).
        public var keepAlive: String

        public init(options: AnalysisConfig.LLMOptions, think: OllamaThink, repairAttempts: Int, timeout: Double?, numCtx: Int,
                    keepAlive: String) {
            self.options = options
            self.think = think
            self.repairAttempts = repairAttempts
            self.timeout = timeout
            self.numCtx = numCtx
            self.keepAlive = keepAlive
        }

        /// As documents are read (`analysis`), with the context and keep-alive images are described with too.
        public static func documents(_ config: PipelineConfig) -> Effort {
            Effort(options: config.analysis.llmOptions, think: config.analysis.think, repairAttempts: config.analysis.repairAttempts,
                   timeout: nil, numCtx: config.analysis.numCtx, keepAlive: config.ollama.keepAlive.chat)
        }

        /// As a search task's request is read at `preset`, sampled, and loaded, as documents are.
        public static func task(_ preset: EffortPreset, config: PipelineConfig) -> Effort {
            Effort(options: preset.options(over: config.analysis.llmOptions), think: preset.think, repairAttempts: preset.repairAttempts,
                   timeout: preset.timeout, numCtx: config.analysis.numCtx, keepAlive: config.ollama.keepAlive.chat)
        }
    }

    /// Asks `model`, and asks it again with what was wrong while its answer is invalid and the effort allows. A model
    /// Ollama does not have, and a server that is away (`OllamaError.isTransient(asking:)`), are thrown, so the document
    /// or task waits for them; any other failure, an answer that took longer than the effort's own `timeout`, which has
    /// nothing to send back, and an answer never valid, is `ModelAnswerError` with every call made.
    public func ask<Answer: Sendable & Hashable>(system: String, user: String, schema: JSONValue, model: String,
                                                 repairPrompt: @Sendable (String) throws -> String,
                                                 validate: @Sendable (String) throws -> Answer) async throws -> ModelAnswer<Answer> {
        let llm = effort.options
        let options: [String: JSONValue] = [
            "temperature": .number(llm.temperature), "top_k": .number(Double(llm.topK)),
            "top_p": .number(llm.topP), "num_predict": .number(Double(llm.numPredict)),
            "seed": .number(Double(llm.seed)), "num_ctx": .number(Double(effort.numCtx)),
        ]
        let think = try await think(model)
        var calls: [ModelCall] = []
        var messages: [OllamaMessage] = [.system(system), .user(user)]
        for attempt in 0...effort.repairAttempts {
            var call = ModelCall(model: model, attempt: attempt, reason: attempt == 0 ? .primary : .repair,
                                 system: system, user: messages.last?.content ?? user, schema: schema, options: options, think: think)
            let request = OllamaChatRequest(model: model, messages: messages, format: schema, options: options,
                                            keepAlive: effort.keepAlive, think: think, timeout: effort.timeout)
            let response: OllamaChatResponse
            do {
                response = try await gate.chat(request)
            } catch let error as OllamaError where error.isTransient(asking: request) {
                throw error
            } catch {
                if case OllamaError.timeout = error, let seconds = request.timeout {
                    call.error = AnswerValidationError.timedOut(seconds).localizedDescription
                } else {
                    call.error = error.localizedDescription
                }
                calls.append(call)
                if case OllamaError.modelNotFound = error { throw error }
                break
            }
            call.response = response.message.content
            call.metrics = response.metrics
            do {
                let answer = try validate(response.message.content)
                calls.append(call)
                return ModelAnswer(answer: answer, model: model, calls: calls)
            } catch {
                // An answer cut off at its length limit is invalid for that reason, whatever is wrong with what came.
                let error = response.reachedLengthLimit ? AnswerValidationError.cutOff(effort.options.numPredict) : error
                call.error = error.localizedDescription
                calls.append(call)
                Log.warning(.classify, "Invalid model answer", ["model": model, "attempt": String(attempt),
                                                                "error": error.localizedDescription])
                messages.append(.assistant(response.message.content))
                messages.append(.user(try repairPrompt(error.localizedDescription)))
            }
        }
        throw ModelAnswerError.exhausted(calls)
    }

    /// What `model` is told about thinking, as its `/api/show` allows (`OllamaShowResponse.think(sending:)`). A model
    /// Ollama does not have, and a server that is away, are thrown before it is asked anything; a model whose
    /// capabilities cannot be read otherwise is told nothing, and thinks as it does by default.
    private func think(_ model: String) async throws -> OllamaThink? {
        do {
            return try await models.capabilities(of: model).think(sending: effort.think)
        } catch {
            if let error = error as? OllamaError {
                if error.isTransient { throw error }
                if case .modelNotFound = error { throw error }
            }
            Log.warning(.classify, "The model's capabilities could not be read; it is told nothing about thinking",
                        ["model": model, "error": error.localizedDescription])
            return nil
        }
    }
}
