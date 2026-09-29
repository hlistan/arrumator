import Foundation
import GRDB

/// How much a stop matters: a duplicate leaving early is the pipeline working, a failure is not.
public enum FunnelSeverity: String, Sendable, Codable, Hashable {
    /// The pipeline did its job by stopping here.
    case expected
    /// Nothing is wrong, but somebody has to act.
    case attention
    /// Something went wrong.
    case problem
}

/// Why a document stopped at a step instead of going further.
public struct FunnelStop: Sendable, Codable, Hashable, Identifiable {
    public var reason: String
    public var count: Int
    public var severity: FunnelSeverity
    public var id: String { reason }

    public init(reason: String, count: Int, severity: FunnelSeverity) {
        self.reason = reason
        self.count = count
        self.severity = severity
    }
}

/// One step of the funnel: how many documents reached it, how many got past it, and what it cost.
public struct FunnelStepStats: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var reached: Int
    public var passed: Int
    public var stoppedHere: [FunnelStop]
    public var warnings: Int
    public var errors: Int
    public var medianMs: Double
    public var p95Ms: Double
    /// Documents that arrived in the window at all, so the step can say what share of everything reached it.
    public var ofAll: Int

    public var dropped: Int { reached - passed }
    /// Share of the documents that reached this step and got past it.
    public var passRate: Double? { reached == 0 ? nil : Double(passed) / Double(reached) }
    /// Share of everything that arrived which reached this step.
    public var cumulativeShare: Double? { ofAll == 0 ? nil : Double(reached) / Double(ofAll) }
}

/// Who chose the folder: a learned rule, a near-identical past filing, the local model, or the user.
public struct DecisionSource: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var count: Int
    /// True when no model call was needed.
    public var learned: Bool
}

/// One period of the "how much is placed without the model" trend.
public struct FunnelTrendPoint: Sendable, Codable, Hashable, Identifiable {
    public var start: Date
    public var end: Date
    public var decided: Int
    public var withoutModel: Int
    public var id: Date { start }
    public var share: Double? { decided == 0 ? nil : Double(withoutModel) / Double(decided) }
}

/// The processing funnel over a time window, plus the numbers that say whether the app is learning.
public struct ProcessingFunnel: Sendable, Codable, Hashable {
    public var generatedAt: Date
    public var windowDays: Int
    public var documents: Int
    public var steps: [FunnelStepStats]
    public var decisions: [DecisionSource]
    public var trend: [FunnelTrendPoint]

    /// The step where most documents stopped, ignoring the last one.
    public var biggestDropOff: FunnelStepStats? {
        steps.dropLast().max { $0.dropped < $1.dropped }.flatMap { $0.dropped > 0 ? $0 : nil }
    }

    /// The step that takes the longest at the median.
    public var slowestStep: FunnelStepStats? {
        steps.max { $0.medianMs < $1.medianMs }.flatMap { $0.medianMs > 0 ? $0 : nil }
    }

    public var decidedWithoutModel: Int { decisions.filter(\.learned).reduce(0) { $0 + $1.count } }
    public var decidedTotal: Int { decisions.reduce(0) { $0 + $1.count } }
    /// Share of decisions made with no model call.
    public var withoutModelShare: Double? { decidedTotal == 0 ? nil : Double(decidedWithoutModel) / Double(decidedTotal) }
    /// Documents that went in and came out filed with nobody touching them.
    public var straightThrough: Int { steps.last?.reached ?? 0 }
    public var straightThroughShare: Double? { documents == 0 ? nil : Double(straightThrough) / Double(documents) }
    /// Below this many documents, shares are noise and only counts are worth showing.
    public func showsShares(minimum: Int) -> Bool { documents >= minimum }
}

extension StatsService {
    /// How a document that never finished is described in the funnel, and how much it matters.
    public static func stopReason(for status: DocumentStatus) -> (text: String, severity: FunnelSeverity) {
        switch status {
        case .duplicate: ("A copy of a file already filed", .expected)
        case .needsReview: ("Waiting for you to decide", .attention)
        case .failed: ("Could not be processed", .problem)
        case .held: ("Left for later", .attention)
        case .undone: ("Undone by you", .expected)
        case .missing: ("No longer on disk", .problem)
        case .arrived, .processing: ("Still being worked on", .expected)
        case .filed: ("Filed", .expected)
        }
    }

    /// How a decision maker is named in the funnel.
    public static func decisionSource(for decidedBy: DecidedBy) -> (name: String, learned: Bool) {
        switch decidedBy {
        case .rule: ("A learned rule", true)
        case .knnOnly: ("A near-identical past filing", true)
        case .llm: ("The local model", false)
        case .review, .user: ("You", false)
        case .dummy: ("A test stub", false)
        }
    }

    /// Builds the funnel for documents that arrived inside the window.
    public func funnel(days: Int, now: Date = Date()) async throws -> ProcessingFunnel {
        let cfg = config.funnel
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return try await database.reader.read { db in
            let documents = try Row.fetchAll(db, sql: """
                SELECT d.id AS id, d.status AS status, d.decided_by AS decided_by, d.added_at AS added_at,
                       (SELECT MAX(t.id) FROM traces t WHERE t.doc_id = d.id AND t.source = ?) AS trace_id
                FROM documents d WHERE d.added_at >= ?
                """, arguments: [TraceSource.ingest.rawValue, cutoff.unixSeconds])
            guard !documents.isEmpty else {
                return ProcessingFunnel(generatedAt: now, windowDays: days, documents: 0,
                                        steps: Self.emptySteps(cfg), decisions: [], trend: [])
            }

            // Every stage a document recorded, and what each cost.
            let traceIDs = documents.compactMap { $0["trace_id"] as Int64? }
            var stagesByTrace: [Int64: [String: (status: String, ms: Double)]] = [:]
            if !traceIDs.isEmpty {
                let placeholders = databaseQuestionMarks(count: traceIDs.count)
                for row in try Row.fetchAll(db, sql: """
                    SELECT trace_id, stage, status, SUM(duration_ms) AS ms FROM trace_steps
                    WHERE trace_id IN (\(placeholders)) GROUP BY trace_id, stage, status
                    """, arguments: StatementArguments(traceIDs)) {
                    let id: Int64 = row["trace_id"]
                    let stage: String = row["stage"]
                    let status: String = row["status"]
                    let ms: Double = row["ms"] ?? 0
                    var stages = stagesByTrace[id] ?? [:]
                    // An error anywhere in a stage is what matters; durations add up.
                    let previous = stages[stage]
                    let worst = Self.worse(previous?.status, status)
                    stages[stage] = (worst, (previous?.ms ?? 0) + ms)
                    stagesByTrace[id] = stages
                }
            }

            return Self.assemble(documents: documents, stagesByTrace: stagesByTrace, cfg: cfg,
                                 days: days, cutoff: cutoff, now: now)
        }
    }

    private static func emptySteps(_ cfg: FunnelConfig) -> [FunnelStepStats] {
        cfg.steps.map {
            FunnelStepStats(id: $0.id, title: $0.title, detail: $0.detail, reached: 0, passed: 0,
                            stoppedHere: [], warnings: 0, errors: 0, medianMs: 0, p95Ms: 0, ofAll: 0)
        }
    }

    /// `error` beats `warn` beats `ok` beats `skipped`.
    private static func worse(_ a: String?, _ b: String) -> String {
        let rank = ["skipped": 0, "ok": 1, "warn": 2, "error": 3]
        guard let a, (rank[a] ?? 0) >= (rank[b] ?? 0) else { return b }
        return a
    }

    private static func assemble(documents: [Row], stagesByTrace: [Int64: [String: (status: String, ms: Double)]],
                                 cfg: FunnelConfig, days: Int, cutoff: Date, now: Date) -> ProcessingFunnel {
        let stepStages = cfg.steps.map { Set($0.stages.map(\.rawValue)) }
        var reached = [Int](repeating: 0, count: cfg.steps.count)
        var warnings = [Int](repeating: 0, count: cfg.steps.count)
        var errors = [Int](repeating: 0, count: cfg.steps.count)
        var durations = [[Double]](repeating: [], count: cfg.steps.count)
        var stops = [[String: (count: Int, severity: FunnelSeverity)]](repeating: [:], count: cfg.steps.count)
        var sources: [String: (count: Int, learned: Bool)] = [:]

        for document in documents {
            let status = DocumentStatus(rawValue: document["status"] ?? "") ?? .processing
            let stages = (document["trace_id"] as Int64?).flatMap { stagesByTrace[$0] } ?? [:]

            // How far it got: the last step with a recorded stage. Arrival is implied by the document existing.
            var furthest = 0
            for (index, wanted) in stepStages.enumerated() {
                let recorded = stages.filter { wanted.contains($0.key) && $0.value.status != "skipped" }
                guard !recorded.isEmpty else { continue }
                furthest = max(furthest, index)
                if recorded.values.contains(where: { $0.status == "error" }) {
                    // A step that fails fast would otherwise read as a fast step.
                    errors[index] += 1
                } else {
                    durations[index].append(recorded.values.reduce(0) { $0 + $1.ms })
                    if recorded.values.contains(where: { $0.status == "warn" }) { warnings[index] += 1 }
                }
            }
            for index in 0...furthest { reached[index] += 1 }
            if status != .filed || furthest < cfg.steps.count - 1 {
                let reason = stopReason(for: status)
                let previous = stops[furthest][reason.text]?.count ?? 0
                stops[furthest][reason.text] = (previous + 1, reason.severity)
            }
            if let decided = (document["decided_by"] as String?).flatMap(DecidedBy.init(rawValue:)) {
                let source = decisionSource(for: decided)
                var entry = sources[source.name] ?? (0, source.learned)
                entry.count += 1
                sources[source.name] = entry
            }
        }

        let steps = cfg.steps.enumerated().map { index, step -> FunnelStepStats in
            let next = index + 1 < reached.count ? reached[index + 1] : reached[index] - stops[index].values.reduce(0) { $0 + $1.count }
            let sorted = durations[index].sorted()
            return FunnelStepStats(
                id: step.id, title: step.title, detail: step.detail, reached: reached[index],
                passed: max(0, min(next, reached[index])),
                stoppedHere: stops[index].map { FunnelStop(reason: $0.key, count: $0.value.count, severity: $0.value.severity) }
                    .sorted { $0.count > $1.count },
                warnings: warnings[index], errors: errors[index],
                medianMs: percentile(sorted, 0.5), p95Ms: percentile(sorted, 0.95), ofAll: documents.count)
        }

        let decisions = sources.map { DecisionSource(id: $0.key, count: $0.value.count, learned: $0.value.learned) }
            .sorted { $0.count > $1.count }
        return ProcessingFunnel(generatedAt: now, windowDays: days, documents: documents.count, steps: steps,
                                decisions: decisions,
                                trend: trend(documents: documents, cfg: cfg, cutoff: cutoff, now: now))
    }

    private static func trend(documents: [Row], cfg: FunnelConfig, cutoff: Date, now: Date) -> [FunnelTrendPoint] {
        let buckets = max(1, cfg.trendBuckets)
        let span = max(1, now.timeIntervalSince(cutoff)) / Double(buckets)
        var decided = [Int](repeating: 0, count: buckets)
        var learned = [Int](repeating: 0, count: buckets)
        for document in documents {
            guard let source = (document["decided_by"] as String?).flatMap(DecidedBy.init(rawValue:)) else { continue }
            let added = Date(unixSeconds: document["added_at"] ?? cutoff.unixSeconds)
            let index = min(buckets - 1, max(0, Int(added.timeIntervalSince(cutoff) / span)))
            decided[index] += 1
            if decisionSource(for: source).learned { learned[index] += 1 }
        }
        return (0..<buckets).map { index in
            let start = cutoff.addingTimeInterval(span * Double(index))
            return FunnelTrendPoint(start: start, end: start.addingTimeInterval(span),
                                    decided: decided[index], withoutModel: learned[index])
        }
    }
}

/// `?,?,?` for an `IN` clause.
func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
