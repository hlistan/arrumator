@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// Document text goes into a diagnostics export only when the user says so (AGENTS.md §4.1).
@Suite struct DiagnosticsTests {
    static let documentText = "Cliente: Maria Exemplo, NIF 503504564"

    static func step(_ stage: TraceStage, seq: Int) -> TraceStepRecord {
        TraceStepRecord(id: nil, traceId: 1, seq: seq, stage: stage.rawValue, status: .ok, startedAt: TestTime.start,
                        durationMs: 1, inputJson: #"{"tiers":"ministral-3:14b"}"#,
                        outputJson: #"[{"user":"\#(documentText)","response":"{\"subjects\":[\"Maria Exemplo\"]}"}]"#, error: nil)
    }

    static let steps = [step(.extract, seq: 0), step(.analyse, seq: 1), step(.vlm, seq: 2), step(.consolidate, seq: 3), step(.place, seq: 4)]

    @Test func withoutConsentNoModelExchangeLeavesTheMac() {
        let shared = DiagnosticsExporter.shareable(Self.steps, includeDocumentText: false)
        for step in shared where [TraceStage.analyse.rawValue, TraceStage.vlm.rawValue, TraceStage.consolidate.rawValue].contains(step.stage) {
            #expect(step.inputJson == nil && step.outputJson == nil,
                    "\(step.stage) holds the document's text or the model's answers drawn from it; both stay out")
        }
        #expect(shared.map(\.stage) == Self.steps.map(\.stage) && shared.map(\.durationMs) == Self.steps.map(\.durationMs),
                "every step is still there, with its timing")
        #expect(shared.first { $0.stage == TraceStage.place.rawValue } == Self.steps.last, "steps without a model exchange are kept whole")
    }

    @Test func withConsentTheExchangesAreKept() {
        #expect(DiagnosticsExporter.shareable(Self.steps, includeDocumentText: true) == Self.steps, "with the user's consent, every step is shared whole")
    }

    @Test func theExportedZipHoldsTracesWithoutTheDocumentUnlessAskedFor() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        try await h.ingest("bill.txt", text: Self.documentText)
        let doctor = DoctorReport(generatedAt: TestTime.start, appVersion: "test", macOS: "test", paths: [:], checks: [], models: [],
                                  ollama: "none")
        let exporter = DiagnosticsExporter(database: h.env.database, paths: h.env.paths, config: h.env.config.stats)
        for consent in [false, true] {
            let zip = h.env.root.appendingPathComponent("diagnostics-\(consent).zip")
            let contents = try await exporter.export(to: zip, doctor: doctor, settings: await h.env.settings.current,
                                                     includeDocumentText: consent)
            #expect(contents.traces == 1 && contents.includesDocumentText == consent, "the one trace, as the user chose")
            let unzipped = h.env.root.appendingPathComponent("unzipped-\(consent)", isDirectory: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, unzipped.path]
            try ditto.run()
            ditto.waitUntilExit()
            let folder = unzipped.appendingPathComponent("arrumator-diagnostics", isDirectory: true)
            let traces = try String(contentsOf: folder.appendingPathComponent("traces.jsonl"), encoding: .utf8)
            #expect(traces.contains("Maria Exemplo") == consent,
                    consent ? "with consent, the labels read from the document are shared" : "without it, nothing read from the document leaves")
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("doctor.json").path), "with the doctor's report")
        }
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
            await trace.record(TraceStep(stage: .analyse, input: #"{"tiers":"m"}"#, output: exchange))
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
