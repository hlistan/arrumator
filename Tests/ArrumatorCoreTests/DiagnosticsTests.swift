@testable import ArrumatorCore
import Foundation
import Testing

/// Document text goes into a diagnostics export only when the user says so (AGENTS.md §4.1).
@Suite struct DiagnosticsTests {
    static let documentText = "Cliente: Maria Exemplo, NIF 503504564"

    static func step(_ stage: TraceStage, seq: Int) -> TraceStepRecord {
        TraceStepRecord(id: nil, traceId: 1, seq: seq, stage: stage.rawValue, status: TraceStatus.ok.rawValue, startedAt: Date(),
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
        #expect(shared.first { $0.stage == TraceStage.place.rawValue }?.outputJson != nil, "steps without a model exchange are kept whole")
    }

    @Test func withConsentTheExchangesAreKept() {
        #expect(DiagnosticsExporter.shareable(Self.steps, includeDocumentText: true) == Self.steps)
    }
}
