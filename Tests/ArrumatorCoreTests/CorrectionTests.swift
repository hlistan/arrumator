import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What the user corrects of a document's labels, from its card or from a terminal, is a change (`LabelEdit`): the
/// labels added and those taken off, made to the labels the document has when it is made, never a whole set the card
/// last showed. The rules of a label's kind hold whoever makes it (docs/how-it-works.md#correcting-labels).
@Suite struct CorrectionTests {
    static let receipt = DocumentLabel(kind: .type, value: "receipt")

    @Test func aTypeOrADateAddedTakesThePlaceOfTheOneThereForTheAppAndTheCommandLineAlike() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.receipt, DocumentLabel(kind: .date, value: "2026-07-06")]))
        let edited = try #require(try await h.services.documents.document(id: id))
        #expect(edited.labels(.type) == ["receipt"], "a document has one type, and the one added replaces the one it had")
        #expect(edited.labels(.date) == ["2026-07-06"], "and one date")
        #expect(edited.labels(.topic) == ["electricity"], "a label of a kind that has many stays beside the others")
        #expect(edited.labels?.map(\.kind) == StubAnalyzer.edpBill.map(\.kind), "and each replaced in its place, the order kept")
        let summary = try await h.services.history.events(limit: 5, kinds: [.corrected], docID: id).first?.summary ?? ""
        #expect(summary.contains("added type “receipt”") && summary.contains("removed type “invoice”"),
                "History says the type was replaced: \(summary)")
    }

    @Test func labelsTakenOffOneAfterAnotherEachStayOff() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        let review = h.review
        // Each × on the card sends its own change at once, as quickly as the user clicks, while the others are made.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for label in StubAnalyzer.edpBill {
                group.addTask { try await review.edit(id, fileName: nil, labels: LabelEdit(removing: [label])) }
            }
            try await group.waitForAll()
        }
        let edited = try #require(try await h.services.documents.document(id: id))
        #expect(edited.labels == [], "every label taken off stays off; none comes back with a change made beside it: \(edited.labels ?? [])")
        #expect(try await h.services.history.events(limit: 50, kinds: [.corrected], docID: id).count == StubAnalyzer.edpBill.count,
                "each change is recorded once")
    }

    @Test func aChangeThatChangesNothingRecordsNothing() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [DocumentLabel(kind: .topic, value: "Electricity")],
                                                                     removing: [DocumentLabel(kind: .sender, value: "Nobody")]))
        // The type and date it has, given again, as from a terminal: they are the ones there, not new ones.
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [DocumentLabel(kind: .type, value: "Invoice"),
                                                                              DocumentLabel(kind: .date, value: "2026-07-05")]))
        let edited = try #require(try await h.services.documents.document(id: id))
        #expect(edited.labels == StubAnalyzer.edpBill,
                "a label it has, however written, a type or date it has, and one it has not, change nothing, in order: \(edited.labels ?? [])")
        #expect(try await h.services.history.events(limit: 5, kinds: [.corrected], docID: id).isEmpty, "and nothing is recorded")
    }

    @Test func aChangeToADocumentThatIsGoneIsRefusedNamingIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        await #expect(throws: IngestError.documentNotFound(Self.noDocument)) {
            try await h.review.edit(Self.noDocument, fileName: nil, labels: LabelEdit(adding: [Self.receipt]))
        }
    }

    static let noDocument: Int64 = 404
}
