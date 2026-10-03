import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

@Suite struct SearchTests {
    struct HashEmbedder: Embedder {
        let modelId = "hash"
        func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { MockOllama.hashEmbedding($0, dimension: 256) } }
    }

    func insert(_ db: AppDatabase, title: String, body: String, sender: String) async throws -> Int64 {
        let labels = [DocumentLabel(kind: .sender, value: sender)]
        var record = DocumentRecord.arrived(path: "/tmp/\(title).pdf", sha256: title, size: 1,
                                            uttype: "com.adobe.pdf", inode: nil, modified: nil, now: TestTime.start)
        record.labelsJson = try JSON.string(labels)
        record.status = .filed
        let doc = try await DocumentStore(database: db, time: TestTime(.advances)).save(record)
        let id = try #require(doc.id)
        try await IndexStore(database: db, time: TestTime(.advances)).upsertText(docID: id, filename: doc.filename, body: body, summary: nil, metadata: [:],
                                                      extractorVersion: "t", labels: labels)
        return id
    }

    @Test func fullTextIsDiacriticAndCaseInsensitiveAcrossScripts() async throws {
        let db = try AppDatabase.inMemory()
        let edp = try await insert(db, title: "Fatura eletricidade", body: "EDP Comercial fatura de eletricidade, período de faturação julho",
                                   sender: "EDP")
        let sber = try await insert(db, title: "Выписка по счёту", body: "Сбербанк выписка по счёту за июль, ИНН 7707083893",
                                    sender: "Sberbank")
        let config = try PipelineConfig.bundledDefaults().search
        let search = SearchService(database: db, vectors: VectorIndex(), embedder: nil, config: config, time: TestTime(.advances))
        let pt = try await search.fullText(SearchQuery(text: "FATURAÇÃO"))
        #expect(pt.hits.map(\.id) == [edp], "case and accents do not matter")
        let ru = try await search.fullText(SearchQuery(text: "выпис"))
        #expect(ru.hits.map(\.id) == [sber], "a Cyrillic word is found by its start")
        #expect(ru.hits.first?.snippet.contains(SearchHighlight.open) == true, "the match is highlighted in the snippet")
        let field = try await search.fullText(SearchQuery(text: "sender:edp"))
        #expect(field.hits.map(\.id) == [edp], "a label is found under its kind")
    }

    @Test func hybridSearchFusesSemanticHits() async throws {
        let db = try AppDatabase.inMemory()
        let a = try await insert(db, title: "Electricity bill", body: "electricity power invoice kilowatt", sender: "EDP")
        let b = try await insert(db, title: "Mobile contract", body: "phone contract data plan", sender: "MEO")
        let vectors = VectorIndex()
        let embedder = HashEmbedder()
        await vectors.load(model: embedder.modelId, rows: [])
        for (id, text) in [(a, "electricity power invoice kilowatt"), (b, "phone contract data plan")] {
            await vectors.upsert(docID: id, vector: try await embedder.embed([text])[0], model: embedder.modelId)
        }
        let search = SearchService(database: db, vectors: vectors, embedder: embedder, config: try PipelineConfig.bundledDefaults().search,
                                   time: TestTime(.advances))
        let results = try await search.search(SearchQuery(text: "kilowatt power"))
        #expect(results.semanticUsed, "the query is compared by meaning too")
        #expect(results.hits.first?.id == a, "the document with the words and the meaning leads")
        #expect(results.hits.first?.sources == [.fullText, .semantic], "it is found both by its words and by its meaning")
    }

    /// Maps every text to one fixed vector, so a test sets each document's similarity to the query exactly.
    struct FixedEmbedder: Embedder {
        static let model = "fixed"
        var modelId = FixedEmbedder.model
        let vector: [Float]
        func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in vector } }
    }

    /// The fixed embedder's vectors for documents whose similarity to its query, `[1, 0]`, is each `cosine`.
    static func vectors(_ cosines: [(Int64, Float)]) async -> VectorIndex {
        let vectors = VectorIndex()
        await vectors.load(model: FixedEmbedder.model, rows: cosines.map { id, cosine in (id, [cosine, (1 - cosine * cosine).squareRoot()]) })
        return vectors
    }

    @Test func documentsWithTheWordsComeFirstThenThoseAlikeInMeaningBySimilarity() async throws {
        let db = try AppDatabase.inMemory()
        let withWord = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let closest = try await insert(db, title: "Electricity bill", body: "power invoice for July", sender: "EDP")
        let alike = try await insert(db, title: "Gas bill", body: "gas supply invoice", sender: "Galp")
        let unrelated = try await insert(db, title: "Passport", body: "passport scan", sender: "Ministry")
        let vectors = await Self.vectors([(withWord, 0), (closest, 0.9), (alike, 0.6), (unrelated, 0.3)])
        var config = try PipelineConfig.bundledDefaults().search
        config.semanticMinSimilarity = 0.5
        let search = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(vector: [1, 0]), config: config, time: TestTime(.advances))

        let results = try await search.search(SearchQuery(text: "kilowatt"))

        #expect(results.semanticUsed, "the query is compared by meaning too")
        #expect(results.hits.map(\.id) == [withWord, closest, alike],
                "the document containing the word leads although it is least alike; the rest follow by similarity, and one below the floor is left out")
        #expect(results.hits.first?.sources == [.fullText], "the word match is not among the similar documents above the floor")
        #expect(results.hits.dropFirst().allSatisfy { $0.sources == [.semantic] }, "the rest are found by meaning alone")
        #expect(results.hits.dropFirst().map(\.score) == [0.9, 0.6].map { Double(Float($0)) },
                "a document found by meaning alone is scored by its similarity to the query")
    }

    @Test func withoutAWordMatchOnlyDocumentsAboveTheSimilarityFloorAreFound() async throws {
        let db = try AppDatabase.inMemory()
        let near = try await insert(db, title: "Electricity bill", body: "power invoice", sender: "EDP")
        let far = try await insert(db, title: "Passport", body: "passport scan", sender: "Ministry")
        let vectors = await Self.vectors([(near, 0.8), (far, 0.2)])
        var config = try PipelineConfig.bundledDefaults().search
        config.semanticMinSimilarity = 0.5
        let search = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(vector: [1, 0]), config: config, time: TestTime(.advances))

        #expect(try await search.search(SearchQuery(text: "eletricidade")).hits.map(\.id) == [near],
                "a word in another language still finds the document it means, and nothing unrelated")
        config.semanticMinSimilarity = 0.95
        let strict = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(vector: [1, 0]), config: config, time: TestTime(.advances))
        #expect(try await strict.search(SearchQuery(text: "eletricidade")).hits.isEmpty,
                "when nothing contains the words and nothing is alike enough, search finds nothing")
    }

    /// Fails as it is told to, as an embedding model that is missing or a server that is away.
    struct FailingEmbedder: Embedder {
        let modelId = "failing"
        let error: any Error & Sendable
        func embed(_ texts: [String]) async throws -> [[Float]] { throw error }
    }

    @Test func aQuestionOrdersTheDocumentsOfASetByAnyOfItsWordsAndByMeaningAndLeavesTheRestOut() async throws {
        let db = try AppDatabase.inMemory()
        let meter = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let power = try await insert(db, title: "Electricity bill", body: "power invoice for July", sender: "EDP")
        let gas = try await insert(db, title: "Gas bill", body: "gas supply invoice", sender: "Galp")
        let passport = try await insert(db, title: "Passport", body: "passport scan", sender: "Ministry")
        let outside = try await insert(db, title: "Other meter", body: "meter meter meter", sender: "EDP")
        let vectors = await Self.vectors([(meter, 0), (power, 0.9), (gas, 0.3), (passport, 0.2), (outside, 0.95)])
        var config = try PipelineConfig.bundledDefaults().search
        config.semanticMinSimilarity = 0.5
        let set = [meter, power, gas, passport]
        func service(_ embedder: (any Embedder)?) -> SearchService {
            SearchService(database: db, vectors: vectors, embedder: embedder, config: config, time: TestTime(.advances))
        }
        let search = service(FixedEmbedder(vector: [1, 0]))
        let ordered = try await search.relevance(of: "What does the meter say about the gas?", among: set)
        #expect(ordered.documents == [gas, meter, power] && ordered.semanticUsed && ordered.semanticUnavailableReason == nil,
                "those with its words lead, the rarer the word the sooner (gas is in one document, meter in two); then one alike in meaning")
        #expect(try await !search.relevance(of: "meter passport", among: [meter, power, gas]).documents.contains(passport),
                "nothing outside the set is ever ordered")
        let words = try await service(nil).relevance(of: "the meter", among: set)
        #expect(words.documents == [meter] && !words.semanticUsed && words.semanticUnavailableReason == SearchService.noEmbedder,
                "without an embedding model, the words alone order them, and it says so")
        #expect(try await service(nil).relevance(of: "?!", among: set).documents.isEmpty, "a question without words concerns none")
        let none = try await search.relevance(of: "meter", among: [])
        #expect(none.documents.isEmpty && !none.semanticUsed && none.semanticUnavailableReason == SearchService.noDocuments,
                "and an empty set has none, compared with nothing")

        let missing = try await service(FailingEmbedder(error: OllamaError.modelNotFound("bge-m3"))).relevance(of: "the meter", among: set)
        #expect(missing.documents == [meter] && !missing.semanticUsed
                && missing.semanticUnavailableReason == OllamaError.modelNotFound("bge-m3").localizedDescription,
                "an embedding model that is missing leaves the words to order them, and says why")
        let away = service(FailingEmbedder(error: OllamaError.unreachable("down")))
        await #expect(throws: OllamaError.unreachable("down"), "Ollama away is thrown, as the answer must wait for it all the same") {
            try await away.relevance(of: "the meter", among: set)
        }
    }

    @Test func aQueryTheIndexCannotCompareIsSearchedByItsWordsAndSaysWhy() async throws {
        let db = try AppDatabase.inMemory()
        let meter = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let vectors = await Self.vectors([(meter, 0.9)])
        let config = try PipelineConfig.bundledDefaults().search
        let longer = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(vector: [1, 0, 0]), config: config, time: TestTime(.advances))
        let found = try await longer.search(SearchQuery(text: "kilowatt"))
        #expect(found.hits.map(\.id) == [meter] && !found.semanticUsed, "a query of another dimension than the index is not compared by meaning")
        #expect(found.semanticUnavailableReason == VectorIndexError.otherDimension(model: FixedEmbedder.model, held: 2, asked: 3).localizedDescription,
                "and the results say why")
        let other = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(modelId: "other", vector: [1, 0]), config: config,
                                  time: TestTime(.advances))
        let ordered = try await other.relevance(of: "the kilowatt meter", among: [meter])
        let loaded = await vectors.model
        #expect(ordered.documents == [meter] && ordered.semanticUsed && loaded == "other",
                "a question by another model than the index's loads that model's vectors first, here none, and is compared with them")
    }

    /// Holds every embedding asked for until its task is stopped, saying when it is first asked, as Ollama does with a
    /// long request.
    struct StalledEmbedder: Embedder {
        let modelId = FixedEmbedder.model
        let asked = Signal()
        func embed(_ texts: [String]) async throws -> [[Float]] {
            asked.fire()
            let (stream, continuation) = AsyncStream<Never>.makeStream()
            defer { continuation.finish() }
            for await _ in stream {}
            throw CancellationError()
        }
    }

    @Test func aSearchThatIsStoppedStops() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let embedder = StalledEmbedder()
        let search = SearchService(database: db, vectors: await Self.vectors([]), embedder: embedder,
                                   config: try PipelineConfig.bundledDefaults().search, time: TestTime(.advances))
        let searching = Task { try await search.search(SearchQuery(text: "kilowatt")) }
        #expect(await Patience.until { embedder.asked.fired }, "the search asks for the query's meaning")
        searching.cancel()
        await #expect(throws: CancellationError.self, "stopped, it stops: no results by the words alone as though Ollama failed") {
            try await searching.value
        }
    }

    /// Answers with one fixed vector, holding the embeddings asked for while it holds, and counts what it is asked.
    actor HeldEmbedder: Embedder {
        nonisolated let modelId = FixedEmbedder.model
        private(set) var asked = 0
        private var holding = true
        private var held: [CheckedContinuation<Void, Never>] = []

        func embed(_ texts: [String]) async throws -> [[Float]] {
            asked += 1
            if holding { await withCheckedContinuation { held.append($0) } }
            return texts.map { _ in [1, 0] }
        }

        func release() {
            holding = false
            for each in held { each.resume() }
            held = []
        }
    }

    @Test func aQueryTwoSearchesAskForAtOnceIsKeptOnce() async throws {
        let db = try AppDatabase.inMemory()
        let meter = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        var config = try PipelineConfig.bundledDefaults().search
        config.queryCacheSize = 1
        let embedder = HeldEmbedder()
        let search = SearchService(database: db, vectors: await Self.vectors([(meter, 0.9)]), embedder: embedder, config: config,
                                   time: TestTime(.advances))
        let query = SearchQuery(text: "kilowatt")
        async let first = search.search(query)
        async let second = search.search(query)
        #expect(await Patience.until { await embedder.asked == 2 }, "both searches ask for the query's meaning at once")
        await embedder.release()
        _ = try await (first, second)
        _ = try await search.search(query)
        #expect(await embedder.asked == 2, "the query's vector is kept once, so the next search finds it kept")
    }

    @Test func aVectorFiledOrADocumentRemovedWhileTheIndexLoadsIsNotLostToWhatTheLoadRead() async throws {
        let db = try AppDatabase.inMemory()
        let older = try await insert(db, title: "Electricity bill", body: "power invoice", sender: "EDP")
        let removed = try await insert(db, title: "Water bill", body: "water supply", sender: "Águas")
        let filed = try await insert(db, title: "Gas bill", body: "gas supply", sender: "Galp")
        let index = IndexStore(database: db, time: TestTime(.advances))
        let model = FixedEmbedder.model
        try await index.upsertEmbedding(docID: older, model: model, vector: [1, 0], sourceText: "power invoice")
        try await index.upsertEmbedding(docID: removed, model: model, vector: [0.8, 0.6], sourceText: "water supply")
        let vectors = VectorIndex()

        // The steps of a load and of filing in the order an interleaving gives them: the load begins and reads, a
        // document is filed and another taken out, then the load puts in what it read.
        await vectors.beginLoad(model: model)
        let read = try await index.embeddings(model: model)
        try await index.upsertEmbedding(docID: filed, model: model, vector: [0.6, 0.8], sourceText: "gas supply")
        await vectors.upsert(docID: filed, vector: [0.6, 0.8], model: model)
        await vectors.remove(docID: removed)
        await vectors.load(model: model, rows: read)

        #expect(try await vectors.topK([1, 0], model: model, k: 5).map(\.docID) == [older, filed],
                "the document filed meanwhile is found by meaning, and the one taken out is not")
    }

    @Test func twoFirstSearchesAtOnceReadTheVectorsOnce() async throws {
        let db = try AppDatabase.inMemory()
        let bill = try await insert(db, title: "Electricity bill", body: "power invoice", sender: "EDP")
        try await IndexStore(database: db, time: TestTime(.advances)).upsertEmbedding(docID: bill, model: FixedEmbedder.model,
                                                                                     vector: [1, 0], sourceText: "power invoice")
        let reads = Mutex(0)
        try await db.writer.write { db in
            db.trace { event in
                if event.description.contains("FROM embeddings") { reads.withLock { $0 += 1 } }
            }
        }
        let search = SearchService(database: db, vectors: VectorIndex(), embedder: FixedEmbedder(vector: [1, 0]),
                                   config: try PipelineConfig.bundledDefaults().search, time: TestTime(.advances))
        async let first = search.search(SearchQuery(text: "electricidade"))
        async let second = search.search(SearchQuery(text: "electricidade"))
        let (one, other) = try await (first, second)
        #expect(one.semanticUsed && other.semanticUsed && one.hits.map(\.id) == [bill] && other.hits.map(\.id) == [bill],
                "both are compared by meaning")
        #expect(reads.withLock { $0 } == 1, "with the vectors one of them read, which the other waited for")
    }

    @Test func theVectorsOfTheEmbeddingModelAreLoadedWhenASearchFirstNeedsThem() async throws {
        let db = try AppDatabase.inMemory()
        let meter = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let bill = try await insert(db, title: "Electricity bill", body: "power invoice", sender: "EDP")
        let index = IndexStore(database: db, time: TestTime(.advances))
        try await index.upsertEmbedding(docID: bill, model: FixedEmbedder.model, vector: [1, 0], sourceText: "power invoice")
        try await index.upsertEmbedding(docID: meter, model: "another model", vector: [1, 0], sourceText: "kilowatt hours")
        let vectors = VectorIndex()
        let search = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(vector: [1, 0]),
                                   config: try PipelineConfig.bundledDefaults().search, time: TestTime(.advances))
        #expect(await vectors.model == nil, "nothing is loaded before a search needs it")
        let found = try await search.search(SearchQuery(text: "electricidade"))
        #expect(found.semanticUsed && found.hits.map(\.id) == [bill], "a search by meaning loads the vectors of its embedding model first")
        #expect(await vectors.model == FixedEmbedder.model, "and keeps them for the next")
    }

    @Test func aSearchWhoseVectorsCannotBeReadGoesOnByItsWords() async throws {
        let db = try AppDatabase.inMemory()
        let meter = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        try await db.writer.write { try $0.execute(sql: "DROP TABLE embeddings") }
        let search = SearchService(database: db, vectors: VectorIndex(), embedder: FixedEmbedder(vector: [1, 0]),
                                   config: try PipelineConfig.bundledDefaults().search, time: TestTime(.advances))
        let found = try await search.search(SearchQuery(text: "kilowatt"))
        #expect(found.hits.map(\.id) == [meter] && !found.semanticUsed && found.semanticUnavailableReason?.isEmpty == false,
                "vectors that cannot be read leave the words to find the documents, and the results say why")
        let ordered = try await search.relevance(of: "the kilowatt meter", among: [meter])
        #expect(ordered.documents == [meter] && !ordered.semanticUsed && ordered.semanticUnavailableReason?.isEmpty == false,
                "and a question's documents are ordered by its words, without waiting for anything")
    }

    @Test func queryBuilderEscapes() {
        #expect(FTSQueryBuilder.build("  ") == nil, "a blank query searches for nothing")
        #expect(FTSQueryBuilder.build("a\"b") == "\"a\" \"b\"", "a stray quote cannot break the query")
        #expect(FTSQueryBuilder.build("filename:fatura edp") == "filename : \"fatura\" \"edp\" *", "a field names its column; the last word is a prefix")
        #expect(FTSQueryBuilder.build("\"nota de liquidação\"") == "\"nota de liquidação\"", "a quoted phrase is searched as a phrase")
    }

    @Test func aLabelKindIsAFieldAndAFieldTakesAPhrase() {
        #expect(FTSQueryBuilder.build("jurisdiction:\"Costa Rica\"") == "jurisdiction : \"Costa Rica\"", "a label kind is a column and takes a whole phrase")
        #expect(FTSQueryBuilder.build("Party:silva") == "party : \"silva\" *", "a field is named in any case; the last word is a prefix")
        #expect(FTSQueryBuilder.build("before\"a phrase\"") == "\"before\" \"a phrase\"", "a word before a phrase is a term of its own")
        #expect(FTSQueryBuilder.build("owner:\"x y\"") == "\"owner\" \"x y\"", "what is no column is a word")
        #expect(FTSQueryBuilder.build("object:\"\"") == nil, "an empty phrase is nothing to search for")
        #expect(FTSQueryBuilder.build("language:\"pt") == "language : \"pt\"", "a phrase left open ends with the query")
    }

    @Test func vectorIndexTopKAndRemove() async throws {
        let index = VectorIndex()
        await index.load(model: "m", rows: [(1, [1, 0]), (2, [0, 1]), (3, VectorCodec.normalized([1, 1]))])
        #expect(try await index.topK([1, 0], model: "m", k: 2).map(\.docID) == [1, 3], "the nearest documents, nearest first")
        await index.remove(docID: 1)
        #expect(try await index.topK([1, 0], model: "m", k: 1).map(\.docID) == [3], "a removed document is no longer found")
        #expect(try await index.topK([1, 0], model: "m", k: 5, allowed: [2]).map(\.docID) == [2], "a search kept to some documents finds only those")
    }

    @Test func aVectorOfAnotherModelLeavesTheIndexAsItIs() async throws {
        let index = VectorIndex()
        await index.load(model: "m", rows: [(1, [1, 0]), (2, [0, 1])])
        // A reading that began before the profile changed ends with the model it began with.
        await index.upsert(docID: 3, vector: [1, 0], model: "earlier")
        #expect(try await index.topK([1, 0], model: "m", k: 5).map(\.docID) == [1, 2], "the index keeps every vector it held, and takes none of another model")
        await #expect(throws: VectorIndexError.otherModel(held: "m", asked: "earlier"), "nor is a query of that model compared with them") {
            try await index.topK([1, 0], model: "earlier", k: 5)
        }
        await #expect(throws: VectorIndexError.otherModel(held: nil, asked: "m"), "an index loaded for no model compares nothing") {
            try await VectorIndex().topK([1, 0], model: "m", k: 5)
        }
        await index.upsert(docID: 3, vector: [0.6, 0.8], model: "m")
        #expect(try await index.topK([1, 0], model: "m", k: 5).map(\.docID) == [1, 3, 2], "a vector of its model is taken")
    }

    @Test func aVectorOfAnotherDimensionOrNoneIsRefused() async throws {
        let index = VectorIndex()
        await index.load(model: "m", rows: [(1, [1, 0])])
        await index.upsert(docID: 2, vector: [1, 0, 0], model: "m")
        await index.upsert(docID: 3, vector: [], model: "m")
        #expect(try await index.topK([1, 0], model: "m", k: 5).map(\.docID) == [1], "neither a longer vector nor an empty one is taken")
        await #expect(throws: VectorIndexError.otherDimension(model: "m", held: 2, asked: 3), "nor is a query of another dimension compared") {
            try await index.topK([1, 0, 0], model: "m", k: 5)
        }
        await index.upsert(docID: 4, vector: [0, 1], model: "m")
        await index.remove(docID: 1)
        #expect(try await index.topK([0, 1], model: "m", k: 5).map(\.docID) == [4], "and the vectors it holds stay in their places")
        await index.remove(docID: 4)
        await index.upsert(docID: 5, vector: [0, 0, 1], model: "m")
        #expect(try await index.topK([0, 0, 1], model: "m", k: 5).map(\.docID) == [5], "an index holding nothing takes the dimension of the next vector")

        let empty = VectorIndex()
        await empty.load(model: "m", rows: [])
        await empty.upsert(docID: 1, vector: [], model: "m")
        await empty.upsert(docID: 2, vector: [1, 0], model: "m")
        await empty.upsert(docID: 3, vector: [0, 1], model: "m")
        #expect(try await empty.topK([0, 1], model: "m", k: 5).map(\.docID) == [3, 2],
                "an empty vector sets no dimension and takes no place, so each vector after it keeps its own")
    }

    @Test func anIndexLoadedTakesTheDimensionMostOfItsVectorsHave() async throws {
        let index = VectorIndex()
        await index.load(model: "m", rows: [(1, []), (2, [1, 0, 0]), (3, [1, 0]), (4, [0, 1])])
        #expect(try await index.topK([1, 0], model: "m", k: 5).map(\.docID) == [3, 4],
                "an empty vector, or one of another dimension, first or not, never decides it, nor is taken")
        let empty = VectorIndex()
        await empty.load(model: "m", rows: [])
        #expect(try await empty.topK([1, 0], model: "m", k: 5).isEmpty, "an index of the model with no vectors yet finds nothing")
    }
}
