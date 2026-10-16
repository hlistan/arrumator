import Foundation

/// Why documents were not compared with a query by meaning, as a closed set: the app words each in `Wording`, the command
/// line in its own words, and a conversation's trace records its name.
public enum WithoutMeaning: String, Sendable, Hashable, Codable, CaseIterable {
    /// The query asked for its words alone, and is long enough to be compared.
    case notAsked
    /// No term of the query holds a letter or a number, so there is nothing to look for, by words or by meaning.
    case nothingToLookFor
    /// The query is shorter than `search.minSemanticQueryChars`: too short to mean anything.
    case tooShort
    /// The profile in use has no embedding model.
    case noEmbeddingModel
    /// The index holds no vector of the embedding model's among the documents asked about.
    case noDocuments
    /// Ollama does not have the embedding model (`OllamaError.modelNotFound`).
    case modelNotInstalled
    /// Ollama runs the embedding model beyond this Mac and the local network (`OllamaError.runsElsewhere`).
    case runsElsewhere
    /// Ollama could not be reached, or did not answer, or failed in a way worth asking again for (`OllamaError.isTransient`).
    case ollamaAway
    /// Ollama answered with a failure that asking again does not mend.
    case ollamaFailed
    /// The vectors, or the documents asked about, could not be read.
    case vectorsUnreadable

    /// The reason a comparison by meaning failed with `failure`. What stops a search (`CancellationError`) is no reason:
    /// callers throw it before they ask.
    public init(failure: any Error) {
        switch failure {
        case let error as OllamaError:
            switch error {
            case .modelNotFound: self = .modelNotInstalled
            case .runsElsewhere: self = .runsElsewhere
            default: self = error.isTransient ? .ollamaAway : .ollamaFailed
            }
        default:
            // What else a comparison throws is the index: `VectorIndexError`, or a `DatabaseError` reading the vectors or
            // the documents asked about.
            self = .vectorsUnreadable
        }
    }

    /// Whether Ollama was asked and failed to answer: what a search does not ask again for the same query.
    public var askedOllama: Bool {
        switch self {
        case .modelNotInstalled, .runsElsewhere, .ollamaAway, .ollamaFailed: true
        case .notAsked, .nothingToLookFor, .tooShort, .noEmbeddingModel, .noDocuments, .vectorsUnreadable: false
        }
    }
}
