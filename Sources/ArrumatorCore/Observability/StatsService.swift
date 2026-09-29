import Foundation
import GRDB

public struct AccuracyWindow: Sendable, Codable, Hashable {
    public var days: Int
    public var autoFiled: Int
    public var corrected: Int
    public var accuracy: Double?
}

public struct ConfusionPair: Sendable, Codable, Hashable {
    public var from: String
    public var to: String
    public var count: Int
}

public struct BandStats: Sendable, Codable, Hashable {
    public var band: String
    public var total: Int
    public var corrected: Int
}

public struct ThresholdWhatIf: Sendable, Codable, Hashable {
    public var autoThreshold: Double
    public var autoShare: Double
    public var autoAccuracy: Double?
}

public struct StageLatency: Sendable, Codable, Hashable {
    public var stage: String
    public var count: Int
    public var p50Ms: Double
    public var p95Ms: Double
}

public struct FolderHealth: Sendable, Codable, Hashable {
    public var code: String
    public var name: String
    public var documents: Int
    public var correctionsIn: Int
    public var correctionsOut: Int
    public var userEdited: Bool
}

public struct FolderOverlap: Sendable, Codable, Hashable {
    public var a: String
    public var b: String
    public var similarity: Double
}

public struct Insights: Sendable, Codable, Hashable {
    public var generatedAt: Date
    public var documents: Int
    public var decidedBy: [String: Int]
    public var statuses: [String: Int]
    public var accuracy: [AccuracyWindow]
    public var accuracyByLanguage: [String: Double]
    public var confusion: [ConfusionPair]
    public var bands: [BandStats]
    public var whatIf: [ThresholdWhatIf]
    public var latency: [StageLatency]
    public var meanOCRConfidence: Double?
    public var warnings: [String: Int]
    public var rules: Int
    public var ruleHits: Int
    public var ruleContradictions: Int
    public var meanKNNAgreement: Double?
    public var folders: [FolderHealth]
    public var overlaps: [FolderOverlap]
}

/// Aggregates traces, documents and corrections into the numbers that tell where the pipeline needs tuning.
/// A document counts as "correct" unless the user later moved it to a different folder.
public struct StatsService: Sendable {
    public let database: AppDatabase
    public let config: StatsConfig

    public init(database: AppDatabase, config: StatsConfig) {
        self.database = database
        self.config = config
    }

    /// Decisions made without the user.
    static let automaticDeciders: [DecidedBy] = [.llm, .rule, .knnOnly]
    /// Corrections that express "the app put it in the wrong place".
    static let relocatingSources: [CorrectionSource] = [.review, .moveTo, .finderMove, .bulkMove]
    static let automatic = sqlList(automaticDeciders.map(\.rawValue))
    static let correctionSources = sqlList(relocatingSources.map(\.rawValue))

    private static func sqlList(_ values: [String]) -> String {
        "(" + values.map { "'\($0)'" }.joined(separator: ",") + ")"
    }

    public func insights(now: Date = Date()) async throws -> Insights {
        let cfg = config
        return try await database.reader.read { db in
            let documents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents") ?? 0
            let decidedBy = try Self.histogram(db, sql: "SELECT COALESCE(decided_by,'none'), COUNT(*) FROM documents GROUP BY 1")
            let statuses = try Self.histogram(db, sql: "SELECT status, COUNT(*) FROM documents GROUP BY 1")
            let correctedIDs = Set(try Int64.fetchAll(db, sql: """
                SELECT DISTINCT doc_id FROM corrections WHERE source IN \(Self.correctionSources)
                AND (from_folder_id IS NULL OR to_folder_id IS NULL OR from_folder_id != to_folder_id)
                """))
            let automaticDocs = try Row.fetchAll(db, sql: """
                SELECT id, filed_at, confidence, band, language FROM documents
                WHERE decided_by IN \(Self.automatic) AND filed_at IS NOT NULL
                """)
            let accuracy = cfg.windowsDays.map { days -> AccuracyWindow in
                let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
                let inWindow = automaticDocs.filter { ($0["filed_at"] as Double? ?? 0) >= cutoff && ($0["band"] as String?) != "review" }
                let corrected = inWindow.filter { correctedIDs.contains($0["id"]) }.count
                return AccuracyWindow(days: days, autoFiled: inWindow.count, corrected: corrected,
                                      accuracy: inWindow.isEmpty ? nil : 1 - Double(corrected) / Double(inWindow.count))
            }
            var byLanguage: [String: (Int, Int)] = [:]
            for row in automaticDocs where (row["band"] as String?) != "review" {
                let lang: String = row["language"] ?? "und"
                var entry = byLanguage[lang] ?? (0, 0)
                entry.0 += 1
                if correctedIDs.contains(row["id"]) { entry.1 += 1 }
                byLanguage[lang] = entry
            }
            let bands = Dictionary(grouping: automaticDocs) { $0["band"] as String? ?? "none" }.map { band, rows in
                BandStats(band: band, total: rows.count, corrected: rows.filter { correctedIDs.contains($0["id"]) }.count)
            }.sorted { $0.band < $1.band }
            let scored = automaticDocs.compactMap { row -> (Double, Bool)? in
                guard let c: Double = row["confidence"] else { return nil }
                return (c, !correctedIDs.contains(row["id"]))
            }
            let whatIf = cfg.whatIfAutoThresholds.map { t -> ThresholdWhatIf in
                let auto = scored.filter { $0.0 >= t }
                return ThresholdWhatIf(autoThreshold: t, autoShare: scored.isEmpty ? 0 : Double(auto.count) / Double(scored.count),
                                       autoAccuracy: auto.isEmpty ? nil : Double(auto.filter(\.1).count) / Double(auto.count))
            }
            let confusion = try Row.fetchAll(db, sql: """
                SELECT COALESCE(ff.code, '—') AS f, COALESCE(tf.code, '—') AS t, COUNT(*) AS n FROM corrections c
                LEFT JOIN folders ff ON ff.id = c.from_folder_id LEFT JOIN folders tf ON tf.id = c.to_folder_id
                WHERE c.source IN \(Self.correctionSources) AND (c.from_folder_id IS NULL OR c.from_folder_id != c.to_folder_id)
                GROUP BY 1, 2 ORDER BY n DESC LIMIT ?
                """, arguments: [cfg.confusionPairsLimit]).map { ConfusionPair(from: $0["f"], to: $0["t"], count: $0["n"]) }
            var durations: [String: [Double]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT stage, duration_ms FROM trace_steps WHERE status != 'skipped'") {
                durations[row["stage"], default: []].append(row["duration_ms"])
            }
            let latency = durations.map { stage, values -> StageLatency in
                let sorted = values.sorted()
                return StageLatency(stage: stage, count: sorted.count, p50Ms: Self.percentile(sorted, 0.5),
                                    p95Ms: Self.percentile(sorted, 0.95))
            }.sorted { $0.stage < $1.stage }
            let ocr = try Double.fetchOne(db, sql: """
                SELECT AVG(json_extract(content_json, '$.ocr.meanConfidence')) FROM documents
                WHERE json_extract(content_json, '$.ocr.meanConfidence') IS NOT NULL
                """)
            let warnings = try Self.histogram(db, sql: """
                SELECT json_extract(w.value, '$.code'), COUNT(*) FROM documents d, json_each(d.content_json, '$.warnings') w
                WHERE d.content_json IS NOT NULL GROUP BY 1
                """)
            let ruleRow = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, COALESCE(SUM(hits),0) AS h, COALESCE(SUM(contradictions),0) AS c FROM rules WHERE forgotten = 0")
            let knn = try Double.fetchOne(db, sql: """
                SELECT AVG(json_extract(decision_json, '$.confidence.knnAgreement')) FROM documents
                WHERE json_extract(decision_json, '$.confidence.knnAgreement') IS NOT NULL
                """)
            let folders = try Row.fetchAll(db, sql: """
                SELECT f.code, f.name, f.user_edited,
                  (SELECT COUNT(*) FROM documents d WHERE d.folder_id = f.id AND d.status = 'filed') AS docs,
                  (SELECT COUNT(*) FROM corrections c WHERE c.to_folder_id = f.id AND c.source IN \(Self.correctionSources)
                     AND (c.from_folder_id IS NULL OR c.from_folder_id != f.id)) AS cin,
                  (SELECT COUNT(*) FROM corrections c WHERE c.from_folder_id = f.id AND c.source IN \(Self.correctionSources)
                     AND (c.to_folder_id IS NULL OR c.to_folder_id != f.id)) AS cout
                FROM folders f WHERE f.role IS NULL AND f.origin != ? AND f.is_archived = 0 ORDER BY f.rel_path
                """, arguments: [FolderOrigin.system.rawValue]).map { FolderHealth(code: $0["code"], name: $0["name"], documents: $0["docs"], correctionsIn: $0["cin"],
                                        correctionsOut: $0["cout"], userEdited: $0["user_edited"]) }
            let embeddings = try Row.fetchAll(db, sql: """
                SELECT f.code, e.vector FROM folder_embeddings e JOIN folders f ON f.id = e.folder_id WHERE f.is_archived = 0
                """).map { ($0["code"] as String, VectorCodec.decode($0["vector"])) }
            var overlaps: [FolderOverlap] = []
            for i in embeddings.indices {
                for j in embeddings.indices where j > i {
                    let s = Double(VectorCodec.dot(embeddings[i].1, embeddings[j].1))
                    if s >= cfg.folderOverlapSimilarity {
                        overlaps.append(FolderOverlap(a: embeddings[i].0, b: embeddings[j].0, similarity: s))
                    }
                }
            }
            return Insights(generatedAt: now, documents: documents, decidedBy: decidedBy, statuses: statuses, accuracy: accuracy,
                            accuracyByLanguage: byLanguage.mapValues { $0.0 == 0 ? 0 : 1 - Double($0.1) / Double($0.0) },
                            confusion: confusion, bands: bands, whatIf: whatIf, latency: latency, meanOCRConfidence: ocr,
                            warnings: warnings, rules: ruleRow?["n"] ?? 0, ruleHits: ruleRow?["h"] ?? 0,
                            ruleContradictions: ruleRow?["c"] ?? 0, meanKNNAgreement: knn, folders: folders,
                            overlaps: overlaps.sorted { $0.similarity > $1.similarity })
        }
    }

    private static func histogram(_ db: Database, sql: String) throws -> [String: Int] {
        Dictionary(try Row.fetchAll(db, sql: sql).map { ($0[0] as String? ?? "none", $0[1] as Int) }, uniquingKeysWith: +)
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
        return sorted[index]
    }
}
