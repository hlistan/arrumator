import NaturalLanguage

/// The words of English the system knows, by its English word embedding (`NLEmbedding`, which the system loads once for
/// every caller): what tells a word of the language a reference's description is asked in from one of another language
/// that is not also an English word ("contract" and "client" are; "fatura" and "konto" are not). When the embedding
/// cannot be loaded every word is taken for English, so no description that may be English is sent back.
struct EnglishWords {
    private let embedding = NLEmbedding.wordEmbedding(for: .english)

    /// Whether `word`, in small letters, is an English word.
    func knows(_ word: String) -> Bool {
        embedding?.contains(word) ?? true
    }
}
