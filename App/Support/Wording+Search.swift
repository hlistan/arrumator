import ArrumatorCore
import Foundation

/// What the search field and the page of its results say.
extension Wording {
    // MARK: The field and its menu item

    /// Edit › Find…, which brings the cursor to the field.
    static let findMenuItem = "Find…"
    /// What VoiceOver calls the field, never its placeholder: the placeholder is only a hint of what is typed there.
    static let searchDocuments = "Search Documents"
    static let searchPrompt = "Search"
    static let clearSearch = "Clear Search"
    static let searchTitle = "Search"
    /// What VoiceOver calls the results as one stop for the keyboard, with each row within it.
    static let searchResults = "Search Results"

    // MARK: Results

    static let withTheseWords = "With These Words"
    static let alikeInMeaning = "Alike in Meaning"
    /// One quiet line under the title while Ollama is asked for the query's meaning.
    static let lookingForMeaning = "Looking for documents alike in meaning…"
    static let noDocumentHasTheseWords = "No document has these words."
    static let typeAWord = "Type a word to look for."
    /// At the foot of results that were cut at `search.resultLimit`: no count, but how to narrow them down.
    static let searchCut = "The best matches are shown. More words, a phrase in quotes or field:word narrow them down."

    /// What a search that found nothing says, to the eye and to VoiceOver alike: nil when it found documents.
    static func nothingFound(_ results: SearchResults) -> String? {
        if results.nothingToLookFor { return typeAWord }
        return results.hits.isEmpty ? noDocumentHasTheseWords : nil
    }

    /// What VoiceOver is told when a search settles, as nothing visible counts the results: what the page says when it
    /// found nothing, how many it found, or, when it failed, the failure the banner shows. Nil while it is still looking.
    static func searchSaid(_ state: TypedSearchState) -> String? {
        if let failure = state.failure { return Wording.failure(searchAction, failure) }
        guard state.settled, let results = state.results else { return nil }
        return nothingFound(results) ?? "\(Format.count(results.hits.count, "document")) found"
    }

    static let searchAction = "Search"
    static let loadSearchAction = "Load search results"

    /// The line under the title that says how far comparing by meaning has come: nil where nothing is worth saying, as
    /// while it has not begun or has compared, and where the reason is no failure: a query too short to compare, or with
    /// nothing to look for, or asked for by its words alone.
    static func meaningLine(_ progress: MeaningProgress) -> String? {
        switch progress {
        case .pending, .compared: nil
        case .looking: lookingForMeaning
        case let .without(reason): meaningLine(reason)
        }
    }

    /// Why documents were not compared by meaning, as a line; nil for the reasons that are no failure.
    static func meaningLine(_ reason: WithoutMeaning) -> String? {
        let prefix = "Not compared by meaning: "
        switch reason {
        case .notAsked, .tooShort, .nothingToLookFor: return nil
        case .ollamaAway: return prefix + "Ollama cannot be reached or is not answering"
        case .noEmbeddingModel: return prefix + "the profile has no embedding model"
        case .modelNotInstalled: return prefix + "the embedding model is not installed in Ollama"
        case .runsElsewhere: return prefix + "the embedding model runs outside your network"
        case .ollamaFailed: return prefix + "Ollama answered with an error"
        case .vectorsUnreadable: return prefix + "the search index's vectors cannot be read"
        case .noDocuments: return prefix + "no document can be compared by meaning yet"
        }
    }

    /// A snippet of a document's text as a row shows it: its text as it is, the words found in bold, never read as
    /// Markdown or a link (AGENTS.md §4.5); nil for none.
    static func snippet(_ snippet: String) -> AttributedString? {
        var out = AttributedString()
        for (text, isMatch) in SearchHighlight.runs(snippet) {
            var run = AttributedString(text)
            if isMatch { run.inlinePresentationIntent = .stronglyEmphasized }
            out.append(run)
        }
        return out.characters.isEmpty ? nil : out
    }
}
