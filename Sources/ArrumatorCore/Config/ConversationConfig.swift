import Foundation

/// How the model answers what is asked about a search task's documents (docs/how-it-works.md#talking-with-a-tasks-documents):
/// the context it answers in, how much of the set and of the conversation so far it is shown there, how it writes, and
/// how much it thinks at the task's effort. Which model answers is the task's profile's.
///
/// What it is shown is retrieved, as retrieval-augmented generation does (Lewis et al., "Retrieval-Augmented Generation
/// for Knowledge-Intensive NLP Tasks", NeurIPS 2020): of a set larger than the context holds, the text of the documents
/// most relevant to the question, and the rest by name; a long context is also used worst in its middle (Liu et al.,
/// "Lost in the Middle", TACL 2024), so it is kept to what the question needs
/// (docs/organizing-principles-sources.md#sources-for-conversations).
public struct ConversationConfig: Sendable, Codable, Hashable {
    /// Stamped on every answer's trace, so a change to the prompt shows in what it recorded.
    public var promptVersion: Int
    /// The context an answer is asked in (`num_ctx`): the documents' text, the conversation so far, the question and the
    /// answer, its thinking included, must fit in it, or Ollama drops the start of the prompt. A context other than
    /// `analysis.numCtx` has Ollama load the model again whenever it goes from reading documents to answering.
    public var numCtx: Int
    /// Characters of the set's text an answer is shown at most, the documents the question concerns most first.
    public var contextChars: Int
    /// Characters of one document's text shown at most: its start and its end, as a document is read
    /// (`analysis.excerptTailDivisor`).
    public var documentChars: Int
    /// Documents shown by their name, date and labels alone, those whose text does not fit, at most.
    public var maxListed: Int
    /// Characters of the conversation so far shown with a question, the latest exchanges kept.
    public var historyChars: Int
    /// Longest a question may be.
    public var maxQuestionChars: Int
    /// Documents outside the set an answer suggests at most, when it was asked to find more.
    public var maxSuggested: Int
    /// How an answer is sampled. Writing is not reading: greedy decoding, which reads documents the same each time,
    /// repeats itself over a long text (Holtzman et al., "The Curious Case of Neural Text Degeneration", ICLR 2020).
    public var sampling: Sampling
    /// How much the model thinks before it answers at each effort, with the budget that needs: every `TaskEffort` has one.
    public var efforts: [TaskEffort: Effort]

    public struct Sampling: Sendable, Codable, Hashable {
        public var temperature: Double
        public var topK: Int
        public var topP: Double
        public var seed: Int
    }

    /// What the model is told about thinking at an effort, sent as the model allows (`OllamaShowResponse.think(sending:)`),
    /// how often an answer that cannot be read goes back to it, how long an answer may be, its thinking included, and how
    /// many seconds it may take, in place of `ollama.timeouts.chat`.
    public struct Effort: Sendable, Codable, Hashable {
        public var think: OllamaThink
        public var repairAttempts: Int
        public var numPredict: Int
        public var timeout: Double
    }

    /// How the model answers at `effort`.
    public func effort(_ effort: TaskEffort) throws -> Effort {
        guard let preset = efforts[effort] else {
            throw ConfigError.invalid(name: "pipeline", underlying: "conversation.efforts.\(effort.rawValue) is missing")
        }
        return preset
    }

    /// The sampling an answer is asked with at `effort`, with the length it may take.
    public func options(_ effort: Effort) -> AnalysisConfig.LLMOptions {
        AnalysisConfig.LLMOptions(temperature: sampling.temperature, topK: sampling.topK, topP: sampling.topP,
                                  numPredict: effort.numPredict, seed: sampling.seed)
    }

    var problems: [String] {
        var problems: [String] = []
        for effort in TaskEffort.allCases {
            guard let preset = efforts[effort] else {
                problems.append("conversation.efforts.\(effort.rawValue) is missing")
                continue
            }
            if preset.repairAttempts < 0 { problems.append("conversation.efforts.\(effort.rawValue).repairAttempts cannot be negative") }
            if preset.numPredict < 1 { problems.append("conversation.efforts.\(effort.rawValue).numPredict must be at least 1") }
            if preset.numPredict >= numCtx { problems.append("conversation.efforts.\(effort.rawValue).numPredict leaves no room in conversation.numCtx") }
            if preset.timeout <= 0 { problems.append("conversation.efforts.\(effort.rawValue).timeout must be more than 0") }
        }
        if contextChars < 1 { problems.append("conversation.contextChars must be at least 1") }
        if documentChars < 1 { problems.append("conversation.documentChars must be at least 1") }
        if maxListed < 0 { problems.append("conversation.maxListed cannot be negative") }
        if historyChars < 0 { problems.append("conversation.historyChars cannot be negative") }
        if maxQuestionChars < 1 { problems.append("conversation.maxQuestionChars must be at least 1") }
        if maxSuggested < 1 { problems.append("conversation.maxSuggested must be at least 1") }
        return problems
    }
}
