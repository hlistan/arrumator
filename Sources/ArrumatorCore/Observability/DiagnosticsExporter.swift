import Foundation
import GRDB

public struct DiagnosticsContents: Sendable, Codable, Hashable {
    public var logFiles: [String]
    public var traces: Int
    public var includesDocumentText: Bool
}

/// Writes a zip with logs, recent traces, the doctor report, settings and the taxonomy snapshot.
/// Document text is included only when explicitly requested.
public struct DiagnosticsExporter: Sendable {
    public let database: AppDatabase
    public let paths: AppPaths
    public let config: StatsConfig

    public init(database: AppDatabase, paths: AppPaths, config: StatsConfig) {
        self.database = database
        self.paths = paths
        self.config = config
    }

    public func export(to zipURL: URL, doctor: DoctorReport, settings: AppSettings, taxonomy: TaxonomySnapshot,
                       includeDocumentText: Bool) async throws -> DiagnosticsContents {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("arrumator-diagnostics-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("arrumator-diagnostics", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        try JSON.prettyEncoder.encode(doctor).write(to: staging.appendingPathComponent("doctor.json"))
        try JSON.prettyEncoder.encode(settings).write(to: staging.appendingPathComponent("settings.json"))
        try JSON.prettyEncoder.encode(taxonomy).write(to: staging.appendingPathComponent("taxonomy.json"))
        var logFiles: [String] = []
        let logsDir = staging.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        for file in (try? fm.contentsOfDirectory(at: paths.logsDirectory, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "jsonl" {
            try fm.copyItem(at: file, to: logsDir.appendingPathComponent(file.lastPathComponent))
            logFiles.append(file.lastPathComponent)
        }
        let limit = config.diagnosticsTraceLimit
        let traces = try await database.reader.read { db -> [String] in
            let traces = try TraceRecord.order(Column("started_at").desc).limit(limit).fetchAll(db)
            return try traces.map { t in
                var steps = try TraceStepRecord.filter(Column("trace_id") == t.id).order(Column("seq")).fetchAll(db)
                if !includeDocumentText {
                    steps = steps.map { s in
                        var s = s
                        if s.stage == TraceStage.llm.rawValue || s.stage == TraceStage.vlm.rawValue { s.inputJson = nil }
                        return s
                    }
                }
                return JSON.string(TraceExport(trace: t, steps: steps))
            }
        }
        try Data(traces.joined(separator: "\n").utf8).write(to: staging.appendingPathComponent("traces.jsonl"))
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", staging.path, zipURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: zipURL.path])
        }
        Log.info(.app, "Diagnostics exported", ["path": zipURL.path, "traces": String(traces.count)])
        return DiagnosticsContents(logFiles: logFiles, traces: traces.count, includesDocumentText: includeDocumentText)
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
