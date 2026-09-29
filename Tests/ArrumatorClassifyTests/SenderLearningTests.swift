@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// Who documents come from is learned from what is filed: a sender's own identifiers recognise its next document
/// however its name is written, a name the user corrects is remembered, and anything learned can be forgotten.
@Suite struct SenderLearningTests {
    static func edpBill(_ name: String, keys: [StableKey] = [Fixtures.edpNIF]) -> ExtractedContent {
        Fixtures.content(name, text: Fixtures.edpText, keys: keys)
    }

    @Test func aFiledDocumentIsLinkedToItsSenderNewOrKnown() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer() }
        defer { h.env.cleanup() }
        let first = try await h.file(Self.edpBill("july.pdf"))
        let second = try await h.file(Self.edpBill("august.pdf"))
        let senders = try await h.senders.correspondents()
        #expect(senders.map(\.canonicalName) == ["EDP Comercial"], "the second document is from the sender the first taught")
        let documents = try await DocumentStore(database: h.env.database).documents(ids: [first.id, second.id])
        #expect(documents.values.allSatisfy { $0.correspondentId == senders.first?.id })
        #expect(senders.first?.filedCount == 2)
    }

    @Test func identifiersSeenOnASendersDocumentsAloneRecogniseItsNextDocument() async throws {
        let h = try await ClassifyHarness.make { request in
            // Later bills name the sender only by its brand; the tax number is the same.
            Fixtures.answer(correspondent: request.allText.contains("third.pdf") ? "EDP" : "EDP Comercial")
        }
        defer { h.env.cleanup() }
        try await h.file(Self.edpBill("first.pdf"))
        #expect(try await h.senders.correspondents().first?.stableKeys.isEmpty == true,
                "one document is not enough to make an identifier the sender's own")
        try await h.file(Self.edpBill("second.pdf"))
        let edp = try #require(try await h.senders.correspondents().first)
        #expect(edp.stableKeys == [Fixtures.edpNIF.token], "after stableKeyMinFilings documents it is")
        let third = try await h.file(Self.edpBill("third.pdf"))
        #expect(third.analysis.correspondent == "EDP Comercial" && third.analysis.correspondentID == edp.id,
                "recognised by its tax number, not the name the model wrote")
        #expect(try await h.senders.correspondents().count == 1)
    }

    @Test func anIdentifierOnSeveralSendersDocumentsIdentifiesNone() async throws {
        let ownNIF = StableKey(kind: .ptNIF, value: "123456789")
        let h = try await ClassifyHarness.make { request in
            Fixtures.answer(correspondent: request.allText.contains("meo-") ? "MEO" : "EDP Comercial")
        }
        defer { h.env.cleanup() }
        for name in ["edp-1.pdf", "edp-2.pdf", "meo-1.pdf", "meo-2.pdf"] { try await h.file(Self.edpBill(name, keys: [ownNIF])) }
        let senders = try await h.senders.correspondents()
        #expect(senders.map(\.canonicalName).sorted() == ["EDP Comercial", "MEO"])
        #expect(senders.allSatisfy { $0.stableKeys.isEmpty }, "the user's own tax number, printed on every bill, is nobody's")
    }

    @Test func aSenderTheUserRenamesKeepsTheOldNameAsAnother() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer(correspondent: "EDP Energia") }
        defer { h.env.cleanup() }
        let filed = try await h.file(Self.edpBill("bill.pdf"))
        await h.learner.senderRenamed(documentID: filed.id, from: "EDP Energia", to: "EDP Comercial")
        let edp = try #require(try await h.senders.correspondents().first { $0.canonicalName == "EDP Comercial" })
        #expect(edp.aliases == ["EDP Energia"])
        #expect(try await DocumentStore(database: h.env.database).document(id: filed.id)?.correspondentId == edp.id,
                "the document is the renamed sender's")
        let next = try await h.analyse(Self.edpBill("next.pdf", keys: []))
        #expect(next.analysis.correspondent == "EDP Comercial" && next.analysis.correspondentID == edp.id,
                "the next document the model reads as from EDP Energia is from EDP Comercial")
        let learned = try await HistoryStore(database: h.env.database).events(limit: 5, kinds: [.learned])
        #expect(learned.compactMap(LearnedFact.recorded(by:)) == [.alias(correspondentID: edp.id, alias: "EDP Energia")],
                "what was learned is recorded against the document it came from, and can be forgotten")
    }

    @Test func forgettingANameOrASender() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer() }
        defer { h.env.cleanup() }
        let filed = try await h.file(Self.edpBill("bill.pdf"))
        await h.learner.senderRenamed(documentID: filed.id, from: "EDP Energia", to: "EDP Comercial")
        let edp = try #require(try await h.senders.correspondents().first)
        let alias = LearnedFact.alias(correspondentID: edp.id, alias: "EDP Energia")
        #expect(try await h.senders.known([alias]) == [alias])

        try await h.learner.forget(alias)
        #expect(try await h.senders.correspondents().first?.aliases.isEmpty == true)
        try await h.learner.forget(alias)
        #expect(try await HistoryStore(database: h.env.database).events(limit: 10, kinds: [.forgot]).count == 1,
                "forgetting what is already forgotten does nothing")

        try await h.learner.forget(.sender(correspondentID: edp.id))
        #expect(try await h.senders.correspondents().isEmpty)
        let document = try await DocumentStore(database: h.env.database).document(id: filed.id)
        #expect(document?.correspondentId == nil && document?.correspondent == "EDP Comercial",
                "its documents keep the name they were filed under")
    }

    @Test func anUndoneFilingNoLongerCountsForItsSender() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer() }
        defer { h.env.cleanup() }
        try await h.file(Self.edpBill("first.pdf"))
        let second = try await h.file(Self.edpBill("second.pdf"))
        #expect(try await h.senders.correspondents().first?.stableKeys == [Fixtures.edpNIF.token])
        let store = DocumentStore(database: h.env.database)
        var undone = try #require(try await store.document(id: second.id))
        undone.status = .undone
        try await store.save(undone)
        #expect(try await h.senders.correspondents().first?.filedCount == 2)
        await h.learner.documentForgotten(documentID: second.id)
        let edp = try #require(try await h.senders.correspondents().first)
        #expect(edp.filedCount == 1, "the undone document is the sender's no longer")
        #expect(edp.stableKeys == [Fixtures.edpNIF.token],
                "an identifier learned stays the sender's while it is on no one else's documents, as one written by hand does")
    }
}
