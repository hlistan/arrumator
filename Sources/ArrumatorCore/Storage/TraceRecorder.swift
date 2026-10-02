import Foundation
import GRDB

public struct TraceHeader: Sendable {
    public var docID: Int64?
    public var jobID: Int64?
    public var attempt: Int
    public var source: TraceSource
    public var promptVersion: Int
    /// The profile whose models read, stamped on the trace; nil when it could not be told.
    public var models: ModelProfile?
    public var settings: AppSettings

    public init(docID: Int64?, jobID: Int64?, attempt: Int, source: TraceSource, promptVersion: Int, models: ModelProfile?,
                settings: AppSettings) {
        self.docID = docID
        self.jobID = jobID
        self.attempt = attempt
        self.source = source
        self.promptVersion = promptVersion
        self.models = models
        self.settings = settings
    }
}

/// Full processing trace of one document: one row per pipeline stage with inputs, outputs, timings and model I/O.
public struct TraceRecorder: TraceSink {
    public let database: AppDatabase
    public let appVersion: String
    public let time: any TimeSource

    public init(database: AppDatabase, appVersion: String, time: any TimeSource) {
        self.database = database
        self.appVersion = appVersion
        self.time = time
    }

    public func start(_ header: TraceHeader) async throws -> TraceContext {
        let now = time.now()
        let id = try await database.writer.write { db in
            var t = TraceRecord(id: nil, docId: header.docID, jobId: header.jobID, attempt: header.attempt,
                                source: header.source.rawValue, startedAt: now, finishedAt: nil, outcome: nil,
                                appVersion: appVersion, promptVersion: header.promptVersion, modelChat: header.models?.chatModel,
                                modelVision: header.models?.visionModel, modelEmbed: header.models?.embedModel,
                                settingsJson: JSON.string(header.settings), totalMs: nil)
            try t.insert(db)
            return t.id ?? 0
        }
        return TraceContext(traceID: id, sink: self)
    }

    public func append(traceID: Int64, step: TraceStep) async {
        do {
            try await database.writer.write { db in
                let seq = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM trace_steps WHERE trace_id = ?",
                                           arguments: [traceID]) ?? 1
                var r = TraceStepRecord(id: nil, traceId: traceID, seq: seq, stage: step.stage.rawValue, status: step.status,
                                        startedAt: step.startedAt, durationMs: step.durationMs, inputJson: step.input,
                                        outputJson: step.output, error: step.error)
                try r.insert(db)
            }
        } catch {
            Log.error(.db, "Failed to record trace step", ["trace": String(traceID), "stage": step.stage.rawValue,
                                                          "error": error.localizedDescription])
        }
    }

    public func finish(_ context: TraceContext, outcome: String, docID: Int64?) async {
        guard let id = context.traceID else { return }
        let now = time.now()
        do {
            try await database.writer.write { db in
                guard var t = try TraceRecord.fetchOne(db, key: id) else { return }
                t.finishedAt = now
                t.outcome = outcome
                t.totalMs = t.startedAt.milliseconds(until: now)
                if let docID { t.docId = docID }
                try t.update(db)
            }
        } catch {
            Log.error(.db, "Failed to finish trace", ["trace": String(id), "error": error.localizedDescription])
        }
    }

    public func trace(id: Int64) async throws -> (TraceRecord, [TraceStepRecord])? {
        try await database.reader.read { db in
            guard let t = try TraceRecord.fetchOne(db, key: id) else { return nil }
            let steps = try TraceStepRecord.filter(Column("trace_id") == id).order(Column("seq")).fetchAll(db)
            return (t, steps)
        }
    }

    public func traces(docID: Int64) async throws -> [TraceRecord] {
        try await database.reader.read { db in
            try TraceRecord.filter(Column("doc_id") == docID).order(Column("started_at").desc).fetchAll(db)
        }
    }

    /// Clears what steps that talked to a model sent it and got back (`TraceStep.exchangeKey`: the prompts, which hold
    /// the document's text, and the raw answers) in traces older than `days`, keeping what each step concluded.
    /// Returns how many steps it cleared.
    public func trimRawPayloads(olderThanDays days: Int) async throws -> Int {
        let cutoff = time.now().addingTimeInterval(-Double(days) * Units.secondsPerDay)
        let stages = TraceStage.allCases.filter(\.exchangesWithModel).map(\.rawValue)
        let path = "$." + TraceStep.exchangeKey
        return try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE trace_steps SET output_json = json_remove(output_json, ?)
                WHERE stage IN (\(databaseQuestionMarks(count: stages.count))) AND json_valid(output_json)
                AND json_type(output_json, ?) IS NOT NULL
                AND trace_id IN (SELECT id FROM traces WHERE started_at < ?)
                """, arguments: StatementArguments([path] + stages + [path, cutoff.unixSeconds]))
            return db.changesCount
        }
    }
}
