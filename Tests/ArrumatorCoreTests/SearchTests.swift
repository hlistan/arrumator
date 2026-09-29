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

    func insert(_ db: AppDatabase, title: String, body: String, correspondent: String) async throws -> Int64 {
        var record = DocumentRecord.arrived(path: "/tmp/\(UUID().uuidString).pdf", sha256: UUID().uuidString, size: 1,
                                            uttype: "com.adobe.pdf", inode: nil, modified: nil)
        record.originalFilename = "\(title).pdf"
        record.correspondent = correspondent
        record.title = title
        record.status = .filed
        let doc = try await DocumentStore(database: db).save(record)
        let id = try #require(doc.id)
        try await IndexStore(database: db).upsertText(docID: id, title: title, correspondent: correspondent, filename: doc.filename,
                                                      body: body, summary: nil, metadata: [:], extractorVersion: "t")
        return id
    }

    @Test func fullTextIsDiacriticAndCaseInsensitiveAcrossScripts() async throws {
        let db = try AppDatabase.inMemory()
        let edp = try await insert(db, title: "Fatura eletricidade", body: "EDP Comercial fatura de eletricidade, período de faturação julho",
                                   correspondent: "EDP")
        let sber = try await insert(db, title: "Выписка по счёту", body: "Сбербанк выписка по счёту за июль, ИНН 7707083893",
                                    correspondent: "Sberbank")
        let config = try PipelineConfig.bundledDefaults().search
        let search = SearchService(database: db, vectors: VectorIndex(), embedder: nil, config: config)
        let pt = try await search.fullText(SearchQuery(text: "FATURAÇÃO"))
        #expect(pt.hits.map(\.id) == [edp])
        let ru = try await search.fullText(SearchQuery(text: "выпис"))
        #expect(ru.hits.map(\.id) == [sber])
        #expect(ru.hits.first?.snippet.contains(SearchHighlight.open) == true)
        let field = try await search.fullText(SearchQuery(text: "correspondent:edp"))
        #expect(field.hits.map(\.id) == [edp])
    }

    @Test func hybridSearchFusesSemanticHits() async throws {
        let db = try AppDatabase.inMemory()
        let a = try await insert(db, title: "Electricity bill", body: "electricity power invoice kilowatt", correspondent: "EDP")
        let b = try await insert(db, title: "Mobile contract", body: "phone contract data plan", correspondent: "MEO")
        let vectors = VectorIndex()
        let embedder = HashEmbedder()
        for (id, text) in [(a, "electricity power invoice kilowatt"), (b, "phone contract data plan")] {
            await vectors.upsert(docID: id, vector: try await embedder.embed([text])[0], model: embedder.modelId)
        }
        let search = SearchService(database: db, vectors: vectors, embedder: embedder, config: try PipelineConfig.bundledDefaults().search)
        let results = try await search.search(SearchQuery(text: "kilowatt power"))
        #expect(results.semanticUsed)
        #expect(results.hits.first?.id == a)
        #expect(results.hits.first?.sources.contains(.semantic) == true)
    }

    /// Maps every text to one fixed vector, so a test sets each document's similarity to the query exactly.
    struct FixedEmbedder: Embedder {
        let modelId = "fixed"
        let vector: [Float]
        func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in vector } }
    }

    @Test func documentsWithTheWordsComeFirstThenThoseAlikeInMeaningBySimilarity() async throws {
        let db = try AppDatabase.inMemory()
        let withWord = try await insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", correspondent: "EDP")
        let closest = try await insert(db, title: "Electricity bill", body: "power invoice for July", correspondent: "EDP")
        let alike = try await insert(db, title: "Gas bill", body: "gas supply invoice", correspondent: "Galp")
        let unrelated = try await insert(db, title: "Passport", body: "passport scan", correspondent: "Ministry")
        let vectors = VectorIndex()
        for (id, cosine) in [(withWord, Float(0)), (closest, 0.9), (alike, 0.6), (unrelated, 0.3)] {
            await vectors.upsert(docID: id, vector: [cosine, (1 - cosine * cosine).squareRoot()], model: "fixed")
        }
        var config = try PipelineConfig.bundledDefaults().search
        config.semanticMinSimilarity = 0.5
        let search = SearchService(database: db, vectors: vectors, embedder: FixedEmbedder(vector: [1, 0]), config: config)

        let results = try await search.search(SearchQuery(text: "kilowatt"))

        #expect(results.semanticUsed)
        #expect(results.hits.map(\.id) == [withWord, closest, alike],
                "the document containing the word leads although it is least alike; the rest follow by similarity, and one below the floor is left out")
        #expect(results.hits.first?.sources == [.fullText], "the word match is not among the similar documents above the floor")
        #expect(results.hits.dropFirst().allSatisfy { $0.sources == [.semantic] })
        #expect(results.hits.dropFirst().map(\.score) == [0.9, 0.6].map { Double(Float($0)) },
                "a document found by meaning alone is scored by its similarity to the query")
    }

    @Test func withoutAWordMatchOnlyDocumentsAboveTheSimilarityFloorAreFound() async throws {
        let db = try AppDatabase.inMemory()
        let near = try await insert(db, title: "Electricity bill", body: "power invoice", correspondent: "EDP")
        let far = try await insert(db, title: "Passport", body: "passport scan", correspondent: "Ministry")
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

    @Test func queryBuilderEscapes() {
        #expect(FTSQueryBuilder.build("  ") == nil)
        #expect(FTSQueryBuilder.build("a\"b") != nil)
        #expect(FTSQueryBuilder.build("title:fatura edp")?.contains("title :") == true)
        #expect(FTSQueryBuilder.build("\"nota de liquidação\"") == "\"nota de liquidação\"")
    }

    @Test func vectorIndexTopKAndRemove() async {
        let index = VectorIndex()
        await index.upsert(docID: 1, vector: [1, 0], model: "m")
        await index.upsert(docID: 2, vector: [0, 1], model: "m")
        await index.upsert(docID: 3, vector: VectorCodec.normalized([1, 1]), model: "m")
        #expect(await index.topK([1, 0], k: 2).map(\.docID) == [1, 3])
        await index.remove(docID: 1)
        #expect(await index.topK([1, 0], k: 1).map(\.docID) == [3])
        #expect(await index.topK([1, 0], k: 5, allowed: [2]).map(\.docID) == [2])
    }
}
