import Foundation
import GRDB

public struct DiagnosticsContents: Sendable, Codable, Hashable {
    public var logFiles: [String]
    public var traces: Int
    public var includesDocumentText: Bool
}

/// Writes a zip with logs, recent traces, the doctor report and settings, for a bug report. Without the user's consent
/// it holds nothing derived from a document or its file: no text, preview, metadata, name, path, identifier, label or
/// question (AGENTS.md §4.1). What it keeps is chosen by allow-list (`shareable`, `LogEntry.shareableFields`), so what
/// a new stage or log field records stays out until it is shown to come from no document.
public struct DiagnosticsExporter: Sendable {
    /// macOS's own archiver, which writes the zip (`man ditto`): nothing is added to the app to make one.
    static let dittoPath = "/usr/bin/ditto"
    /// The arguments that make `ditto` zip a folder, keeping the folder itself as the zip's top level.
    static let dittoZipArguments = ["-c", "-k", "--keepParent"]

    public let database: AppDatabase
    public let paths: AppPaths
    public let config: StatsConfig

    public init(database: AppDatabase, paths: AppPaths, config: StatsConfig) {
        self.database = database
        self.paths = paths
        self.config = config
    }

    public func export(to zipURL: URL, doctor: DoctorReport, settings: AppSettings,
                       includeDocumentText: Bool) async throws -> DiagnosticsContents {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("arrumator-diagnostics-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("arrumator-diagnostics", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        try JSON.prettyEncoder.encode(doctor).write(to: staging.appendingPathComponent("doctor.json"))
        try JSON.prettyEncoder.encode(settings).write(to: staging.appendingPathComponent("settings.json"))
        var logFiles: [String] = []
        let logsDir = staging.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        // A logs folder not made yet holds no logs.
        for file in (try? fm.contentsOfDirectory(at: paths.logsDirectory, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "jsonl" {
            let copy = logsDir.appendingPathComponent(file.lastPathComponent)
            if includeDocumentText {
                try fm.copyItem(at: file, to: copy)
            } else {
                try Self.shareableLog(try Data(contentsOf: file)).write(to: copy)
            }
            logFiles.append(file.lastPathComponent)
        }
        let limit = config.diagnosticsTraceLimit
        let traces = try await database.reader.read { db -> [String] in
            let traces = try TraceRecord.order(Column("started_at").desc).limit(limit).fetchAll(db)
            return try traces.map { t in
                let steps = try TraceStepRecord.filter(Column("trace_id") == t.id).order(Column("seq")).fetchAll(db)
                return try JSON.string(TraceExport(trace: Self.shareable(t), steps: Self.shareable(steps, includeDocumentText: includeDocumentText)))
            }
        }
        try Data(traces.joined(separator: "\n").utf8).write(to: staging.appendingPathComponent("traces.jsonl"))
        try await Self.zip(staging, to: zipURL)
        Log.info(.app, "Diagnostics exported", ["path": zipURL.path, "traces": String(traces.count)])
        return DiagnosticsContents(logFiles: logFiles, traces: traces.count, includesDocumentText: includeDocumentText)
    }

    /// Zips `folder` into `zipURL` with `ditto`, awaiting its end without holding a thread of the cooperative pool.
    private static func zip(_ folder: URL, to zipURL: URL) async throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: dittoPath)
        ditto.arguments = dittoZipArguments + [folder.path, zipURL.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            ditto.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try ditto.run()
            } catch {
                // A process that did not start never ends, so its handler is never called.
                ditto.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: zipURL.path]) }
    }
}

extension DiagnosticsExporter {
    /// Trace steps as an export or output for sharing holds them. Without the user's consent each keeps only what the
    /// app did and when: its place in the trace, its stage and status, when it started and how long it took. What it
    /// was given, what it gave and why it failed are left out whatever the stage: they carry the document's text, a
    /// preview of it, its metadata, its name and where it was filed, the identifiers read from it, its labels and the
    /// user's question. A field added to a step is left out until it is added here.
    public static func shareable(_ steps: [TraceStepRecord], includeDocumentText: Bool) -> [TraceStepRecord] {
        guard !includeDocumentText else { return steps }
        return steps.map { step in
            TraceStepRecord(id: step.id, traceId: step.traceId, seq: step.seq, stage: step.stage, status: step.status,
                            startedAt: step.startedAt, durationMs: step.durationMs, inputJson: nil, outputJson: nil, error: nil)
        }
    }

    /// A trace's header as an export holds it: which document, job and attempt it belongs to, how it began and ended,
    /// and the app, prompt, models and settings it ran with, none of which comes from a document. A field added to the
    /// header is left out until it is added here.
    public static func shareable(_ trace: TraceRecord) -> TraceRecord {
        TraceRecord(id: trace.id, docId: trace.docId, jobId: trace.jobId, attempt: trace.attempt, source: trace.source,
                    startedAt: trace.startedAt, finishedAt: trace.finishedAt, outcome: trace.outcome, appVersion: trace.appVersion,
                    promptVersion: trace.promptVersion, modelChat: trace.modelChat, modelVision: trace.modelVision,
                    modelEmbed: trace.modelEmbed, settingsJson: trace.settingsJson, totalMs: trace.totalMs)
    }

    /// A processing log, a JSON line per entry (`Log`), as an export without the user's consent holds it: each line
    /// keeps when it was written, its level, its category and its message, which is a constant (a `StaticString`,
    /// `Log.log`), and of its fields only those `LogEntry.shareableFields` names. A line that cannot be read,
    /// such as the last one of a log cut short, cannot be shown to hold nothing of a document, and is left out, as is a
    /// line an earlier version wrote with a History event's summary in its message (`isEarlierEvent`).
    static func shareableLog(_ log: Data) throws -> Data {
        var shared = Data()
        for line in log.split(separator: newline) {
            guard var entry = try? JSON.decoder.decode(ShareableLogLine.self, from: line), !isEarlierEvent(entry.msg) else { continue }
            entry.fields = entry.fields.filter { LogEntry.shareableFields.contains($0.key) }
            shared.append(try JSON.encoder.encode(entry))
            shared.append(newline)
        }
        return shared
    }

    private static let newline = UInt8(ascii: "\n")

    /// How versions 0.1.1 to 0.1.4 began the message they logged for every History event, "event <kind>: <summary>"
    /// (`HistoryStore`), its summary naming documents and labels; logs are kept `logging.keepDays`, so one of those
    /// versions may still be exported. No message the app logs now begins so.
    static let earlierEventPrefix = "event "
    static let earlierEventSeparator = ": "

    /// Whether `message` is one an earlier version logged for a History event, with its summary in it.
    static func isEarlierEvent(_ message: String) -> Bool {
        message.hasPrefix(earlierEventPrefix) && message.contains(earlierEventSeparator)
    }

    /// The parts of a log line an export keeps; `ts` is copied as written.
    private struct ShareableLogLine: Codable {
        var ts: String
        var level: LogLevel
        var cat: LogCategory
        var msg: String
        var fields: [String: String]
    }
}

public struct TraceExport: Sendable, Codable {
    public var trace: TraceRecord
    public var steps: [TraceStepRecord]

    public init(trace: TraceRecord, steps: [TraceStepRecord]) {
        self.trace = trace
        self.steps = steps
    }
}
