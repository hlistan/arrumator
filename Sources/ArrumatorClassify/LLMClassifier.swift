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
    /// How many characters of this call's answer were left out when it was sent back to the model to be repaired, so
    /// the repair fit the model's context (`LLMClassifier.Effort.promptRoom`); nil when it was sent back whole or not at all.
    public var cutWhenSentBack: Int?

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
    /// The model gave no valid answer as often as it was asked.
    case exhausted([ModelCall])
    /// Asking ended before the model gave a valid answer, for `cause`, which the caller acts on as it would without the
    /// calls: a stop, a server that is away, or a model Ollama does not have. The last call failed with it.
    case interrupted(cause: any Error, calls: [ModelCall])

    /// Every call made before giving up, for the trace.
    public var calls: [ModelCall] {
        switch self {
        case let .exhausted(calls), let .interrupted(_, calls): calls
        }
    }

    /// What ended the asking, when it was not the model's answers: what the caller throws on once the calls are traced.
    public var cause: (any Error)? {
        switch self {
        case .exhausted: nil
        case let .interrupted(cause, _): cause
        }
    }

    /// How the step that asked is traced: a stop is no failure of the model's, anything else that ended it is.
    public var status: TraceStatus {
        guard let cause else { return .error }
        return cause is CancellationError ? .warn : .error
    }

    public var errorDescription: String? {
        switch self {
        case let .exhausted(calls):
            "No valid answer after \(Format.count(calls.count, "model call"))" + (calls.last?.error.map { ": \($0)" } ?? "")
        case let .interrupted(cause, _): cause.localizedDescription
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
        /// Whether a server that is away is asked again here (`ingest.retryDelays`), or left at once to a queue that waits
        /// for it and says so.
        public var retriesWhenAway: Bool
        /// The characters every call's messages may hold together, so they fit `numCtx` beside the answer
        /// (`PromptBudget.room`): what a repair sends back of an invalid answer is cut to it. Nil for no bound, as a
        /// document's reading has, whose prompt `analysis.excerptChars` bounds.
        public var promptRoom: Int?

        public init(options: AnalysisConfig.LLMOptions, think: OllamaThink, repairAttempts: Int, timeout: Double?, numCtx: Int,
                    keepAlive: String, promptRoom: Int?, retriesWhenAway: Bool = true) {
            self.options = options
            self.think = think
            self.repairAttempts = repairAttempts
            self.timeout = timeout
            self.numCtx = numCtx
            self.keepAlive = keepAlive
            self.promptRoom = promptRoom
            self.retriesWhenAway = retriesWhenAway
        }

        /// As documents are read (`analysis`), with the context and keep-alive images are described with too.
        public static func documents(_ config: PipelineConfig) -> Effort {
            Effort(options: config.analysis.llmOptions, think: config.analysis.think, repairAttempts: config.analysis.repairAttempts,
                   timeout: nil, numCtx: config.analysis.numCtx, keepAlive: config.ollama.keepAlive.chat, promptRoom: nil)
        }

        /// As a search task's request is read at `preset`, sampled, and loaded, as documents are.
        public static func task(_ preset: EffortPreset, config: PipelineConfig) -> Effort {
            Effort(options: preset.options(over: config.analysis.llmOptions), think: preset.think, repairAttempts: preset.repairAttempts,
                   timeout: preset.timeout, numCtx: config.analysis.numCtx, keepAlive: config.ollama.keepAlive.chat,
                   promptRoom: PromptBudget(numCtx: config.analysis.numCtx, numPredict: preset.numPredict,
                                            charsPerToken: config.ollama.charsPerToken).room)
        }

        /// As a question about a task's documents is answered at `effort`, sampled as writing is, in the conversation's
        /// context (`conversation`), and kept loaded as documents are. A server that is away is left to the conversation's
        /// queue, which shows the question waiting for Ollama rather than being answered.
        public static func conversation(_ effort: ConversationConfig.Effort, config: PipelineConfig) -> Effort {
            Effort(options: config.conversation.options(effort), think: effort.think, repairAttempts: effort.repairAttempts,
                   timeout: effort.timeout, numCtx: config.conversation.numCtx, keepAlive: config.ollama.keepAlive.chat,
                   promptRoom: PromptBudget(numCtx: config.conversation.numCtx, numPredict: effort.numPredict,
                                            charsPerToken: config.ollama.charsPerToken).room,
                   retriesWhenAway: false)
        }
    }

    /// Asks `model`, and asks it again with what was wrong while its answer is invalid and the effort allows. Every call
    /// made is in what it throws, so a caller traces each, those that failed too. A stop, a model Ollama does not have,
    /// and a server that is away (`OllamaError.isTransient(asking:)`) end the asking as
    /// `ModelAnswerError.interrupted`, whose `cause` the caller throws on, so the work stops or the document or task
    /// waits; any other failure, an answer that took longer than the effort's own `timeout`, which has nothing to send
    /// back, and an answer never valid, is `ModelAnswerError.exhausted`; an answer whose only fault is a guess it sends back
    /// (`GuessSentBack`) stands when no repair is left, or none comes of it, the last such answer. A stop before any call
    /// is thrown as it is.
    ///
    /// With `partial`, each answer is streamed to it as it is written, with the number of the attempt it belongs to. With
    /// `cutOff`, an answer cut off at its length limit is neither checked nor sent back: `cutOff` makes the answer of what
    /// came of it, as a long text is worth keeping in part where a list of labels is not.
    public func ask<Answer: Sendable & Hashable>(system: String, user: String, schema: JSONValue, model: String,
                                                 repairPrompt: @Sendable (String) throws -> String,
                                                 partial: (@Sendable (_ attempt: Int, _ response: OllamaChatResponse) async -> Void)? = nil,
                                                 cutOff: (@Sendable (String) throws -> Answer)? = nil,
                                                 validate: @Sendable (String) throws -> Answer) async throws -> ModelAnswer<Answer> {
        let llm = effort.options
        let options: [String: JSONValue] = [
            "temperature": .number(llm.temperature), "top_k": .number(Double(llm.topK)),
            "top_p": .number(llm.topP), "num_predict": .number(Double(llm.numPredict)),
            "seed": .number(Double(llm.seed)), "num_ctx": .number(Double(effort.numCtx)),
        ]
        let think = try await think(model)
        var calls: [ModelCall] = []
        // The answer that stands should no repair come of a guess sent back (`GuessSentBack`): a guess never fails one.
        var standing: Answer?
        var messages: [OllamaMessage] = [.system(system), .user(user)]
        for attempt in 0...effort.repairAttempts {
            var call = ModelCall(model: model, attempt: attempt, reason: attempt == 0 ? .primary : .repair,
                                 system: system, user: messages.last?.content ?? user, schema: schema, options: options, think: think)
            let request = OllamaChatRequest(model: model, messages: messages, format: schema, options: options,
                                            keepAlive: effort.keepAlive, think: think, timeout: effort.timeout)
            var streamed: (@Sendable (OllamaChatResponse) async -> Void)?
            if let partial {
                streamed = { @Sendable sofar in await partial(attempt, sofar) }
            }
            let response: OllamaChatResponse
            do {
                response = try await gate.chat(request, retrying: effort.retriesWhenAway, partial: streamed)
            } catch {
                if case OllamaError.timeout = error, let seconds = request.timeout {
                    call.error = AnswerValidationError.timedOut(seconds).localizedDescription
                } else {
                    call.error = error.localizedDescription
                }
                calls.append(call)
                if let cause = Self.ending(error, asking: request) { throw ModelAnswerError.interrupted(cause: cause, calls: calls) }
                break
            }
            call.response = response.message.content
            call.metrics = response.metrics
            if response.reachedLengthLimit, let cutOff {
                call.error = AnswerValidationError.cutOff(effort.options.numPredict).localizedDescription
                calls.append(call)
                return ModelAnswer(answer: try cutOff(response.message.content), model: model, calls: calls)
            }
            do {
                let answer = try validate(response.message.content)
                calls.append(call)
                return ModelAnswer(answer: answer, model: model, calls: calls)
            } catch let guess as GuessSentBack<Answer> where attempt == effort.repairAttempts && !response.reachedLengthLimit {
                // No repair is left to tell the model of a guess: the answer stands as it is, its notes saying so.
                calls.append(call)
                return ModelAnswer(answer: guess.standing, model: model, calls: calls)
            } catch {
                // An answer cut off at its length limit is invalid for that reason, whatever is wrong with what came.
                let error = response.reachedLengthLimit ? AnswerValidationError.cutOff(effort.options.numPredict) : error
                if let guess = error as? GuessSentBack<Answer> {
                    standing = guess.standing
                    guess.sent()
                }
                call.error = error.localizedDescription
                let repair = try repairPrompt(error.localizedDescription)
                let sentBack = Self.sentBack(response.message.content, after: messages, repair: repair, room: effort.promptRoom)
                call.cutWhenSentBack = sentBack.cut
                calls.append(call)
                Log.warning(.classify, "Invalid model answer", ["model": model, "attempt": String(attempt),
                                                                "error": error.localizedDescription])
                messages.append(.assistant(sentBack.text))
                messages.append(.user(repair))
            }
        }
        if let standing { return ModelAnswer(answer: standing, model: model, calls: calls) }
        throw ModelAnswerError.exhausted(calls)
    }

    /// What of an invalid `answer` a repair sends back, so the messages so far, the answer and `repair` fit `room`
    /// characters: its start, as far as fits, and how many characters were left out; the whole answer without a room.
    static func sentBack(_ answer: String, after messages: [OllamaMessage], repair: String, room: Int?) -> (text: String, cut: Int?) {
        guard let room else { return (answer, nil) }
        let left = max(0, room - messages.reduce(repair.count) { $0 + $1.content.count })
        guard answer.count > left else { return (answer, nil) }
        return (String(answer.prefix(left)), answer.count - left)
    }

    /// What ends the asking when a call to the model fails with `error`, rather than the call counting as one more answer
    /// that was not valid: a stop, as cancellation; a server that is away; a model Ollama does not have. Nil otherwise.
    static func ending(_ error: any Error, asking request: OllamaChatRequest) -> (any Error)? {
        if Cancellation.stops(error) { return CancellationError() }
        guard let error = error as? OllamaError else { return nil }
        if error.isTransient(asking: request) { return error }
        if case .modelNotFound = error { return error }
        return nil
    }

    /// What `model` is told about thinking, as its `/api/show` allows (`OllamaShowResponse.think(sending:)`). A stop, a
    /// model Ollama does not have, and a server that is away, are thrown before it is asked anything; a model whose
    /// capabilities cannot be read otherwise is told nothing, and thinks as it does by default.
    private func think(_ model: String) async throws -> OllamaThink? {
        do {
            return try await models.capabilities(of: model).think(sending: effort.think)
        } catch {
            try Cancellation.rethrow(error)
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
