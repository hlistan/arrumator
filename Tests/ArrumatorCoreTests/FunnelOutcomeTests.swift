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

    @Test func theReportsNineDocumentsAreNotEveryOneFiled() {
        // The QA run of 15 October 2026: seven filed, one waiting for the user and one left for later, both stopped at the
        // last step, which `mainStop` never looked at.
        let funnel = Self.funnel(documents: 9, [
            Self.step("arrived", stops: []),
            Self.step("read", stops: []),
            Self.step("analysed", stops: []),
            Self.step("filed", stops: [Self.stop(.needsReview, 1), Self.stop(.held, 1)]),
        ])
        #expect(funnel.mainStop != nil, "two documents not filed stopped at Filed, and the last step's stops count")
        let verdict = funnel.verdict
        #expect(verdict?.everyOneFiled == false, "two of nine were not filed")
        #expect(verdict?.notFiled.map(\.status) == [.needsReview, .held], "both are named, in the order of the table: \(String(describing: verdict))")
        #expect(verdict?.notFiled.map(\.reason) == ["Waiting for you to decide", "Left for later"], "each by its reason")
    }

    @Test func everyDocumentFiledIsEveryOneFiled() {
        let funnel = Self.funnel(documents: 3, [Self.step("arrived", stops: []), Self.step("filed", stops: [])])
        #expect(funnel.verdict == FunnelVerdict(notFiled: [], inProgress: 0), "nothing is left over")
        #expect(funnel.verdict?.everyOneFiled == true, "so every one was filed")
    }

    @Test func documentsStillWorkedOnAreNotAVerdictOfFiling() {
        let funnel = Self.funnel(documents: 2, [Self.step("arrived", stops: [Self.stop(.processing, 1), Self.stop(.arrived, 1)])])
        #expect(funnel.verdict?.everyOneFiled == false, "documents on their way are not yet filed")
        #expect(funnel.verdict?.notFiled.isEmpty == true, "and not a stop either")
        #expect(funnel.verdict?.inProgress == 2, "they are counted as being worked on")
    }

    @Test func aCopyLeavingEarlyIsNotFiled() {
        let funnel = Self.funnel(documents: 2, [Self.step("arrived", stops: [Self.stop(.duplicate, 1)]), Self.step("filed", stops: [])])
        #expect(funnel.verdict?.notFiled.map(\.reason) == ["A copy of a file already filed"],
                "a copy stopped at the first step, and is named, though it is the pipeline working")
        #expect(funnel.verdict?.everyOneFiled == false, "it was not filed")
    }

    @Test func anEmptyWindowHasNoVerdict() {
        #expect(Self.funnel(documents: 0, [Self.step("arrived", stops: [])]).verdict == nil, "there is nothing to say of no document")
    }

    @Test func documentsFiledWithoutTheirStepsAreFiledInTheVerdict() {
        let funnel = Self.funnel(documents: 2, [Self.step("arrived", stops: [Self.stop(.filed, 2)]), Self.step("filed", stops: [])])
        #expect(funnel.verdict?.everyOneFiled == true, "a document filed whose steps were not kept has not stopped anywhere")
        #expect(funnel.mainStop == nil, "nor does the main stop name it")
    }
}
