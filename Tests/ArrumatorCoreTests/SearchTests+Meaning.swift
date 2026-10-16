import ArrumatorCore
import ArrumatorTesting
import GRDB
import Foundation
import Synchronization
import Testing

extension SearchTests {
    /// Answers with one fixed vector and counts the embeddings it is asked for.
    final class CountingEmbedder: Embedder {
        let modelId = FixedEmbedder.model
        private let count = Mutex(0)
        var asked: Int { count.withLock { $0 } }
        func embed(_ texts: [String], retrying: Bool) async throws -> [[Float]] {
            count.withLock { $0 += 1 }
            return texts.map { _ in [1, 0] }
        }
    }

    /// QA 2026-10-15, C7-1: with Ollama away, a search asked it again after each of `ollama.retryDelays`, so the meaning
    /// part of the app's search ended a minute late.
    @Test func theAppsSearchAsksOllamaOnceWhileItIsAway() async throws {
        let db = try AppDatabase.inMemory()
        let meter = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let mock = MockOllama(installed: [FixedEmbedder.model]) { _ in "" }
        await mock.failEmbedding(with: OllamaError.unreachable("down"))
        let (search, _) = try await searchByOllama(db, mock: mock, meter: meter)
        let found = try await search.search(SearchQuery(text: "kilowatt", meaning: .askOnce))
        #expect(found.hits.map(\.id) == [meter], "the words find the document")
        #expect(found.withoutMeaning == .ollamaAway, "and the results say Ollama was not reached or did not answer")
        #expect(await mock.embedRequests.count == 1, "Ollama is asked once, not again after each delay")
    }

    /// A search over a real `OllamaEmbedder` whose server `mock` stands in for, with the index holding `meter`'s vector.
    private func searchByOllama(_ db: AppDatabase, mock: MockOllama, meter: Int64) async throws -> (SearchService, PipelineConfig) {
        let config = try PipelineConfig.bundledDefaults()
        let gate = InferenceGate(api: mock, retryDelays: config.ollama.retryDelays, time: TestTime(.advances))
        let embedder = OllamaEmbedder(gate: gate, model: FixedEmbedder.model, keepAlive: config.ollama.keepAlive.embed,
                                      numCtx: config.analysis.embeddingNumCtx)
        let vectors = await Self.vectors([(meter, 0.9)])
        return (SearchService(database: db, vectors: vectors, embedder: embedder, config: config.search, time: TestTime(.advances)), config)
    }

    @Test func theCommandLinesSearchStillAsksAgainWhileOllamaIsAway() async throws {
        let db = try AppDatabase.inMemory()
        let meter = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let mock = MockOllama(installed: [FixedEmbedder.model]) { _ in "" }
        await mock.failEmbedding(with: OllamaError.unreachable("down"))
        let (search, config) = try await searchByOllama(db, mock: mock, meter: meter)
        let found = try await search.search(SearchQuery(text: "kilowatt", meaning: .askRetrying))
        #expect(found.hits.map(\.id) == [meter] && found.withoutMeaning == .ollamaAway, "the words stand, and it says why")
        #expect(await mock.embedRequests.count == 1 + config.ollama.retryDelays.count, "Ollama is asked again after each delay")
    }

    /// Every failure a comparison by meaning can end in, and the one reason each is told as.
    static let failures: [(any Error & Sendable, WithoutMeaning)] = [
        (OllamaError.unreachable("down"), .ollamaAway),
        (OllamaError.timeout("embed"), .ollamaAway),
        (OllamaError.http(status: 503, body: ""), .ollamaAway),
        (OllamaError.emptyResponse, .ollamaAway),
        (OllamaError.locationUnknown(model: "m", because: .unreachable("down")), .ollamaAway),
        (OllamaError.modelNotFound("bge-m3"), .modelNotInstalled),
        (OllamaError.runsElsewhere(model: "m", host: "h"), .runsElsewhere),
        (OllamaError.http(status: 400, body: ""), .ollamaFailed),
        (OllamaError.decoding("x"), .ollamaFailed),
        (OllamaError.redirected(endpoint: "e", location: nil), .ollamaFailed),
        (OllamaError.locationUnknown(model: "m", because: .http(status: 400, body: "")), .ollamaFailed),
        (VectorIndexError.otherDimension(model: "m", held: 2, asked: 3), .vectorsUnreadable),
        (DatabaseError(message: "no such table: embeddings"), .vectorsUnreadable),
    ]

    @Test(arguments: SearchTests.failures)
    func eachFailureOfMeaningIsOneReason(_ failure: any Error & Sendable, _ reason: WithoutMeaning) {
        #expect(WithoutMeaning(failure: failure) == reason, "\(failure)")
    }

    @Test func onlyWhatAskedOllamaIsToldAsOllamaFailing() {
        let asked: Set<WithoutMeaning> = [.modelNotInstalled, .runsElsewhere, .ollamaAway, .ollamaFailed]
        let all = Set(WithoutMeaning.allCases)
        #expect(all.filter(\.askedOllama) == asked, "the reasons that ask Ollama are those four")
        #expect(all.subtracting(asked) == [.notAsked, .nothingToLookFor, .tooShort, .noEmbeddingModel, .noDocuments, .vectorsUnreadable],
                "and the others never did")
    }

    @Test func whenMeaningCannotBeComparedTheWordsStandAndSayWhy() async throws {
        let db = try AppDatabase.inMemory()
        let meter = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let config = try PipelineConfig.bundledDefaults().search
        func found(_ embedder: (any Embedder)?, vectors: VectorIndex) async throws -> SearchResults {
            try await SearchService(database: db, vectors: vectors, embedder: embedder, config: config, time: TestTime(.advances))
                .search(SearchQuery(text: "kilowatt", meaning: .askOnce))
        }
        let held = await Self.vectors([(meter, 0.9)])
        let none = try await found(nil, vectors: held)
        #expect(none.hits.map(\.id) == [meter] && none.withoutMeaning == .noEmbeddingModel, "no embedding model")

        let counting = CountingEmbedder()
        let empty = try await found(counting, vectors: await Self.vectors([]))
        #expect(empty.hits.map(\.id) == [meter] && empty.withoutMeaning == .noDocuments, "an index with no vectors has nothing to compare")
        #expect(counting.asked == 0, "and Ollama is not asked")

        let elsewhere = try await found(FailingEmbedder(error: OllamaError.runsElsewhere(model: "m", host: "h")), vectors: held)
        #expect(elsewhere.hits.map(\.id) == [meter] && elsewhere.withoutMeaning == .runsElsewhere, "a model that runs elsewhere")
        let missing = try await found(FailingEmbedder(error: OllamaError.modelNotFound("bge-m3")), vectors: held)
        #expect(missing.hits.map(\.id) == [meter] && missing.withoutMeaning == .modelNotInstalled, "a model that is not installed")

        try await db.writer.write { try $0.execute(sql: "DROP TABLE embeddings") }
        let unreadable = try await found(FixedEmbedder(vector: [1, 0]), vectors: VectorIndex())
        #expect(unreadable.hits.map(\.id) == [meter] && unreadable.withoutMeaning == .vectorsUnreadable, "vectors that cannot be read")
    }

    @Test func theWordsComeWithoutTheModel() async throws {
        let db = try AppDatabase.inMemory()
        let meter = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let config = try PipelineConfig.bundledDefaults().search
        let counting = CountingEmbedder()
        let held = await Self.vectors([(meter, 0.1)])
        let words = try await SearchService(database: db, vectors: held, embedder: counting, config: config, time: TestTime(.advances))
            .search(SearchQuery(text: "kilowatt", meaning: .wordsOnly))
        #expect(words.hits.map(\.id) == [meter] && words.withoutMeaning == .notAsked, "the words find the document and say meaning was not asked")
        #expect(counting.asked == 0, "no embedding is asked for")
        let short = try await SearchService(database: db, vectors: held, embedder: counting, config: config, time: TestTime(.advances))
            .search(SearchQuery(text: String("kilowatt".prefix(config.minSemanticQueryChars - 1)), meaning: .wordsOnly))
        #expect(short.withoutMeaning == .tooShort, "a query too short to compare says so, as the full search does")

        let stalled = StalledEmbedder()
        let slow = SearchService(database: db, vectors: held, embedder: stalled, config: config, time: TestTime(.advances))
        let unhurried = try await slow.search(SearchQuery(text: "kilowatt", meaning: .wordsOnly))
        #expect(unhurried.hits.map(\.id) == [meter] && !stalled.asked.fired, "an embedder that never answers is never waited for")
        let both = try await SearchService(database: db, vectors: held, embedder: FixedEmbedder(vector: [1, 0]), config: config, time: TestTime(.advances))
            .search(SearchQuery(text: "kilowatt", meaning: .askOnce))
        #expect(both.hits.map(\.id) == unhurried.hits.map(\.id), "with no vector alike enough, the words' order is the full search's")
    }

    @Test func theAppsSearchAndTheCommandLinesFindTheSameInOneOrder() async throws {
        let db = try AppDatabase.inMemory()
        let withWord = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let closest = try await insert(db, title: "Electricity bill", body: "power invoice for July", sender: "EDP")
        let alike = try await insert(db, title: "Gas bill", body: "gas supply invoice", sender: "Galp")
        var config = try PipelineConfig.bundledDefaults().search
        config.semanticMinSimilarity = 0.5
        let search = SearchService(database: db, vectors: await Self.vectors([(withWord, 0.2), (closest, 0.9), (alike, 0.6)]),
                                   embedder: FixedEmbedder(vector: [1, 0]), config: config, time: TestTime(.advances))
        let app = try await search.search(SearchQuery(text: "kilowatt", meaning: .askOnce))
        let command = try await search.search(SearchQuery(text: "kilowatt", meaning: .askRetrying))
        #expect(app.hits.map(\.id) == [withWord, closest, alike], "the word first, then the documents alike by similarity")
        #expect(command.hits.map(\.id) == app.hits.map(\.id), "the command line's search finds the same in the same order")
    }

    @Test func everyStatusIsFoundAsTheCommandLineFindsIt() async throws {
        let db = try AppDatabase.inMemory()
        let statuses: [DocumentStatus] = [.filed, .needsReview, .held, .processing, .missing]
        var ids: [Int64] = []
        for status in statuses {
            let id = try await insert(db, title: "Meter \(status.rawValue)", body: "kilowatt hours", sender: "EDP")
            try await DocumentStore(database: db, time: TestTime(.advances)).update(id) { $0.status = status }
            ids.append(id)
        }
        let search = SearchService(database: db, vectors: await Self.vectors([]), embedder: FixedEmbedder(vector: [1, 0]),
                                   config: try PipelineConfig.bundledDefaults().search, time: TestTime(.advances))
        for mode in [SearchMeaning.wordsOnly, .askOnce, .askRetrying] {
            let found = try await search.search(SearchQuery(text: "kilowatt", meaning: mode))
            #expect(Set(found.hits.map(\.id)) == Set(ids), "every status is found, \(mode)")
            #expect(Dictionary(uniqueKeysWithValues: found.hits.map { ($0.id, $0.document.status) })
                    == Dictionary(uniqueKeysWithValues: zip(ids, statuses).map { ($0, $1) }), "each with its status, \(mode)")
        }
    }

    /// Whether the index holds a vector among the documents asked about: with no limit, among a set smaller than the index
    /// (looked up one by one) and among one as large (the index's own ones looked up in it), each way it can answer.
    @Test func theIndexSaysWhetherItHoldsAVectorAmongTheDocumentsAskedAbout() async {
        let vectors = await Self.vectors([(1, 0.9), (2, 0.8), (3, 0.7)])
        #expect(await vectors.holdsAny(among: nil), "with no limit, any vector will do")
        #expect(await VectorIndex().holdsAny(among: nil) == false, "and an index with none holds none")
        #expect(await vectors.holdsAny(among: [3, 99]), "a set smaller than the index that holds one of its documents")
        #expect(await vectors.holdsAny(among: [98, 99]) == false, "a set smaller than the index that holds none of its documents")
        #expect(await vectors.holdsAny(among: [2, 97, 98, 99]), "a set larger than the index that holds one of its documents")
        #expect(await vectors.holdsAny(among: [96, 97, 98, 99]) == false, "a set larger than the index that holds none of its documents")
        #expect(await vectors.holdsAny(among: []) == false, "an empty set holds none")
    }
}
