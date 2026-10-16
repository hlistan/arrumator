import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

extension SearchTests {
    @Test func manyResultsAreCutAtTheLimitAndSaySo() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try Data(#"{"search": {"resultLimit": 3}}"#.utf8).write(to: env.paths.pipelineOverrideURL)
        let lowered = try PipelineConfig.load(paths: env.paths, environment: TestEnvironment.isolated).search
        let bundled = try PipelineConfig.bundledDefaults().search
        let limit = lowered.resultLimit
        #expect(limit < bundled.resultLimit, "the override lowers the limit the search is cut at")
        for (matching, cut) in [(limit, false), (limit + 1, true), (0, false)] {
            let db = try AppDatabase.inMemory()
            for number in 0..<matching { _ = try await insert(db, title: "Meter \(number)", body: "kilowatt hours", sender: "EDP") }
            func found(_ config: SearchConfig) async throws -> SearchResults {
                try await SearchService(database: db, vectors: VectorIndex(), embedder: nil, config: config, time: TestTime(.advances))
                    .search(SearchQuery(text: "kilowatt", meaning: .wordsOnly))
            }
            let results = try await found(lowered)
            #expect(results.cut == cut, "\(matching) matching with a limit of \(limit): cut is \(cut)")
            #expect(results.hits.count == min(matching, limit), "the results hold at most the limit")
            #expect(results.hits.map(\.id) == Array(try await found(bundled).hits.prefix(limit)).map(\.id), "and they are the best, as with no cut")
            #expect(try await found(bundled).cut == false, "the bundled limit cuts none of them")
        }
    }

    @Test func aMatchOutsideTheTextHasNoSnippet() async throws {
        let db = try AppDatabase.inMemory()
        let byName = try await insert(db, title: "Hetzner July", body: "Server CPX31 monthly charge", sender: "Hosting")
        let byLabel = try await insert(db, title: "Invoice", body: "Server CPX31 monthly charge", sender: "Hetzner Online")
        let byText = try await insert(db, title: "Notes", body: "Hetzner invoice for the server", sender: "Hosting")
        let search = SearchService(database: db, vectors: VectorIndex(), embedder: nil, config: try PipelineConfig.bundledDefaults().search,
                                   time: TestTime(.advances))
        let hits = try await search.search(SearchQuery(text: "july", meaning: .wordsOnly)).hits
        #expect(hits.map(\.id) == [byName], "the word is in the name only")
        #expect(hits.first?.snippet == "", "a match in the name shows no text of the document, which has no word marked in it")
        let labelled = try await search.search(SearchQuery(text: "online", meaning: .wordsOnly)).hits
        #expect(labelled.map(\.id) == [byLabel] && labelled.first?.snippet == "", "nor does a match in a label")
        let texts = try await search.search(SearchQuery(text: "hetzner", meaning: .wordsOnly)).hits
        #expect(Set(texts.map(\.id)) == [byName, byLabel, byText], "the word is in the name, a label and the text of three documents")
        #expect(texts.first { $0.id == byText }?.snippet.contains(SearchHighlight.open) == true, "a match in the text is marked in its snippet")
        #expect(texts.filter { $0.id != byText }.allSatisfy { $0.snippet.isEmpty }, "the others, which hold the word outside their text, show none")
    }

    @Test func aSnippetIsRunsWithoutMarkersOrControlCharacters() {
        func runs(_ text: String) -> [[String: Bool]] { SearchHighlight.runs(text).map { [$0.0: $0.1] } }
        #expect(runs("a\u{E001}b") == [["ab": false]], "a close with no open is dropped")
        #expect(runs("\u{E000}a\u{E000}b\u{E001}c") == [["ab": true], ["c": false]], "an open inside a match is dropped")
        #expect(runs("x\u{E000}abc") == [["x": false], ["abc": true]], "a match left open runs to the end")
        let controlled = SearchHighlight.runs("line\none\u{1B}[2J").map(\.0).joined()
        #expect(!controlled.contains("\n") && !controlled.contains("\u{1B}"), "no break or control character is left: \(controlled.debugDescription)")
        #expect(runs("[link](x) **b**") == [["[link](x) **b**": false]], "Markdown is text, as it is")
        #expect(runs("") == [], "nothing makes no run")
    }

    /// A marker is one scalar, and a combining mark or a skin-tone modifier after it joins it into one `Character`: the
    /// markers are still found, and none reaches the screen or `--json`.
    @Test func aMarkerBesideAMarkOrAModifierIsStillAMarker() {
        func runs(_ text: String) -> [[String: Bool]] { SearchHighlight.runs(text).map { [$0.0: $0.1] } }
        #expect(runs("a \u{E000}\u{301}b\u{E001} c") == [["a ": false], ["\u{301}b": true], [" c": false]],
                "an open marker followed by a combining mark still opens a match")
        #expect(runs("\u{E000}ab\u{E001}\u{1F3FB}c") == [["ab": true], ["\u{1F3FB}c": false]], "a close marker followed by a skin-tone modifier still closes it")
        #expect(!SearchHighlight.plain("a \u{E000}\u{301}b\u{E001}\u{1F3FB}c").unicodeScalars.contains { $0 == "\u{E000}" || $0 == "\u{E001}" },
                "plain text, as --json gives it, holds no marker")
        #expect(SearchHighlight.plain("a \u{E000}\u{301}b\u{E001}\u{1F3FB}c") == "a \u{301}b\u{1F3FB}c", "and keeps the mark and the modifier")
    }
}
