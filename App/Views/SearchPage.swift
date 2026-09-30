import ArrumatorCore
import SwiftUI

/// Results for the sidebar's search field, as document rows that open in place.
struct SearchPage: View {
    @Environment(AppModel.self) private var model
    @State private var results: SearchResults?

    var body: some View {
        Page(title: Wording.search, symbol: "magnifyingglass", tint: .secondary, notes: note) {
            if let results, results.hits.isEmpty {
                EmptyState(symbol: "magnifyingglass", text: Wording.noMatches(model.searchText))
            } else if let results {
                VStack(alignment: .leading, spacing: 0) {
                    DocumentList(documents: results.hits.map(\.document),
                                 snippets: Dictionary(results.hits.map { ($0.id, $0.snippet) }, uniquingKeysWith: { a, _ in a }))
                }
            }
        }
        .task(id: "\(model.searchText)|\(model.activity)") { await search() }
    }

    /// Said only when search is working with less than it could.
    private var note: String? {
        guard let results, !results.semanticUsed else { return nil }
        return Wording.wordsOnly(results.semanticUnavailableReason)
    }

    private func search() async {
        guard let runtime = model.runtime else { return }
        do {
            try await Task.sleep(for: .milliseconds(runtime.config.search.debounceMilliseconds))
        } catch {
            return // The user typed again; the newer search replaces this one.
        }
        let query = model.searchText
        if let settings = model.settings {
            _ = await model.load(Wording.prepareSearchAction) { try await $0.prepareSearch(settings) }
        }
        results = await model.load(Wording.searchAction) { try await $0.search.search(SearchQuery(text: query)) }
    }
}
