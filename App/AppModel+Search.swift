import ArrumatorCore
import ArrumatorRuntime
import Foundation

/// The search field: what typing in it and the Find command do. Core decides which documents, in what order, and when
/// Ollama is asked (`TypedSearch`); this only passes the text on, in order, and shows the page of results.
extension AppModel {
    /// Hands `TypedSearch` what the person did, in the order they did it.
    func send(_ input: TypedSearch.Input) { searchFeed?.yield(input) }

    /// Brings the main window forward with the cursor in the search field (Edit › Find…, ⌘F). Until the field is there to
    /// hear it, as before the app is set up, the window that comes is the one that sets it up, and the request is let go
    /// of (`show(_:)`).
    func findDocuments() {
        searchFieldWanted = phase == .ready && settings?.onboardingCompleted == true
        show(.main)
    }

    /// Every change of the field's text. The first character shows the page of results in place of the page that was
    /// shown, which clearing the field shows again; searching lets go of the labels chosen and of collecting for a task,
    /// as any other page does (`go(_:)`).
    func search(_ text: String) {
        guard text != session.searchText else { return }
        guard !text.isEmpty else {
            go(session.beforeSearch ?? .processed)
            return
        }
        if session.destination != .search {
            session.beforeSearch = session.destination == .labelled ? .processed : session.destination
            go(.search)
        }
        session.searchText = text
        send(.typed(text))
    }

    /// Return in the field: Ollama is asked for the query's meaning now, without waiting for typing to pause.
    func submitSearch() { send(.submitted) }

    /// The field's × and its first Escape.
    func clearSearch() { search("") }

    /// The first document the page lists, which Down Arrow in the field puts the keyboard on; whether there is one.
    func focusFirstResult() -> Bool {
        guard let first = session.searchRows.first?.id else { return false }
        session.rowToFocus = first
        return true
    }

    /// Shows the results of the search for the text in the field: reads their documents with why each cannot be removed now
    /// and sets the rows the page lists. The rows keep their places under an open card and one no longer found closes it
    /// (`RowsUnderCard.reread`); a state of an older query is never shown. A query whose search failed before it found
    /// anything shows no rows, never the previous query's, and closes the card the same way; one whose words are still being
    /// searched leaves the page as it is.
    func showSearchResults() async {
        guard let state = session.currentSearch, state.results != nil || state.failedBeforeFinding else { return }
        var found: [SearchRow] = []
        if let results = state.results {
            let documents = results.hits.map(\.document)
            let read: @Sendable (ArrumatorRuntime) async throws -> (value: SearchResults, documents: [DocumentRecord]) = { _ in (results, documents) }
            guard let (_, refusals) = await load(Wording.loadSearchAction, withRefusals: read) else { return }
            // A newer state came while the refusals were read: its own reading shows it.
            guard session.currentSearch == state else { return }
            let listed = listed(documents, refusals: refusals)
            found = zip(results.hits, listed).map { hit, listed in
                SearchRow(listed: listed, excerpt: Wording.snippet(hit.snippet), byMeaningAlone: hit.byMeaningAlone)
            }
        }
        let outcome = RowsUnderCard.reread(shown: session.searchRows, read: found, open: session.openDocument,
                                           sameQuery: session.shownSearchQuery == state.query, id: \.id)
        session.shownSearchQuery = state.query
        session.searchRows = outcome.rows
        session.searchExcerpts = Dictionary(outcome.rows.compactMap { row in row.id.flatMap { id in row.excerpt.map { (id, $0) } } },
                                            uniquingKeysWith: { first, _ in first })
        // A card that closes because its document is no longer found leaves the keyboard on the row that takes its place.
        if !outcome.keepsCard {
            session.openDocument = nil
            session.rowToFocus = outcome.focus
        }
    }
}
