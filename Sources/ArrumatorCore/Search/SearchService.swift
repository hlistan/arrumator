import Foundation
import GRDB

/// Markers wrapped around matched terms in snippets; the UI and CLI turn them into highlighting.
public enum SearchHighlight {
    private static let openScalar: Unicode.Scalar = "\u{E000}"
    private static let closeScalar: Unicode.Scalar = "\u{E001}"
    public static let open = String(openScalar)
    public static let close = String(closeScalar)

    /// Splits highlighted text into (segment, isMatch) runs, on one line (`DocumentLabel.oneLine`: no break or control
    /// character reaches a screen). A close marker with no open before it is dropped, an open inside a match is dropped,
    /// and a match left open runs to the end. Read by scalar: a marker is one, and a combining mark or a skin-tone
    /// modifier after it would join it into one `Character` that is no marker.
    public static func runs(_ text: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        var current = String.UnicodeScalarView()
        var inMatch = false
        func end() {
            if !current.isEmpty { out.append((String(current), inMatch)) }
            current = String.UnicodeScalarView()
        }
        for scalar in DocumentLabel.oneLine(text).unicodeScalars {
            switch scalar {
            case openScalar where !inMatch:
                end()
                inMatch = true
            case closeScalar where inMatch:
                end()
                inMatch = false
            case openScalar, closeScalar:
                break
            default:
                current.append(scalar)
            }
        }
        end()
        return out
    }

    /// `text` without the markers.
    public static func plain(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != openScalar && $0 != closeScalar }))
    }
}

public enum HitSource: String, Sendable, Codable, Hashable {
    case fullText, semantic
}

/// Whether a search compares documents with the query by meaning too, and how it asks Ollama for that.
public enum SearchMeaning: Sendable, Hashable {
    /// The words alone, with no model: what the app shows on every change of its field.
    case wordsOnly
    /// The words and meaning, asking Ollama once: when it is away, the meaning part ends at once. The app's search.
    case askOnce
    /// The words and meaning, asking Ollama again when it is away, after each of `ollama.retryDelays`. The command line's.
    case askRetrying
}

public struct SearchQuery: Sendable, Hashable {
    public var text: String
    public var filter: DocumentFilter
    public var meaning: SearchMeaning

    public init(text: String, filter: DocumentFilter = DocumentFilter(), meaning: SearchMeaning) {
        self.text = text
        self.filter = filter
        self.meaning = meaning
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

    /// Whether the document was found by its meaning alone, without the query's words: what puts it in the second
    /// section of the results, after the documents that hold the words.
    public var byMeaningAlone: Bool { sources == [.semantic] }
}

public struct SearchResults: Sendable, Hashable {
    public var hits: [SearchHit]
    /// Why documents were not compared by meaning too; nil when they were.
    public var withoutMeaning: WithoutMeaning?
    /// Whether more documents were found than `search.resultLimit`: `hits` holds the best of them.
    public var cut: Bool
    public var elapsedMs: Double

    /// Whether the query had nothing to look for, so none was looked for.
    public var nothingToLookFor: Bool { withoutMeaning == .nothingToLookFor }
}

/// The documents of a set that a text concerns, the most first (`SearchService.relevance`): whether they were compared
/// with it by meaning too, and, when they were not, why, as a search says (`SearchResults`).
public struct Relevance: Sendable, Hashable {
    public var documents: [Int64]
    public var withoutMeaning: WithoutMeaning?
}

/// Builds safe FTS5 MATCH expressions from user input: quoted terms, `"phrases"`, `field:term`, `field:"phrase"`, prefix
/// on the last term. A term with no letter or number is left out, and a query left with no term is nil: nothing to look
/// for. The fields are the full-text columns (`SearchService.columns`), a label's kind among them.
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
                guard hasSomethingToLookFor(phrase) else { continue }
                let expr = "\"" + phrase.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                parts.append(column.map { "\($0) : \(expr)" } ?? expr)
                continue
            }
            let cleaned = term.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "." }
            let word = String(String.UnicodeScalarView(cleaned))
            guard hasSomethingToLookFor(word) else { continue }
            var expr = "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            if isLast && word.count >= 2 { expr += " *" }
            parts.append(column.map { "\($0) : \(expr)" } ?? expr)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Whether `term` holds a letter or a number: what a term needs to be looked for, as `anyOf` has it. `-`, `.` and
    /// `%%` are not words.
    private static func hasSomethingToLookFor<S: StringProtocol>(_ term: S) -> Bool {
        term.contains { $0.isLetter || $0.isNumber }
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

    /// The documents that hold the query's words, fused with those alike to it in meaning (`fuse`), by the query's
    /// `meaning`. When they cannot be compared by meaning, as when Ollama is away, the words alone find them, and the
    /// results say why. A query with nothing to look for finds nothing and asks nothing. Stopping is thrown.
    public func search(_ query: SearchQuery) async throws -> SearchResults {
        let start = time.now()
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = FTSQueryBuilder.build(query.text) else {
            return SearchResults(hits: [], withoutMeaning: .nothingToLookFor, cut: false, elapsedMs: elapsedMs(since: start))
        }
        let fts = try await ftsHits(query, match: match)
        let meaning: (found: [(docID: Int64, score: Float)], without: WithoutMeaning?)
        switch query.meaning {
        case .wordsOnly: meaning = ([], tooShort(text) ? .tooShort : .notAsked)
        case .askOnce, .askRetrying:
            meaning = try await alike(to: text, k: config.ftsCandidateLimit, waitingForOllama: false, retrying: query.meaning == .askRetrying) {
                try await self.allowedIDs(query.filter)
            }
        }
        let fused = try await fuse(fts: fts, semantic: meaning.found)
        let elapsed = elapsedMs(since: start)
        Log.debug(.search, "Search", Self.logFields(elapsedMs: elapsed, words: fts.count, meaning: meaning.found.count, without: meaning.without))
        return SearchResults(hits: Array(fused.prefix(config.resultLimit)), withoutMeaning: meaning.without, cut: fused.count > config.resultLimit,
                             elapsedMs: elapsed)
    }

    /// What a search logs: how long it took, how many documents the words and the meaning found, and why meaning was not
    /// used. Never the query or a snippet: a search is no action, and what is looked for stays with the person.
    static func logFields(elapsedMs: Double, words: Int, meaning: Int, without: WithoutMeaning?) -> [String: String] {
        ["ms": String(format: "%.0f", elapsedMs), "fts": String(words), "semantic": String(meaning), "without": without?.rawValue ?? ""]
    }

    /// Whether `text` is shorter than `search.minSemanticQueryChars`: too short to mean anything.
    private func tooShort(_ text: String) -> Bool { text.count < config.minSemanticQueryChars }

    private func elapsedMs(since start: Date) -> Double { time.now().timeIntervalSince(start) * 1000 }

    /// The documents alike in meaning to `text`, the most alike first, at most `k`, among those `allowed` gives (all when
    /// it gives nil); or, when they cannot be compared by meaning, none, and why. Stopping is thrown, and so is Ollama being
    /// away when `waitingForOllama`, for what asks to wait for it all the same: at once, without asking it again meanwhile,
    /// as what asks says it waits for Ollama, and when it tries again. Ollama away is asked again only when `retrying`.
    private func alike(to text: String, k: Int, waitingForOllama: Bool, retrying: Bool,
                       among allowed: () async throws -> Set<Int64>?) async throws -> (found: [(docID: Int64, score: Float)], without: WithoutMeaning?) {
        guard !tooShort(text) else { return ([], .tooShort) }
        guard let embedder else { return ([], .noEmbeddingModel) }
        do {
            try await loadVectors(of: embedder.modelId)
        } catch {
            return try unreadable(error)
        }
        let among: Set<Int64>?
        do {
            among = try await allowed()
        } catch {
            return try unreadable(error)
        }
        guard await vectors.holdsAny(among: among) else { return ([], .noDocuments) }
        do {
            let vector = try await queryVector(text, embedder: embedder, retrying: retrying)
            return (try await vectors.topK(vector, model: embedder.modelId, k: k, allowed: among), nil)
        } catch let error as OllamaError where waitingForOllama && error.isTransient {
            throw error
        } catch {
            return try unreadable(error)
        }
    }

    /// The reason `failure` leaves documents without a comparison by meaning, logged; stopping is thrown instead.
    private func unreadable(_ failure: any Error) throws -> (found: [(docID: Int64, score: Float)], without: WithoutMeaning?) {
        if failure is CancellationError || Task.isCancelled { throw failure }
        let reason = WithoutMeaning(failure: failure)
        Log.warning(.search, "Search by meaning unavailable", ["reason": reason.rawValue, "error": failure.localizedDescription])
        return ([], reason)
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

    private func ftsHits(_ query: SearchQuery, match: String) async throws -> [SearchHit] {
        let limit = config.ftsCandidateLimit
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
                // SQLite cuts the start of the text when the words are in no part of it, a name or a label: that shows nothing found.
                let snippet: String = row["snip"] ?? ""
                return SearchHit(document: try DocumentRecord(row: row), score: -(row["rank"] as Double? ?? 0),
                                 snippet: snippet.contains(open) ? snippet : "", sources: [.fullText])
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
        guard !ids.isEmpty else { return Relevance(documents: [], withoutMeaning: .noDocuments) }
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
        let meaning = try await alike(to: text.trimmingCharacters(in: .whitespacesAndNewlines), k: ids.count, waitingForOllama: true, retrying: false) { Set(ids) }
        let order = Self.fusedOrder(fts: fts, semantic: meaning.found, rrfK: config.rrfK, minSimilarity: config.semanticMinSimilarity)
        return Relevance(documents: order.withWords.map(\.id) + order.meaningOnly.map(\.id), withoutMeaning: meaning.without)
    }

    private func allowedIDs(_ filter: DocumentFilter) async throws -> Set<Int64>? {
        try await database.reader.read { db in
            let (sql, args) = try filter.sql(db)
            guard !sql.isEmpty else { return nil }
            return Set(try Int64.fetchAll(db, sql: "SELECT d.id FROM documents d WHERE 1=1 \(sql)", arguments: args))
        }
    }
}
