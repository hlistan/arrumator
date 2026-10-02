@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// Nothing derived from a document or its file goes into a diagnostics export, or into the trace a bug report asks for,
/// unless the user says so (AGENTS.md §4.1): neither its text nor a preview, its metadata, its name or path, the
/// identifiers read from it, its labels nor the user's question.
@Suite struct DiagnosticsTests {
    static let documentText = "Cliente: Maria Exemplo, NIF 503504564"
    /// What a document says, what it is called and what was read from it: none of these may leave without consent.
    static let sentinels = ["Maria Exemplo", "503504564", "Fatura-Exemplo"]

    /// A step of `stage` whose input, output and error each carry the document's name, text and identifier, as the
    /// steps that extract, read, name and file a document do.
    static func step(_ stage: TraceStage, seq: Int) -> TraceStepRecord {
        TraceStepRecord(id: nil, traceId: 1, seq: seq, stage: stage.rawValue, status: .error, startedAt: TestTime.start,
                        durationMs: Double(seq + 1), inputJson: #"{"file":"Fatura-Exemplo.pdf"}"#,
                        outputJson: #"{"preview":"\#(documentText)","stableKeys":["503504564"]}"#,
                        error: "Could not read Fatura-Exemplo.pdf: \(documentText)")
    }

    static let steps = TraceStage.allCases.enumerated().map { step($1, seq: $0) }

    @Test func withoutConsentEveryStepKeepsOnlyWhatTheAppDidAndWhen() {
        let shared = DiagnosticsExporter.shareable(Self.steps, includeDocumentText: false)
        #expect(shared.count == Self.steps.count, "every step is still there")
        for (step, original) in zip(shared, Self.steps) {
            #expect(step.inputJson == nil && step.outputJson == nil && step.error == nil,
                    "\(step.stage): what it was given, what it gave and why it failed hold the document, whatever the stage")
            #expect(step.seq == original.seq && step.stage == original.stage && step.status == original.status
                        && step.startedAt == original.startedAt && step.durationMs == original.durationMs,
                    "\(step.stage): its place, stage, status, start and duration are still there")
        }
    }

    @Test func withConsentEveryStepIsSharedWhole() {
        #expect(DiagnosticsExporter.shareable(Self.steps, includeDocumentText: true) == Self.steps,
                "with the user's consent, every step is shared whole")
    }

    /// Steps of every stage, and log lines whose fields name the document, exported with and without consent and read
    /// back from the zip.
    @Test func theExportedZipHoldsNothingOfTheDocumentUnlessAskedFor() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let recorder = TraceRecorder(database: env.database, appVersion: "test", time: env.time)
        let trace = try await recorder.start(TraceHeader(docID: nil, jobID: nil, attempt: 2, source: .ingest, promptVersion: 1, models: nil,
                                                         settings: await env.settings.current))
        for step in Self.steps {
            await trace.record(TraceStep(stage: try #require(TraceStage(rawValue: step.stage)), status: step.status, startedAt: step.startedAt,
                                         durationMs: step.durationMs, input: step.inputJson, output: step.outputJson, error: step.error))
        }
        await recorder.finish(trace, outcome: "filed", docID: nil)
        // A log of its own, written as the app's is, into this test's logs folder.
        let log = Log()
        log.configure(directory: env.paths.logsDirectory, minLevel: .trace, config: env.config.logging, echoToStderr: false)
        let path = env.incoming.appendingPathComponent("Fatura-Exemplo.pdf").path
        log.log(.info, .ingest, "Queued", ["path": path, "job": "7", "tags": "Maria Exemplo"])
        log.log(.error, .extract, "Extraction failed", ["file": "Fatura-Exemplo.pdf", "doc": "3", "error": Self.documentText])
        log.log(.info, .fileops, "Moved", ["from": path, "to": env.archive.appendingPathComponent("503504564.pdf").path])
        // As versions 0.1.1 to 0.1.4 logged every History event, its summary in the message; logs are kept for days.
        log.log(.debug, .ingest, "event filed: Filed Fatura-Exemplo.pdf from Maria Exemplo", ["doc": "3"])
        let doctor = DoctorReport(generatedAt: TestTime.start, appVersion: "test", macOS: "test", paths: [:], checks: [], models: [],
                                  ollama: "none")
        let exporter = DiagnosticsExporter(database: env.database, paths: env.paths, config: env.config.stats)
        for consent in [false, true] {
            let zip = env.root.appendingPathComponent("diagnostics-\(consent).zip")
            let contents = try await exporter.export(to: zip, doctor: doctor, settings: await env.settings.current, includeDocumentText: consent)
            #expect(contents.traces == 1 && contents.logFiles.count == 1 && contents.includesDocumentText == consent,
                    "the one trace and the one day's log, as the user chose")
            let files = try await Self.unzipped(zip, into: env.root.appendingPathComponent("unzipped-\(consent)", isDirectory: true))
            #expect(files.count == 4, "the doctor's report, the settings, the traces and the log: \(files.keys.sorted())")
            for sentinel in Self.sentinels {
                let holding = files.filter { Self.contains($0.value, sentinel) }.keys.sorted()
                if consent {
                    #expect(!holding.isEmpty, "with consent, \(sentinel) is shared as the app recorded it")
                } else {
                    #expect(holding.isEmpty, "without consent, \(sentinel) is in no file of the export: \(holding)")
                }
            }
            let traces = try #require(files.first { $0.key.hasSuffix("/traces.jsonl") }?.value)
            let exported = try JSON.decoder.decode(TraceExport.self, from: traces)
            #expect(exported.steps.map(\.stage) == TraceStage.allCases.map(\.rawValue) && exported.trace.attempt == 2 && exported.trace.outcome == "filed",
                    "every step is there, and the trace still says which attempt it was and how it ended")
            let lines = try #require(files.first { $0.key.contains("/logs/") }?.value)
            let entries = try lines.split(separator: UInt8(ascii: "\n")).map { try JSON.decoder.decode(LogLine.self, from: $0) }
            let messages = ["Queued", "Extraction failed", "Moved"]
            #expect(entries.map(\.msg) == (consent ? messages + ["event filed: Filed Fatura-Exemplo.pdf from Maria Exemplo"] : messages),
                    "every line is there with its message, but one whose message holds what an earlier version wrote of an event")
            #expect(entries.prefix(3).map { $0.fields["job"] ?? $0.fields["doc"] } == ["7", "3", nil],
                    "and the identifiers of the app's own records, which come from no document")
        }
    }

    /// What a test reads of a line of an exported log.
    struct LogLine: Decodable {
        var msg: String
        var fields: [String: String]
    }

    /// Whether `data` holds `text`, compared on bytes.
    static func contains(_ data: Data, _ text: String) -> Bool {
        let needle = Array(text.utf8)
        let bytes = Array(data)
        guard bytes.count >= needle.count else { return false }
        return (0...(bytes.count - needle.count)).contains { Array(bytes[$0..<($0 + needle.count)]) == needle }
    }

    /// Every file `zip` holds, by its path in the zip, unzipped into `folder` with the archiver that zipped it.
    static func unzipped(_ zip: URL, into folder: URL) async throws -> [String: Data] {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: DiagnosticsExporter.dittoPath)
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            ditto.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try ditto.run()
            } catch {
                ditto.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try #require(status == 0, "the export is a zip")
        let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects ?? []
        var files: [String: Data] = [:]
        for case let url as URL in found where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files[String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))] = try Data(contentsOf: url)
        }
        return files
    }
}

/// The prompts and raw answers of a reading are kept only `traceRawRetentionDays`; what the reading concluded stays.
@Suite struct TraceRetentionTests {
    @Test func oldExchangesWithTheModelAreClearedAndTheirConclusionsKept() async throws {
        let database = try AppDatabase.inMemory()
        let recorder = TraceRecorder(database: database, appVersion: "test", time: TestTime(.advances))
        let settings = try AppSettings.bundledDefaults()
        let header = TraceHeader(docID: nil, jobID: nil, attempt: 0, source: .ingest, promptVersion: 1, models: nil, settings: settings)
        let exchange = #"{"answer":{"fileName":"EDP"},"exchange":[{"user":"\#(DiagnosticsTests.documentText)"}]}"#
        let old = try await recorder.start(header)
        let recent = try await recorder.start(header)
        for trace in [old, recent] {
            await trace.record(TraceStep(stage: .analyse, input: #"{"model":"m"}"#, output: exchange))
            await trace.record(TraceStep(stage: .place, input: #"{"to":"/a"}"#, output: #"{"exchange":"not a model's"}"#))
        }
        let oldID = try #require(old.traceID)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE traces SET started_at = started_at - ? WHERE id = ?", arguments: [200.0 * 86_400, oldID])
        }
        let trimmed = try await recorder.trimRawPayloads(olderThanDays: 180)
        #expect(trimmed == 1, "one step of one old trace exchanged the document with the model")
        let oldSteps = try #require(try await recorder.trace(id: oldID)?.1)
        let reading = try #require(oldSteps.first { $0.stage == TraceStage.analyse.rawValue })
        #expect(reading.outputJson == #"{"answer":{"fileName":"EDP"}}"#,
                "the prompts and raw answers, which hold the document's text, are gone; the answer the reading gave stays")
        #expect(oldSteps.first { $0.stage == TraceStage.place.rawValue }?.outputJson == #"{"exchange":"not a model's"}"#,
                "a step that exchanged nothing with a model is left as it is")
        let recentID = try #require(recent.traceID)
        let recentSteps = try #require(try await recorder.trace(id: recentID)?.1)
        #expect(recentSteps.first { $0.stage == TraceStage.analyse.rawValue }?.outputJson == exchange,
                "a reading inside the retention period keeps its exchange")
    }
}
