@testable import ArrumatorCore
import Foundation
import Testing

/// Where the documents of Statistics' window ended up (`ProcessingFunnel.outcomes`) and how much a step's stops matter
/// (`FunnelStepStats.stopSeverity`), as Core works them out for the app and every other reader alike.
@Suite struct FunnelOutcomeTests {
    static func stop(_ status: DocumentStatus, _ count: Int) -> FunnelStop {
        let (reason, severity) = StatsService.stopReason(for: status)
        return FunnelStop(status: status, reason: reason, count: count, severity: severity)
    }

    static func step(_ id: String, stops: [FunnelStop]) -> FunnelStepStats {
        FunnelStepStats(id: id, title: id, detail: "", stages: [], reached: 0, passed: 0, stoppedHere: stops, warnings: 0, errors: 0,
                        medianMs: 0, p95Ms: 0, ofAll: 0)
    }

    static func funnel(documents: Int, _ steps: [FunnelStepStats]) -> ProcessingFunnel {
        ProcessingFunnel(generatedAt: Date(timeIntervalSince1970: 0), windowDays: 7, documents: documents, waiting: 0, steps: steps)
    }

    @Test func eachOutcomeIsListedOnceAndDocumentsFiledWithoutTheirStepsAreFiled() {
        // Filed after a rebuild from the archive, without the steps it took: it stops at the first step as filed.
        let funnel = Self.funnel(documents: 10, [
            Self.step("arrived", stops: [Self.stop(.filed, 2), Self.stop(.duplicate, 1)]),
            Self.step("read", stops: [Self.stop(.failed, 1), Self.stop(.needsReview, 1)]),
            Self.step("analysed", stops: [Self.stop(.needsReview, 2)]),
        ])
        let outcomes = funnel.outcomes
        #expect(outcomes.map(\.id) == [.filed, .needsReview, .failed, .duplicate],
                "filed first, then the most first and of as many in their order, each once: \(outcomes.map(\.id))")
        #expect(outcomes.first?.count == 5, "the documents filed, those whose steps were not kept among them: \(outcomes)")
        #expect(outcomes.reduce(0) { $0 + $1.count } == funnel.documents, "every document is in one outcome, and only one")
        #expect(outcomes.first(where: { $0.status == .needsReview })?.count == 3, "a reason met at two steps is one outcome")
    }

    @Test func anOutcomeNoDocumentEndedUpInIsNotListed() {
        let outcomes = Self.funnel(documents: 1, [Self.step("read", stops: [Self.stop(.failed, 1)])]).outcomes
        #expect(outcomes.map(\.id) == [.failed], "nothing was filed, so filing is not an outcome: \(outcomes)")
    }

    @Test func aStepsStopsMatterAsMuchAsTheWorstOfThem() {
        #expect(Self.step("a", stops: [Self.stop(.duplicate, 3), Self.stop(.needsReview, 1)]).stopSeverity == .attention,
                "one waiting for the user matters more than copies leaving early")
        #expect(Self.step("b", stops: [Self.stop(.needsReview, 3), Self.stop(.failed, 1)]).stopSeverity == .problem,
                "and one that failed more than both")
        #expect(Self.step("c", stops: []).stopSeverity == nil, "a step nothing stopped at has none")
    }
}
