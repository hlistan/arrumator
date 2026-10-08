import Foundation
import GRDB

/// Markers wrapped around matched terms in snippets; the UI and CLI turn them into highlighting.
public enum SearchHighlight {
    public static let open = "\u{E000}"
    public static let close = "\u{E001}"

    /// Splits highlighted text into (segment, isMatch) runs.
    public static func runs(_ text: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        var rest = Substring(text)
        while let o = rest.range(of: open) {
            if o.lowerBound > rest.startIndex { out.append((String(rest[..<o.lowerBound]), false)) }
            rest = rest[o.upperBound...]
            if let c = rest.range(of: close) {
                out.append((String(rest[..<c.lowerBound]), true))
                rest = rest[c.upperBound...]
            } else {
                out.append((String(rest), true))
                rest = ""
            }
        }
        if !rest.isEmpty { out.append((String(rest), false)) }
        return out
    }

    public static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: open, with: "").replacingOccurrences(of: close, with: "")
    }
}

public enum HitSource: String, Sendable, Codable, Hashable {
    case fullText, semantic
}

public struct SearchQuery: Sendable, Hashable {
    public var text: String
    public var filter: DocumentFilter
    public var semantic: Bool

    public init(text: String, filter: DocumentFilter = DocumentFilter(), semantic: Bool = true) {
        self.text = text
        self.filter = filter
        self.semantic = semantic
    }
}

public struct SearchHit: Sendable, Identifiable, Hashable {
    public var id: Int64 { document.id ?? 0 }
    public var document: DocumentRecord
    /// Orders hits within their group: the fused rank score for a document containing the words (full text only:
    /// its BM25 relevance), cosine similarity to the query for a document found by meaning alone.
    public var score: Double
    public var snippet: String
    public var sources: Set<HitSource>
}

public struct SearchResults: Sendable, Hashable {
    public var hits: [SearchHit]
    /// Whether documents were compared with the query by meaning too; when they were not, why.
    public var semanticUsed: Bool
    public var semanticUnavailableReason: String?
    public var elapsedMs: Double
}

/// The documents of a set that a text concerns, the most first (`SearchService.relevance`): whether they were compared
/// with it by meaning too, and, when they were not, why, as a search says (`SearchResults`).
public struct Relevance: Sendable, Hashable {
    public var documents: [Int64]
    public var semanticUsed: Bool
    public var semanticUnavailableReason: String?
}

/// Builds safe FTS5 MATCH expressions from user input: quoted terms, `"phrases"`, `field:term`, `field:"phrase"`, prefix
/// on the last term. The fields are the full-text columns (`SearchService.columns`), a label's kind among them.
public enum FTSQueryBuilder {
    static let fields = Set(SearchService.columns)

    public static func build(_ input: String) -> String? {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in input {
            if ch == "\"" {
                if inQuotes {
                    tokens.append(current + "\"")
                    current = ""
                } else {
                    // A phrase starts. A word before it is a term of its own, unless it names the phrase's field.
                    if !current.isEmpty && !isField(current) {
                        tokens.append(current)
                        current = ""
                    }
                    current.append(ch)
                }
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(inQuotes ? current + "\"" : current) }
        guard !tokens.isEmpty else { return nil }
        var parts: [String] = []
        for (i, token) in tokens.enumerated() {
            let isLast = i == tokens.count - 1
            var column: String?
            var term = token
            if let colon = token.firstIndex(of: ":"), fields.contains(String(token[..<colon]).lowercased()) {
                column = String(token[..<colon]).lowercased()
                term = String(token[token.index(after: colon)...])
            }
            if term.hasPrefix("\"") {
                let phrase = term.dropFirst().dropLast()
                guard !phrase.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let expr = "\"" + phrase.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                parts.append(column.map { "\($0) : \(expr)" } ?? expr)
                continue
            }
            let cleaned = term.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "." }
            let word = String(String.UnicodeScalarView(cleaned))
            guard !word.isEmpty else { continue }
            var expr = "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            if isLast && word.count >= 2 { expr += " *" }
            parts.append(column.map { "\($0) : \(expr)" } ?? expr)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Any of the words of `text`, each as a term of its own, never a field, a phrase or a prefix: what a sentence is
    /// searched by. Nil when no word has anything to look for.
    public static func anyOf(_ text: String) -> String? {
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var seen = Set<String>()
        let terms = words.filter { seen.insert($0.lowercased()).inserted }.map { "\"" + $0 + "\"" }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    /// `jurisdiction:`, a field's name and the colon that ends it.
    private static func isField(_ word: String) -> Bool {
        word.hasSuffix(":") && fields.contains(String(word.dropLast()).lowercased())
    }
}

/// Hybrid search: FTS5 BM25 (instant) fused with embedding similarity via Reciprocal Rank Fusion.
public actor SearchService {
    /// The columns of the full-text index, in its order (`AppDatabase.migrator`): each can be searched on its own as
    /// `column:term`, and `SearchConfig.bm25Weights` weighs them in this order. The last is what the model read the
    /// document as (`DocumentAnalysis.interpretation`).
    public static let columns = ["filename", "body"] + LabelKind.allCases.map(\.rawValue) + [interpretationColumn]
    /// The column of the full-text index that holds what the model read a document as.
    static let interpretationColumn = "interpretation"
    /// The column snippets are cut from: the document's text.
    static let bodyColumn = 1

    /// Why documents were not compared by meaning: the query asked for its words alone; it is too short to mean
    /// anything (`search.minSemanticQueryChars`); no embedding model is ready; there were no documents to compare.
    public static let notAsked = "disabled"
    public static let tooShort = "query too short"
    public static let noEmbedder = "no embedding model"
    public static let noDocuments = "no documents"

    private let database: AppDatabase
    private let vectors: VectorIndex
    private var embedder: (any Embedder)?
    private let config: SearchConfig
    private let time: any TimeSource
    private var cache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []
    /// The load of a model's vectors under way, which every caller that needs them meanwhile waits for.
    private var loading: (model: String, task: Task<Void, any Error>)?

    public init(database: AppDatabase, vectors: VectorIndex, embedder: (any Embedder)?, config: SearchConfig, time: any TimeSource) {
        self.database = database
        self.vectors = vectors
        self.embedder = embedder
        self.config = config
        self.time = time
    }

    /// Compares documents by meaning with `embedder` from now on, or by their words alone when it is nil, and forgets the
    /// query vectors of the one before. Its vectors are loaded when a comparison first needs them (`loadVectors`).
    public func setEmbedder(_ embedder: (any Embedder)?) {
        self.embedder = embedder
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Loads into the vector index the vectors the index keeps of the embedder's model, unless it holds them already:
    /// what a comparison by meaning does first, and what the app does when it starts, before it files anything, so no
    /// document filed meanwhile is left out. Without an embedder there is nothing to load. Throws what reading them
    /// throws.
    public func loadVectors() async throws {
        guard let embedder else { return }
        try await loadVectors(of: embedder.modelId)
    }

    /// Loads `model`'s vectors once for every caller that needs them meanwhile: a second search while the first loads
    /// waits for that load rather than reading them again. The load begins before the read (`VectorIndex.beginLoad`),
    /// so what is filed while it reads is kept. Its read is one query, so a caller stopped meanwhile stops once it ends.
    private func loadVectors(of model: String) async throws {
        guard await vectors.model != model else { return }
        if let loading, loading.model == model {
            try await loading.task.value
            try Task.checkCancellation()
            return
        }
        let task = Task { [database, time, vectors] in
            await vectors.beginLoad(model: model)
            do {
                await vectors.load(model: model, rows: try await IndexStore(database: database, time: time).embeddings(model: model))
            } catch {
                await vectors.abandonLoad(model: model)
                throw error
            }
        }
        loading = (model, task)
        defer { if loading?.task == task { loading = nil } }
        try await task.value
        try Task.checkCancellation()
    }

    /// Full-text phase only (fast path for type-ahead).
    public func fullText(_ query: SearchQuery) async throws -> SearchResults {
        let start = time.now()
        let hits = try await ftsHits(query)
        return SearchResults(hits: Array(hits.prefix(config.resultLimit)), semanticUsed: false, semanticUnavailableReason: nil,
                             elapsedMs: time.now().timeIntervalSince(start) * 1000)
    }

    /// The documents that hold the query's words, fused with those alike to it in meaning (`fuse`). When they cannot be
    /// compared by meaning, as when Ollama is away, the words alone find them, and the results say why. Stopping is
    /// thrown.
    public func search(_ query: SearchQuery) async throws -> SearchResults {
        let start = time.now()
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fts = try await ftsHits(query)
        let meaning = query.semantic
            ? try await alike(to: text, k: config.ftsCandidateLimit, waitingForOllama: false) { try await self.allowedIDs(query.filter) }
            : (found: [], unavailable: Self.notAsked)
        let fused = try await fuse(fts: fts, semantic: meaning.found)
        let elapsed = time.now().timeIntervalSince(start) * 1000
        Log.debug(.search, "Search", ["ms": String(format: "%.0f", elapsed), "fts": String(fts.count),
                                      "semantic": String(meaning.found.count)])
        return SearchResults(hits: Array(fused.prefix(config.resultLimit)), semanticUsed: meaning.unavailable == nil,
                             semanticUnavailableReason: meaning.unavailable, elapsedMs: elapsed)
    }

    /// The documents alike in meaning to `text`, the most alike first, at most `k`, among those `allowed` gives (all when
    /// it gives nil); or, when they cannot be compared by meaning, as when their vectors cannot be read, none, and why.
    /// Stopping is thrown, and so is Ollama being away when `waitingForOllama`, for what asks to wait for it all the same:
    /// at once, without asking it again meanwhile, as what asks says it waits for Ollama, and when it tries again.
    private func alike(to text: String, k: Int, waitingForOllama: Bool,
                       among allowed: () async throws -> Set<Int64>?) async throws -> (found: [(docID: Int64, score: Float)], unavailable: String?) {
        guard text.count >= config.minSemanticQueryChars else { return ([], Self.tooShort) }
        guard let embedder else { return ([], Self.noEmbedder) }
        do {
            try await loadVectors(of: embedder.modelId)
            let vector = try await queryVector(text, embedder: embedder, retrying: !waitingForOllama)
            return (try await vectors.topK(vector, model: embedder.modelId, k: k, allowed: try await allowed()), nil)
        } catch let error as OllamaError where waitingForOllama && error.isTransient {
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            Log.warning(.search, "Search by meaning unavailable", ["error": error.localizedDescription])
            return ([], error.localizedDescription)
        }
    }

    /// `text`'s vector by `embedder`, kept for the next `search.queryCacheSize` texts asked for. A text two searches ask
    /// for at once is embedded by both and kept once. Ollama away is asked again only when `retrying`.
    private func queryVector(_ text: String, embedder: any Embedder, retrying: Bool) async throws -> [Float] {
        let key = embedder.modelId + "\u{1}" + text
        if let hit = cache[key] { return hit }
        guard let vector = try await embedder.embed([text], retrying: retrying).first else { throw OllamaError.emptyResponse }
        if cache.updateValue(vector, forKey: key) == nil {
            cacheOrder.append(key)
            if cacheOrder.count > config.queryCacheSize { cache[cacheOrder.removeFirst()] = nil }
        }
        return vector
    }

    private func ftsHits(_ query: SearchQuery) async throws -> [SearchHit] {
        let limit = config.ftsCandidateLimit
        guard let match = FTSQueryBuilder.build(query.text) else {
            return try await database.reader.read { db in
                let (whereSQL, whereArgs) = try query.filter.sql(db)
                return try DocumentRecord.fetchAll(db, sql: "SELECT d.* FROM documents d WHERE 1=1 \(whereSQL) ORDER BY d.added_at DESC LIMIT ?",
                                            arguments: whereArgs + [limit])
                    .map { SearchHit(document: $0, score: 0, snippet: "", sources: []) }
            }
        }
        let weights = config.bm25Weights.map { String($0) }.joined(separator: ", ")
        let open = SearchHighlight.open
        let close = SearchHighlight.close
        let tokens = config.snippetTokens
        return try await database.reader.read { db in
            let (whereSQL, whereArgs) = try query.filter.sql(db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.*, bm25(document_fts, \(weights)) AS rank,
                       snippet(document_fts, \(Self.bodyColumn), ?, ?, '…', ?) AS snip
                FROM document_fts JOIN documents d ON d.id = document_fts.rowid
                WHERE document_fts MATCH ? \(whereSQL)
                ORDER BY rank LIMIT ?
                """, arguments: [open, close, tokens, match] + whereArgs + [limit])
            return try rows.map { row in
                SearchHit(document: try DocumentRecord(row: row), score: -(row["rank"] as Double? ?? 0),
                          snippet: row["snip"] ?? "", sources: [.fullText])
            }
        }
    }

    /// Documents that contain the query's words come first, ordered by reciprocal rank fusion of their full-text rank
    /// and, when alike enough, their rank by meaning (`fusedOrder`). Documents found by meaning alone follow, most similar
    /// first.
    private func fuse(fts: [SearchHit], semantic: [(docID: Int64, score: Float)]) async throws -> [SearchHit] {
        let order = Self.fusedOrder(fts: fts.map(\.id), semantic: semantic, rrfK: config.rrfK, minSimilarity: config.semanticMinSimilarity)
        let byID = Dictionary(fts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let withWords = order.withWords.compactMap { item in
            byID[item.id].map { hit in
                var fused = hit
                fused.score = item.score
                if item.byMeaning { fused.sources.insert(.semantic) }
                return fused
            }
        }
        guard !order.meaningOnly.isEmpty else { return withWords }
        let ids = order.meaningOnly.map(\.id)
        let docs = try await database.reader.read { [ids] db in
            Dictionary(uniqueKeysWithValues: try DocumentRecord.fetchAll(db, keys: ids).compactMap { d in d.id.map { ($0, d) } })
        }
        let bodies = try await database.reader.read { [ids] db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
                SELECT doc_id, substr(body, 1, ?) AS b FROM document_text WHERE doc_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: [config.vectorSnippetChars] + StatementArguments(ids)).map { ($0["doc_id"] as Int64, $0["b"] as String? ?? "") })
        }
        return withWords + order.meaningOnly.compactMap { item in
            docs[item.id].map { SearchHit(document: $0, score: Double(item.similarity), snippet: bodies[item.id] ?? "", sources: [.semantic]) }
        }
    }

    /// Documents that contain the words, `fts` in their full-text rank, first, ordered by reciprocal rank fusion (Cormack
    /// et al., SIGIR 2009) of that rank and, when alike enough, their rank by meaning; then the documents found by meaning
    /// alone, most similar first. Similarity is cosine, so every query has nearest neighbours; only those at or above
    /// `minSimilarity` are found, which is the similarity floor Elasticsearch's kNN search applies for the same reason (its
    /// `similarity` parameter).
    static func fusedOrder(fts: [Int64], semantic: [(docID: Int64, score: Float)], rrfK: Double,
                           minSimilarity: Double) -> (withWords: [(id: Int64, score: Double, byMeaning: Bool)],
                                                      meaningOnly: [(id: Int64, similarity: Float)]) {
        let alike = semantic.filter { Double($0.score) >= minSimilarity }
        let meaningRank = Dictionary(alike.enumerated().map { ($1.docID, $0) }, uniquingKeysWith: min)
        let reciprocal = { (rank: Int) in 1 / (rrfK + Double(rank + 1)) }
        let withWords = fts.enumerated().map { rank, id in
            (rank: rank, id: id, score: reciprocal(rank) + (meaningRank[id].map(reciprocal) ?? 0), byMeaning: meaningRank[id] != nil)
        }
        .sorted { ($0.score, $1.rank) > ($1.score, $0.rank) }
        .map { (id: $0.id, score: $0.score, byMeaning: $0.byMeaning) }
        let found = Set(fts)
        return (withWords, alike.filter { !found.contains($0.docID) }.map { (id: $0.docID, similarity: $0.score) })
    }

    /// The documents among `ids` that `text` concerns, the most first: those holding any of its words, in their text,
    /// name or labels, fused with their rank by meaning, then those alike to it in meaning alone (`fusedOrder`), as a
    /// search orders what it finds. A question is no search: it is written in sentences, so any of its words finds a
    /// document, and BM25 weighs each by how rare it is (Robertson and Zaragoza, "The Probabilistic Relevance Framework:
    /// BM25 and Beyond", 2009), so a common word counts for little. Without an embedding model, or when it fails, the
    /// words alone order them, and the relevance says why; documents `text` does not concern at all are left out.
    /// Ollama that cannot be reached is thrown, as is stopping: what asks has to wait for Ollama all the same.
    public func relevance(of text: String, among ids: [Int64]) async throws -> Relevance {
        guard !ids.isEmpty else { return Relevance(documents: [], semanticUsed: false, semanticUnavailableReason: Self.noDocuments) }
        let weights = config.bm25Weights.map { String($0) }.joined(separator: ", ")
        var fts: [Int64] = []
        if let match = FTSQueryBuilder.anyOf(text) {
            fts = try await database.reader.read { db in
                try Int64.fetchAll(db, sql: """
                    SELECT rowid FROM document_fts WHERE document_fts MATCH ? AND rowid IN (\(databaseQuestionMarks(count: ids.count)))
                    ORDER BY bm25(document_fts, \(weights))
                    """, arguments: StatementArguments([match]) + StatementArguments(ids))
            }
        }
        let meaning = try await alike(to: text.trimmingCharacters(in: .whitespacesAndNewlines), k: ids.count, waitingForOllama: true) { Set(ids) }
        let order = Self.fusedOrder(fts: fts, semantic: meaning.found, rrfK: config.rrfK, minSimilarity: config.semanticMinSimilarity)
        return Relevance(documents: order.withWords.map(\.id) + order.meaningOnly.map(\.id), semanticUsed: meaning.unavailable == nil,
                         semanticUnavailableReason: meaning.unavailable)
    }

    private func allowedIDs(_ filter: DocumentFilter) async throws -> Set<Int64>? {
        try await database.reader.read { db in
            let (sql, args) = try filter.sql(db)
            guard !sql.isEmpty else { return nil }
            return Set(try Int64.fetchAll(db, sql: "SELECT d.id FROM documents d WHERE 1=1 \(sql)", arguments: args))
        }
    }
}
