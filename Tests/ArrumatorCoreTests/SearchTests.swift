import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
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
        record.labelsJson = JSON.string(labels)
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
        let search = SearchService(database: db, vectors: VectorIndex(), embedder: nil, config: config)
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
        for (id, text) in [(a, "electricity power invoice kilowatt"), (b, "phone contract data plan")] {
            await vectors.upsert(docID: id, vector: try await embedder.embed([text])[0], model: embedder.modelId)
        }
        let search = SearchService(database: db, vectors: vectors, embedder: embedder, config: try PipelineConfig.bundledDefaults().search)
        let results = try await search.search(SearchQuery(text: "kilowatt power"))
        #expect(results.semanticUsed, "the query is compared by meaning too")
        #expect(results.hits.first?.id == a, "the document with the words and the meaning leads")
        #expect(results.hits.first?.sources == [.fullText, .semantic], "it is found both by its words and by its meaning")
    }

    /// Maps every text to one fixed vector, so a test sets each document's similarity to the query exactly.
    struct FixedEmbedder: Embedder {
        let modelId = "fixed"
        let vector: [Float]
        func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in vector } }
    }

    @Test func documentsWithTheWordsComeFirstThenThoseAlikeInMeaningBySimilarity() async throws {
        let db = try AppDatabase.inMemory()
        let withWord = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let closest = try await insert(db, title: "Electricity bill", body: "power invoice for July", sender: "EDP")
        let alike = try await insert(db, title: "Gas bill", body: "gas supply invoice", sender: "Galp")
        let unrelated = try await insert(db, title: "Passport", body: "passport scan", sender: "Ministry")
        let vectors = VectorIndex()
        for (id, cosine) in [(withWord, Float(0)), (closest, 0.9), (alike, 0.6), (unrelated, 0.3)] {
            await vectors.upsert(docID: id, vector: [cosine, (1 - cosine * cosine).squareRoot()], model: "fixed")
        }
        var config = try PipelineConfig.bundledDefaults().search
        config.semanticMinSimilarity = 0.5
        let search = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(vector: [1, 0]), config: config)

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
        let vectors = VectorIndex()
        await vectors.upsert(docID: near, vector: [0.8, 0.6], model: "fixed")
        await vectors.upsert(docID: far, vector: [0.2, (1 - 0.04 as Float).squareRoot()], model: "fixed")
        var config = try PipelineConfig.bundledDefaults().search
        config.semanticMinSimilarity = 0.5
        let search = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(vector: [1, 0]), config: config)

        #expect(try await search.search(SearchQuery(text: "eletricidade")).hits.map(\.id) == [near],
                "a word in another language still finds the document it means, and nothing unrelated")
        config.semanticMinSimilarity = 0.95
        let strict = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(vector: [1, 0]), config: config)
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
        let vectors = VectorIndex()
        for (id, cosine) in [(meter, Float(0)), (power, 0.9), (gas, 0.3), (passport, 0.2), (outside, 0.95)] {
            await vectors.upsert(docID: id, vector: [cosine, (1 - cosine * cosine).squareRoot()], model: "fixed")
        }
        var config = try PipelineConfig.bundledDefaults().search
        config.semanticMinSimilarity = 0.5
        let set = [meter, power, gas, passport]
        let search = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(vector: [1, 0]), config: config)
        #expect(try await search.relevance(of: "What does the meter say about the gas?", among: set) == [gas, meter, power],
                "those with its words lead, the rarer the word the sooner (gas is in one document, meter in two); then one alike in meaning")
        #expect(try await !search.relevance(of: "meter passport", among: [meter, power, gas]).contains(passport), "nothing outside the set is ever ordered")
        let words = SearchService(database: db, vectors: vectors, embedder: nil, config: config)
        #expect(try await words.relevance(of: "the meter", among: set) == [meter], "without an embedding model, the words alone order them")
        #expect(try await words.relevance(of: "?!", among: set).isEmpty, "a question without words concerns none")
        #expect(try await words.relevance(of: "meter", among: []).isEmpty, "and an empty set has none")

        let missing = SearchService(database: db, vectors: vectors, embedder: FailingEmbedder(error: OllamaError.modelNotFound("bge-m3")),
                                    config: config)
        #expect(try await missing.relevance(of: "the meter", among: set) == [meter],
                "an embedding model that is missing leaves the words to order them")
        let away = SearchService(database: db, vectors: vectors, embedder: FailingEmbedder(error: OllamaError.unreachable("down")), config: config)
        await #expect(throws: OllamaError.unreachable("down"), "Ollama away is thrown, as the answer must wait for it all the same") {
            try await away.relevance(of: "the meter", among: set)
        }
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

    @Test func vectorIndexTopKAndRemove() async {
        let index = VectorIndex()
        await index.upsert(docID: 1, vector: [1, 0], model: "m")
        await index.upsert(docID: 2, vector: [0, 1], model: "m")
        await index.upsert(docID: 3, vector: VectorCodec.normalized([1, 1]), model: "m")
        #expect(await index.topK([1, 0], k: 2).map(\.docID) == [1, 3], "the nearest documents, nearest first")
        await index.remove(docID: 1)
        #expect(await index.topK([1, 0], k: 1).map(\.docID) == [3], "a removed document is no longer found")
        #expect(await index.topK([1, 0], k: 5, allowed: [2]).map(\.docID) == [2], "a search kept to some documents finds only those")
    }
}
