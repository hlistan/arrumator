import Foundation
import GRDB

public struct TraceHeader: Sendable {
    public var docID: Int64?
    public var jobID: Int64?
    public var attempt: Int
    public var source: TraceSource
    public var promptVersion: Int
    /// Fingerprint of the logic the model was given (`LogicStore.version`).
    public var logicVersion: String
    public var taxonomyVersion: Int
    public var models: ResolvedModels?
    public var settings: AppSettings

    public init(docID: Int64?, jobID: Int64?, attempt: Int, source: TraceSource, promptVersion: Int, logicVersion: String,
                taxonomyVersion: Int, models: ResolvedModels?, settings: AppSettings) {
        self.docID = docID
        self.jobID = jobID
        self.attempt = attempt
        self.source = source
        self.promptVersion = promptVersion
        self.logicVersion = logicVersion
        self.taxonomyVersion = taxonomyVersion
        self.models = models
        self.settings = settings
    }
}

/// Full processing trace of one document: one row per pipeline stage with inputs, outputs, timings and model I/O.
public struct TraceRecorder: TraceSink {
    public let database: AppDatabase
    public let appVersion: String

    public init(database: AppDatabase, appVersion: String) {
        self.database = database
        self.appVersion = appVersion
    }

    public func start(_ header: TraceHeader) async throws -> TraceContext {
        let id = try await database.writer.write { db in
            var t = TraceRecord(id: nil, docId: header.docID, jobId: header.jobID, attempt: header.attempt,
                                source: header.source.rawValue, startedAt: Date(), finishedAt: nil, outcome: nil,
                                appVersion: appVersion, promptVersion: header.promptVersion,
                                logicVersion: header.logicVersion, taxonomyVersion: header.taxonomyVersion, modelChat: header.models?.chat,
                                modelVision: header.models?.vision, modelEmbed: header.models?.embed,
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
                var r = TraceStepRecord(id: nil, traceId: traceID, seq: seq, stage: step.stage.rawValue, status: step.status.rawValue,
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
        do {
            try await database.writer.write { db in
                guard var t = try TraceRecord.fetchOne(db, key: id) else { return }
                let now = Date()
                t.finishedAt = now
                t.outcome = outcome
                t.totalMs = now.timeIntervalSince(t.startedAt) * 1000
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

    /// Clears raw prompt/response payloads older than `days`, keeping structured outputs.
    public func trimRawPayloads(olderThanDays days: Int) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        return try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE trace_steps SET input_json = NULL
                WHERE stage IN ('llm','vlm') AND input_json IS NOT NULL
                AND trace_id IN (SELECT id FROM traces WHERE started_at < ?)
                """, arguments: [cutoff])
            return db.changesCount
        }
    }
}
