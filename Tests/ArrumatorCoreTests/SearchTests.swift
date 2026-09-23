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
