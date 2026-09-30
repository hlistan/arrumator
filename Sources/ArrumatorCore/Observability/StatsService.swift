import Foundation
import GRDB

public struct StageLatency: Sendable, Codable, Hashable {
    public var stage: String
    public var count: Int
    public var p50Ms: Double
    public var p95Ms: Double
}

public struct Insights: Sendable, Codable, Hashable {
    public var generatedAt: Date
    public var documents: Int
    public var statuses: [String: Int]
    /// Documents the model labelled, and those it has not (filed before labels, or without a valid answer).
    public var labelled: Int
    public var unlabelled: Int
    /// Labels of each kind across the archive.
    public var labelsByKind: [String: Int]
    /// Documents whose name or details the user corrected, and those the user confirmed as they were.
    public var corrected: Int
    public var confirmed: Int
    /// The user's rules about labels, by what they decide (`LabelRuleAction`).
    public var labelRules: [String: Int]
    /// Labels the model gave that the rules or the archive's vocabulary changed or dropped (`consolidate` steps traced).
    public var labelsTidied: Int
    public var latency: [StageLatency]
    public var meanOCRConfidence: Double?
    public var warnings: [String: Int]
}

public struct StatsService: Sendable {
    public let database: AppDatabase
    public let config: StatsConfig

    public init(database: AppDatabase, config: StatsConfig) {
        self.database = database
        self.config = config
    }

    public func insights(now: Date = Date()) async throws -> Insights {
        try await database.reader.read { db in
            let documents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents") ?? 0
            let statuses = try Self.histogram(db, sql: "SELECT status, COUNT(*) FROM documents GROUP BY 1")
            let labelled = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents WHERE labels_json IS NOT NULL") ?? 0
            let unlabelled = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM documents WHERE labels_json IS NULL AND content_json IS NOT NULL
                """) ?? 0
            let labelsByKind = try Self.histogram(db, sql: """
                SELECT json_extract(l.value, '$.kind'), COUNT(*) FROM documents d, json_each(d.labels_json) l
                WHERE d.labels_json IS NOT NULL GROUP BY 1
                """)
            let userEvents = { (kind: EventKind) in
                try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT doc_id) FROM events WHERE kind = ?", arguments: [kind.rawValue]) ?? 0
            }
            let labelRules = try Self.histogram(db, sql: "SELECT action, COUNT(*) FROM label_rules GROUP BY 1")
            let labelsTidied = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(json_array_length(output_json, '$.changes')), 0) FROM trace_steps
                WHERE stage = ? AND output_json IS NOT NULL
                """, arguments: [TraceStage.consolidate.rawValue]) ?? 0
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
            return Insights(generatedAt: now, documents: documents, statuses: statuses, labelled: labelled, unlabelled: unlabelled,
                            labelsByKind: labelsByKind, corrected: try userEvents(.corrected), confirmed: try userEvents(.markedCorrect),
                            labelRules: labelRules, labelsTidied: labelsTidied,
                            latency: latency, meanOCRConfidence: ocr, warnings: warnings)
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
