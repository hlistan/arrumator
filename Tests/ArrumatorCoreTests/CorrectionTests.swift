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

    @Test func anAmountTheUserTypesIsKeptInTheFormTheModelsAre() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [DocumentLabel(kind: .amount, value: "12,50 €"),
                                                                              DocumentLabel(kind: .amount, value: "1.234,56 EUR")]))
        let edited = try #require(try await h.services.documents.document(id: id))
        #expect(edited.labels(.amount) == ["54.21 EUR", "12.50 EUR", "1234.56 EUR"],
                "a decimal comma, grouping and a currency symbol only one currency has become the amount's form")
        #expect(LabelError.refusal(of: DocumentLabel(kind: .amount, value: "5 %")) != nil, "and a percentage is no amount: it is refused")
    }

    /// Labels a reading gave before their kind was held to its form (the QA run of 4 October 2026).
    static let earlierLabels = StubAnalyzer.edpBill + [DocumentLabel(kind: .party, value: "999999990"), DocumentLabel(kind: .amount, value: "5.00% GBP")]

    @Test func aLabelAnEarlierReadingGaveInAFormItsKindNoLongerKeepsCanStillBeTakenOff() async throws {
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: ["a.txt": Self.earlierLabels, "b.txt": Self.earlierLabels]))
        defer { h.env.cleanup() }
        let a = try #require(try await h.ingest("a.txt", text: "EDP electricity July").id)
        let b = try #require(try await h.ingest("b.txt", text: "EDP electricity August").id)
        try await h.review.edit(a, fileName: nil, labels: LabelEdit(removing: [DocumentLabel(kind: .amount, value: "5.00% GBP")]))
        #expect(try await h.services.documents.document(id: a)?.labels(.amount) == ["54.21 EUR"], "taken off its card as it is written")

        let ignored = try await h.labels.ignore(DocumentLabel(kind: .party, value: "999999990"))
        #expect(ignored.documents == [a, b] && ignored.rule?.value == "999999990", "and removed everywhere, as written")
        #expect(try await h.services.documents.document(id: b)?.labels(.party) == ["Maria Exemplo"], "from every document that has it")
        await #expect(throws: LabelError.notALabel(.party, "123456789"), "a label no document has must still be one of its kind") {
            try await h.labels.ignore(DocumentLabel(kind: .party, value: "123456789"))
        }
        await #expect(throws: LabelError.notALabel(.party, "123456789"), "and so must what a label is merged into") {
            try await h.labels.merge(DocumentLabel(kind: .party, value: "Maria Exemplo"), into: "123456789")
        }
    }

    @Test func aLabelAddedThatIsNoLabelOfItsKindIsRefusedSayingWhatTheKindTakesAndNothingChanges() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        let refused: [(DocumentLabel, String)] = [
            (DocumentLabel(kind: .type, value: "fatura"), "invoice"),
            (DocumentLabel(kind: .date, value: "2026-13-45"), "YYYY-MM-DD"),
            (DocumentLabel(kind: .language, value: "klingon"), "ISO 639"),
            (DocumentLabel(kind: .topic, value: " \n"), "letter"),
        ]
        for (label, says) in refused {
            let refusal = try #require(LabelError.refusal(of: label), "\(label.kind) “\(label.value)” is no label of its kind")
            #expect(refusal == .notALabel(label.kind, DocumentLabel.oneLine(label.value)), "the value is named as one line")
            #expect(refusal.localizedDescription.contains(says), "the reason says what the kind takes: \(refusal.localizedDescription)")
            await #expect(throws: refusal, "the correction is refused for that reason, not dropped without a word") {
                try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.receipt, label]))
            }
        }
        let edited = try #require(try await h.services.documents.document(id: id))
        #expect(edited.labels == StubAnalyzer.edpBill, "nothing of a refused correction is made, not even the label beside it")
        #expect(try await h.services.history.events(limit: 5, kinds: [.corrected], docID: id).isEmpty, "and nothing is recorded")
        #expect(LabelError.refusal(of: DocumentLabel(kind: .date, value: "31/12/2026")) == nil, "a day written day first is a date")
        #expect(LabelError.refusal(of: Self.receipt) == nil, "and a type Arrumator knows is a type")
    }

    @Test func aRefusalNamesNoKindTheAppCallsOtherwise() throws {
        for kind in LabelKind.modelKinds {
            let refusal = try #require(LabelError.refusal(of: DocumentLabel(kind: kind, value: "§")), "“§” is no \(kind.rawValue)")
            #expect(!refusal.localizedDescription.contains(kind.rawValue),
                    "the app calls a party “About” and an object “Concerns”, the command line party= and object=: \(refusal.localizedDescription)")
        }
        let party = try #require(LabelError.refusal(of: DocumentLabel(kind: .party, value: "123456789")))
        #expect(party.localizedDescription == "“123456789” is no label of its kind: it has a letter in it, and no ;",
                "what a party takes, in words both the card and the command line can show")
        let joined = try #require(LabelError.refusal(of: DocumentLabel(kind: .object, value: "car AA-12-BB; car CC-34-DD")))
        #expect(joined.localizedDescription.hasSuffix("and no ;"), "and why two in one are none: \(joined.localizedDescription)")
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
