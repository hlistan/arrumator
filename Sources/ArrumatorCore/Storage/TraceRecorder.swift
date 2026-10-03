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

    /// How a trace of work that waits for Ollama to come back ends: the next attempt at the same work takes it up
    /// (`start(_:resuming:)`).
    public static let waitingOutcome = "waiting"

    public func start(_ header: TraceHeader) async throws -> TraceContext {
        try await start(header, resuming: nil)
    }

    /// Starts a trace of `header`, or takes up `previous` when it ended waiting for Ollama (`waitingOutcome`), as an item of
    /// a queue that waits is tried again every `ingest.retryDelays.last` seconds for as long as Ollama is away: the trace
    /// starts over as the next attempt, `attempt` counting those made, rather than one more trace for every attempt. What
    /// the attempt before recorded goes, as the next says the same and more: it found Ollama away, which the log keeps.
    public func start(_ header: TraceHeader, resuming previous: Int64?) async throws -> TraceContext {
        let now = time.now()
        let id = try await database.writer.write { db in
            if let previous, var waiting = try TraceRecord.fetchOne(db, key: previous), waiting.outcome == Self.waitingOutcome {
                try TraceStepRecord.filter(Column("trace_id") == previous).deleteAll(db)
                waiting.attempt += 1
                waiting.startedAt = now
                waiting.finishedAt = nil
                waiting.outcome = nil
                waiting.totalMs = nil
                waiting.appVersion = appVersion
                waiting.promptVersion = header.promptVersion
                waiting.modelChat = header.models?.chatModel
                waiting.modelVision = header.models?.visionModel
                waiting.modelEmbed = header.models?.embedModel
                waiting.settingsJson = try JSON.string(header.settings)
                try waiting.update(db)
                return previous
            }
            var t = TraceRecord(id: nil, docId: header.docID, jobId: header.jobID, attempt: header.attempt,
                                source: header.source.rawValue, startedAt: now, finishedAt: nil, outcome: nil,
                                appVersion: appVersion, promptVersion: header.promptVersion, modelChat: header.models?.chatModel,
                                modelVision: header.models?.visionModel, modelEmbed: header.models?.embedModel,
                                settingsJson: try JSON.string(header.settings), totalMs: nil)
            try t.insert(db)
            return t.id ?? 0
        }
        return TraceContext(traceID: id, sink: self)
    }

    /// Records `step`, whatever the work that records it is asked meanwhile (`recorded`).
    public func append(traceID: Int64, step: TraceStep) async {
        do {
            try await recorded { db in
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

    /// Ends the trace with `outcome`, whatever the work it traces is asked meanwhile (`recorded`).
    public func finish(_ context: TraceContext, outcome: String, docID: Int64?) async {
        guard let id = context.traceID else { return }
        let now = time.now()
        do {
            try await recorded { db in
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

    /// Writes `change` whatever the work that records it is asked meanwhile. A stop cancels the database accesses the
    /// stopped task makes ("`CancellationError` if the task is cancelled", GRDB's `DatabaseWriter.write`), so the trace of
    /// work that was stopped would lose the step that says how far it came, such as the answer a question had when the
    /// user stopped it, and how it ended. The write runs as a task of its own, which "doesn't have a parent task" (The
    /// Swift Programming Language › Concurrency › Unstructured Concurrency), as filing does (`DocumentFiler.file`): one
    /// short write, which the stop then waits for.
    private func recorded(_ change: @escaping @Sendable (Database) throws -> Void) async throws {
        let database = database
        try await Task { try await database.writer.write(change) }.value
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
