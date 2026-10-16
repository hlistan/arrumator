import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

extension SearchTests {
    @Test(arguments: ["", "   ", "\n\t", "%%%", "\"\"", "-", "*", "sender:"])
    func aQueryWithNothingToLookForFindsNothingAndAsksNothingOfOllama(_ text: String) async throws {
        let db = try AppDatabase.inMemory()
        let first = try await insert(db, title: "Meter reading", body: "kilowatt hours", sender: "EDP")
        let second = try await insert(db, title: "Gas bill", body: "gas supply", sender: "Galp")
        let embedder = CountingEmbedder()
        let search = SearchService(database: db, vectors: await Self.vectors([(first, 0.9), (second, 0.9)]), embedder: embedder,
                                   config: try PipelineConfig.bundledDefaults().search, time: TestTime(.advances))
        let found = try await search.search(SearchQuery(text: text, meaning: .askOnce))
        #expect(found.hits.isEmpty && !found.cut, "nothing to look for lists no document: \(text.debugDescription)")
        #expect(found.withoutMeaning == .nothingToLookFor && found.nothingToLookFor, "and says so: \(text.debugDescription)")
        #expect(embedder.asked == 0, "and asks nothing of Ollama: \(text.debugDescription)")
    }
}

extension SearchTests {
    /// A file name Foundation writes to disk can be decomposed (NFD); a text read from a PDF can be either.
    @Test func aDecomposedQueryOrTextIsFoundAsAComposedOne() async throws {
        let composed = "faturação"
        let decomposed = "faturac\u{327}a\u{303}o"
        #expect(Array(composed.utf8) != Array(decomposed.utf8), "the two spellings are different bytes")
        let forms = [("composed", composed), ("decomposed", decomposed)]
        for (textForm, text) in forms {
            for (queryForm, query) in forms {
                let db = try AppDatabase.inMemory()
                let id = try await insert(db, title: "Bill", body: "período de \(text) julho", sender: "EDP")
                let search = SearchService(database: db, vectors: VectorIndex(), embedder: nil,
                                           config: try PipelineConfig.bundledDefaults().search, time: TestTime(.advances))
                #expect(try await search.search(SearchQuery(text: query, meaning: .wordsOnly)).hits.map(\.id) == [id],
                        "a \(queryForm) query finds \(textForm) text")
            }
        }
    }

    /// The known limit (open question 5 of the spec): `unicode61` makes one token of a run of a script written without
    /// spaces, so a word inside the run is not found by its words.
    @Test func aWordInsideARunOfAScriptWithoutSpacesIsNotFoundByItsWords() async throws {
        let db = try AppDatabase.inMemory()
        let id = try await insert(db, title: "Invoice", body: "東京都の請求書です", sender: "Shop")
        let search = SearchService(database: db, vectors: VectorIndex(), embedder: nil,
                                   config: try PipelineConfig.bundledDefaults().search, time: TestTime(.advances))
        #expect(try await search.search(SearchQuery(text: "東京", meaning: .wordsOnly)).hits.map(\.id) == [id], "the start of the run is found by prefix")
        #expect(try await search.search(SearchQuery(text: "請求書", meaning: .wordsOnly)).hits.isEmpty, "a word inside the run is not")
    }
}

extension SearchTests {
    /// What a person can type or paste, never an SQLite error to the caller (AGENTS.md §3: validate at the boundary).
    @Test(.timeLimit(.minutes(1)))
    func aMalformedQueryGivesResultsOrNoneAndNeverAnSQLiteError() async throws {
        let db = try AppDatabase.inMemory()
        let fixture = "fixture"
        let id = try await insert(db, title: "Notes", body: "abc foobar AND OR NOT NEAR x \(fixture)", sender: "EDP")
        let search = SearchService(database: db, vectors: VectorIndex(), embedder: nil,
                                   config: try PipelineConfig.bundledDefaults().search, time: TestTime(.advances))
        let long = Array(repeating: fixture, count: 10_000 / (fixture.count + 1)).joined(separator: " ")
        #expect(long.count >= 9_000, "the paste is as long as a paste is")
        let cases: [(query: String, found: [Int64])] = [("\"abc", [id]), ("foo:bar", [id]), ("AND", [id]), ("OR", [id]), ("NOT", [id]),
                                                        ("NEAR(", [id]), ("^x", [id]), ("abc \"unfinished", []), (long, [id])]
        for (query, found) in cases {
            let results = try await search.search(SearchQuery(text: query, meaning: .wordsOnly))
            #expect(results.hits.map(\.id) == found, "\(query.prefix(30).debugDescription) gives what it says")
        }
    }
}

extension SearchTests {
    @Test func aWordFromEachPlaceIsFoundAndOnlyWhereItIs() async throws {
        let db = try AppDatabase.inMemory()
        let none: [DocumentLabel] = []
        let text = try await insert(db, title: "Alpha doc", body: "server invoice CPX31", labels: none)
        let name = try await insert(db, title: "2026-07 EDP fatura julho", body: "", labels: none)
        let tag = try await insert(db, title: "Gamma doc", body: "", labels: [DocumentLabel(kind: .tag, value: "taxes 2024")])
        let sender = try await insert(db, title: "Delta doc", body: "", labels: [DocumentLabel(kind: .sender, value: "Hetzner")])
        let photo = try await insert(db, title: "IMG_0001", body: "", labels: none)
        let other = try await insert(db, title: "Zeta doc", body: "nothing of these", labels: none)
        let twice = try await insert(db, title: "Twice twice", body: "twice", labels: none)
        try await DocumentStore(database: db, time: TestTime(.advances)).update(photo) {
            $0.analysisJson = try JSON.string(DocumentAnalysis(interpretation: "A photo, an interpretation of a view."))
        }
        let search = SearchService(database: db, vectors: VectorIndex(), embedder: nil, config: try PipelineConfig.bundledDefaults().search,
                                   time: TestTime(.advances))
        func found(_ query: String) async throws -> SearchResults {
            try await search.search(SearchQuery(text: query, meaning: .wordsOnly))
        }
        for (query, id) in [("CPX31", text), ("julho", name), ("taxes", tag), ("Hetzner", sender), ("interpretation", photo), ("twice", twice)] {
            let results = try await found(query)
            #expect(results.hits.map(\.id) == [id], "\(query) finds its own document and no other")
            #expect(results.hits.allSatisfy { $0.sources == [.fullText] }, "by its words: \(query)")
            #expect(!results.hits.map(\.id).contains(other), "never the one with none of the words: \(query)")
        }
        let twiceFound = try await found("twice").hits.filter { $0.id == twice }
        #expect(twiceFound.count == 1, "a word in two places of one document (its name and its text) finds it once")
        #expect(try await found("c").hits.isEmpty, "one character is a whole word: no prefix")
        #expect(try await found("cp").hits.map(\.id) == [text], "two are the start of one")
        #expect(try await found("\"taxes 2024\"").hits.map(\.id) == [tag], "a phrase")
        #expect(try await found("sender:hetzner").hits.map(\.id) == [sender], "a field")
        #expect(try await found("tag:hetzner").hits.isEmpty, "under its own kind only")
    }
}
