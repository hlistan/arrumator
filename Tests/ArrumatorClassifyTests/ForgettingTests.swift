import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

@Suite struct ForgettingTests {
    private let nif = StableKey(kind: .ptNIF, value: "503504564")

    /// Files enough EDP bills into Utilities for a rule to form, and returns the folder.
    private func learnEDP(_ h: ClassifyHarness) async throws -> TaxonomyFolder {
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true)
        for i in 0..<h.env.config.learning.ruleMinSupport {
            try await h.fileConfirmed(Fixtures.content("edp_\(i).pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        }
        return folder
    }

    @Test func aForgottenExampleIsNoLongerEvidence() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
        defer { h.env.cleanup() }
        _ = try await learnEDP(h)
        let history = HistoryStore(database: h.env.database)
        let lesson = try #require(try await history.events(limit: 10, kinds: [.learned]).first)
        let fact = try #require(LearnedFact.recorded(by: lesson))
        let docID = try #require(lesson.docId)
        #expect(fact == .example(documentID: docID))
        #expect(try await h.store.known([fact]) == [fact])

        try await h.learner.forget(fact)

        #expect(try await h.store.memories(model: "bge-m3").allSatisfy { $0.documentID != docID })
        #expect(try await h.store.known([fact]).isEmpty)
        let forgot = try #require(try await history.events(limit: 1, kinds: [.forgot]).first)
        #expect(forgot.docId == docID && forgot.actor == .user)
        try await h.learner.forget(fact)
        #expect(try await history.events(limit: 10, kinds: [.forgot]).count == 1, "forgetting twice changes nothing")
    }

    @Test func everyExampleTheAppFilesByIsListedAndForgettingTakesItOff() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true)
        try await h.fileConfirmed(Fixtures.content("confirmed.pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        // A filing nobody confirmed teaches an example too, though it writes no lesson in the history.
        let quiet = Fixtures.content("quiet.pdf", text: Fixtures.edpText, keys: [nif])
        var outcome = try await h.classify(quiet)
        outcome.decision.folderCode = folder.code
        outcome.decision.confidence.band = .check
        let quietID = try await h.document("quiet.pdf", folderID: folder.id, correspondent: "EDP")
        await h.learner.documentFiled(documentID: quietID, folderID: folder.id, outcome: outcome, content: quiet,
                                      confirmedByUser: false, trace: .disabled)
        let history = HistoryStore(database: h.env.database)
        #expect(try await history.events(limit: 10, kinds: [.learned], docID: quietID).isEmpty)

        let examples = try await h.store.examples(limit: 10)
        #expect(examples.map(\.document.filename) == ["quiet.pdf", "confirmed.pdf"], "newest first, lesson or not")
        #expect(examples.allSatisfy { $0.memory.folderID == folder.id })

        try await h.learner.forget(try #require(examples.first).fact)
        #expect(try await h.store.examples(limit: 10).map(\.document.filename) == ["confirmed.pdf"], "forgotten, it is gone")
        #expect(try await history.events(limit: 10, kinds: [.forgot]).count == 1)
    }

    @Test func undoingAFilingIsForgettingNotALesson() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true)
        try await h.fileConfirmed(Fixtures.content("edp.pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        let docID = try #require(try await h.store.examples(limit: 1).first?.id)
        await h.learner.documentForgotten(documentID: docID)
        let history = HistoryStore(database: h.env.database)
        #expect(try await history.events(limit: 10, kinds: [.forgot], docID: docID).map(\.summary) == ["Forgot where this was filed"])
        #expect(try await history.events(limit: 10, kinds: [.learned], docID: docID).allSatisfy { $0.summary.hasPrefix("Remembered") })
        #expect(try await h.store.examples(limit: 10).isEmpty)
    }

    @Test func aForgottenRuleStopsPlacingAndDoesNotFormAgain() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
        defer { h.env.cleanup() }
        let folder = try await learnEDP(h)
        let induced = try #require(try await HistoryStore(database: h.env.database).events(limit: 20, kinds: [.ruleInduced]).first)
        guard case let .rule(ruleID) = try #require(LearnedFact.recorded(by: induced)) else {
            Issue.record("a rule event records its rule")
            return
        }
        for rule in try await h.store.rules() where !rule.forgotten { try await h.learner.forget(.rule(id: rule.id)) }
        #expect(try await h.store.rules().allSatisfy(\.forgotten))

        try await h.fileConfirmed(Fixtures.content("edp_more.pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        #expect(try await h.store.rules().allSatisfy(\.forgotten), "the same filings do not bring a forgotten rule back")
        #expect(try await h.store.known([.rule(id: ruleID)]).isEmpty)
    }

    @Test func forgettingANameOrASender() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
        defer { h.env.cleanup() }
        _ = try await learnEDP(h)
        let edp = try #require(try await h.store.correspondents().first { $0.canonicalName == "EDP Comercial" })
        var proposed = try await h.classify(Fixtures.content("x.pdf", text: Fixtures.edpText)).decision
        proposed.correspondent = "EDP Energia"
        let docID = try await h.document("x.pdf")
        await h.learner.correctionRecorded(CorrectionEvent(
            documentID: docID, source: .moveTo, fromFolderID: nil, toFolderID: nil, fromFilename: nil, toFilename: nil,
            proposed: proposed, editedFields: ["correspondent": "EDP Comercial"], traceID: nil), trace: .disabled)
        let alias = LearnedFact.alias(correspondentID: edp.id, alias: "EDP Energia")
        #expect(try await h.store.known([alias]) == [alias])

        try await h.learner.forget(alias)
        #expect(try await h.store.correspondents().first { $0.id == edp.id }?.aliases.isEmpty == true)

        try await h.learner.forget(.sender(correspondentID: edp.id))
        #expect(try await h.store.correspondents().allSatisfy { $0.id != edp.id })
        #expect(try await h.store.rules().filter { $0.predicates.contains(.correspondent(id: edp.id)) }.allSatisfy(\.forgotten),
                "the rules about a forgotten sender are forgotten with it")
    }
}
