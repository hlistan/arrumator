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
    public var semanticUsed: Bool
    public var semanticUnavailableReason: String?
    public var elapsedMs: Double
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

    /// `jurisdiction:`, a field's name and the colon that ends it.
    private static func isField(_ word: String) -> Bool {
        word.hasSuffix(":") && fields.contains(String(word.dropLast()).lowercased())
    }
}

/// Hybrid search: FTS5 BM25 (instant) fused with embedding similarity via Reciprocal Rank Fusion.
public actor SearchService {
    /// The columns of the full-text index, in its order (`AppDatabase.migrator`): each can be searched on its own as
    /// `column:term`, and `SearchConfig.bm25Weights` weighs them in this order.
    public static let columns = ["title", "correspondent", "filename", "body"] + LabelKind.allCases.map(\.rawValue)

    private let database: AppDatabase
    private let vectors: VectorIndex
    private var embedder: (any Embedder)?
    private let config: SearchConfig
    private var cache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []

    public init(database: AppDatabase, vectors: VectorIndex, embedder: (any Embedder)?, config: SearchConfig) {
        self.database = database
        self.vectors = vectors
        self.embedder = embedder
        self.config = config
    }

    public func setEmbedder(_ embedder: (any Embedder)?) {
        self.embedder = embedder
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Full-text phase only (fast path for type-ahead).
    public func fullText(_ query: SearchQuery) async throws -> SearchResults {
        let start = Date()
        let hits = try await ftsHits(query)
        return SearchResults(hits: Array(hits.prefix(config.resultLimit)), semanticUsed: false, semanticUnavailableReason: nil,
                             elapsedMs: Date().timeIntervalSince(start) * 1000)
    }

    public func search(_ query: SearchQuery) async throws -> SearchResults {
        let start = Date()
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fts = try await ftsHits(query)
        var reason: String?
        var semantic: [(docID: Int64, score: Float)] = []
        if !query.semantic {
            reason = "disabled"
        } else if text.count < config.minSemanticQueryChars {
            reason = "query too short"
        } else if let embedder {
            do {
                let vector = try await queryVector(text, embedder: embedder)
                let allowed = try await allowedIDs(query.filter)
                semantic = await vectors.topK(vector, k: config.ftsCandidateLimit, allowed: allowed)
            } catch {
                reason = error.localizedDescription
                Log.warning(.search, "Semantic search unavailable", ["error": reason ?? ""])
            }
        } else {
            reason = "no embedding model"
        }
        let fused = try await fuse(fts: fts, semantic: semantic)
        let elapsed = Date().timeIntervalSince(start) * 1000
        Log.debug(.search, "Search", ["ms": String(format: "%.0f", elapsed), "fts": String(fts.count),
                                      "semantic": String(semantic.count)])
        return SearchResults(hits: Array(fused.prefix(config.resultLimit)), semanticUsed: reason == nil,
                             semanticUnavailableReason: reason, elapsedMs: elapsed)
    }

    private func queryVector(_ text: String, embedder: any Embedder) async throws -> [Float] {
        let key = embedder.modelId + "\u{1}" + text
        if let hit = cache[key] { return hit }
        guard let vector = try await embedder.embed([text]).first else { throw OllamaError.emptyResponse }
        cache[key] = vector
        cacheOrder.append(key)
        if cacheOrder.count > config.queryCacheSize { cache[cacheOrder.removeFirst()] = nil }
        return vector
    }

    private func ftsHits(_ query: SearchQuery) async throws -> [SearchHit] {
        let (whereSQL, whereArgs) = Self.filterSQL(query.filter)
        let limit = config.ftsCandidateLimit
        guard let match = FTSQueryBuilder.build(query.text) else {
            return try await database.reader.read { db in
                try DocumentRecord.fetchAll(db, sql: "SELECT d.* FROM documents d WHERE 1=1 \(whereSQL) ORDER BY d.added_at DESC LIMIT ?",
                                            arguments: whereArgs + [limit])
                    .map { SearchHit(document: $0, score: 0, snippet: "", sources: []) }
            }
        }
        let weights = config.bm25Weights.map { String($0) }.joined(separator: ", ")
        let open = SearchHighlight.open
        let close = SearchHighlight.close
        let tokens = config.snippetTokens
        return try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.*, bm25(document_fts, \(weights)) AS rank,
                       snippet(document_fts, 3, ?, ?, '…', ?) AS snip
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

    /// Documents that contain the query's words come first, ordered by reciprocal rank fusion (Cormack et al., SIGIR
    /// 2009) of their full-text rank and, when alike enough, their rank by meaning. Documents found by meaning alone
    /// follow, most similar first. Similarity is cosine, so every query has nearest neighbours; only those at or above
    /// `semanticMinSimilarity` are found, which is the similarity floor Elasticsearch's kNN search applies for the same
    /// reason (its `similarity` parameter).
    private func fuse(fts: [SearchHit], semantic: [(docID: Int64, score: Float)]) async throws -> [SearchHit] {
        let alike = semantic.filter { Double($0.score) >= config.semanticMinSimilarity }
        guard !alike.isEmpty else { return fts }
        let meaningRank = Dictionary(alike.enumerated().map { ($1.docID, $0) }, uniquingKeysWith: min)
        let reciprocal = { (rank: Int) in 1 / (self.config.rrfK + Double(rank + 1)) }
        let withWords = fts.enumerated().map { rank, hit in
            var fused = hit
            fused.score = reciprocal(rank) + (meaningRank[hit.id].map(reciprocal) ?? 0)
            if meaningRank[hit.id] != nil { fused.sources.insert(.semantic) }
            return (rank: rank, hit: fused)
        }
        .sorted { ($0.hit.score, $1.rank) > ($1.hit.score, $0.rank) }
        .map(\.hit)
        let found = Set(fts.map(\.id))
        let meaningOnly = alike.filter { !found.contains($0.docID) }
        guard !meaningOnly.isEmpty else { return withWords }
        let ids = meaningOnly.map(\.docID)
        let docs = try await DocumentStore(database: database).documents(ids: ids)
        let bodies = try await database.reader.read { [ids] db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
                SELECT doc_id, substr(body, 1, ?) AS b FROM document_text WHERE doc_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: [config.vectorSnippetChars] + StatementArguments(ids)).map { ($0["doc_id"] as Int64, $0["b"] as String? ?? "") })
        }
        return withWords + meaningOnly.compactMap { item in
            docs[item.docID].map { SearchHit(document: $0, score: Double(item.score), snippet: bodies[item.docID] ?? "",
                                             sources: [.semantic]) }
        }
    }

    private func allowedIDs(_ filter: DocumentFilter) async throws -> Set<Int64>? {
        let (sql, args) = Self.filterSQL(filter)
        guard !sql.isEmpty else { return nil }
        return try await database.reader.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT d.id FROM documents d WHERE 1=1 \(sql)", arguments: args))
        }
    }

    static func filterSQL(_ f: DocumentFilter) -> (String, StatementArguments) {
        var sql = ""
        var args = StatementArguments()
        func inList<T: DatabaseValueConvertible>(_ column: String, _ values: Set<T>) {
            sql += " AND d.\(column) IN (\(values.map { _ in "?" }.joined(separator: ",")))"
            for v in values { _ = args.append(contentsOf: [v]) }
        }
        if let v = f.folderIDs { inList("folder_id", v) }
        if let v = f.statuses { inList("status", Set(v.map(\.rawValue))) }
        if let v = f.docTypes { inList("doc_type", v) }
        if let v = f.correspondents { inList("correspondent", v) }
        if let v = f.languages { inList("language", v) }
        if let v = f.dateFrom { sql += " AND d.doc_date >= ?"; _ = args.append(contentsOf: [v]) }
        if let v = f.dateTo { sql += " AND d.doc_date <= ?"; _ = args.append(contentsOf: [v]) }
        return (sql, args)
    }
}
