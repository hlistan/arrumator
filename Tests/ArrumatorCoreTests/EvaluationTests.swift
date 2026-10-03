@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// How `arrumatorcli eval` scores a reading (`Evaluation`), from what a run recorded, with no model: every number in
/// docs/evaluation.md comes from here.
@Suite struct EvaluationTests {
    /// A corpus entry as `expected.json` writes it: an invoice from EDP, in Portuguese, with an amount and a period.
    static let invoice = """
    {"file": "pt/fatura-edp.pdf", "lang": "pt",
     "expected": {"status": "filed", "doc_type": "invoice", "correspondent": "EDP", "date": "2026-03-01",
                  "title_contains": ["EDP"], "labels": {"amount": ["72.00 EUR"], "period": ["2026-02"], "object": ["CPE PT0002|contador"]}},
     "accept_also": {"correspondent": ["Energias de Portugal"]}}
    """
    /// A byte-identical copy of the invoice.
    static let copyOfInvoice = """
    {"file": "pt/fatura-edp-copia.pdf", "lang": "pt", "duplicate_of": "pt/fatura-edp.pdf",
     "expected": {"status": "duplicate", "title_contains": []}}
    """

    private func fixture(_ json: String) throws -> Evaluation.Fixture {
        try JSONDecoder().decode(Evaluation.Fixture.self, from: Data(json.utf8))
    }

    /// The document a run filed from `dropped`, as `name`, with `labels`.
    private func document(from dropped: String, named name: String, status: DocumentStatus = .filed,
                          labels: [DocumentLabel]) throws -> DocumentRecord {
        var record = DocumentRecord.arrived(path: "/Archive/\(name)", sha256: "0", size: 1, uttype: "com.adobe.pdf", inode: nil, modified: nil,
                                            now: TestTime.start)
        record.originalFilename = dropped
        record.status = status
        record.labelsJson = JSON.string(labels)
        return record
    }

    private static let readRight: [DocumentLabel] = [
        DocumentLabel(kind: .type, value: "invoice"), DocumentLabel(kind: .sender, value: "EDP Comercial"),
        DocumentLabel(kind: .date, value: "2026-03-01"), DocumentLabel(kind: .language, value: "pt"),
        DocumentLabel(kind: .amount, value: "72 EUR"), DocumentLabel(kind: .period, value: "2026-02-01/2026-02-28"),
        DocumentLabel(kind: .object, value: "Contador 123"),
    ]

    private static let dropped = URL(fileURLWithPath: "/Incoming/fatura-edp.pdf")

    @Test func aDocumentReadRightScoresRightOnEveryDetailAndExpectedLabel() throws {
        let invoice = try fixture(Self.invoice)
        let doc = try document(from: "fatura-edp.pdf", named: "2026-03-01 EDP fatura.pdf", labels: Self.readRight)
        let row = Evaluation.score(invoice, pass: 1, document: doc, dropped: Self.dropped, seconds: 2)
        #expect(row.statusOK && row.docTypeOK == true && row.correspondentOK == true && row.dateOK == true && row.titleOK == true
                    && row.languageOK == true, "type, sender by its words, date, name and language are each right: \(row)")
        #expect(row.expectedLabels == ["amount: 72.00 EUR": true, "period: 2026-02": true, "object: CPE PT0002|contador": true],
                "an amount by its number and currency, a period by its start, anything else by any one of its alternatives")
    }

    @Test func aDocumentReadWrongScoresWrongAndOneOfAnotherFileIsMissing() throws {
        let invoice = try fixture(Self.invoice)
        let wrong = try document(from: "fatura-edp.pdf", named: "fatura.pdf", status: .needsReview, labels: [
            DocumentLabel(kind: .type, value: "receipt"), DocumentLabel(kind: .sender, value: "Galp"),
            DocumentLabel(kind: .amount, value: "72.01 EUR"),
        ])
        let row = Evaluation.score(invoice, pass: 1, document: wrong, dropped: Self.dropped, seconds: 2)
        #expect(!row.statusOK && row.docTypeOK == false && row.correspondentOK == false && row.dateOK == false && row.titleOK == false
                    && row.languageOK == false, "each detail read wrong, or not at all, is wrong: \(row)")
        #expect(row.expectedLabels?["amount: 72.00 EUR"] == false, "an amount a cent off is another amount")
        let alsoAccepted = try document(from: "fatura-edp.pdf", named: "EDP.pdf", labels: [DocumentLabel(kind: .sender, value: "Energias de Portugal SA")])
        #expect(Evaluation.score(invoice, pass: 1, document: alsoAccepted, dropped: Self.dropped, seconds: 2).correspondentOK == true,
                "a sender the corpus also accepts is right")
        let other = try document(from: "another.pdf", named: "another.pdf", labels: Self.readRight)
        let missing = Evaluation.score(invoice, pass: 1, document: other, dropped: Self.dropped, seconds: 2)
        #expect(missing.status == Evaluation.missing && !missing.statusOK && missing.docTypeOK == nil,
                "the newest document of another file means this one became none, which is no detail read")
    }

    @Test func aCopyIsRightWhenTheDocumentReadAgainIsTheOneItCopies() throws {
        let copy = try fixture(Self.copyOfInvoice)
        let original = try document(from: "fatura-edp pass2.pdf", named: "EDP.pdf", labels: Self.readRight)
        #expect(Evaluation.copy(copy, pass: 2, original: original, seconds: 1).statusOK, "in the second pass, the second pass's original")
        #expect(!Evaluation.copy(copy, pass: 1, original: original, seconds: 1).statusOK, "not another pass's")
    }

    @Test func aPassIsSummarizedFromItsRows() throws {
        let invoice = try fixture(Self.invoice)
        var second = invoice
        second.file = "pt/fatura-edp-2.pdf"
        let right = Evaluation.score(invoice, pass: 1, document: try document(from: "fatura-edp.pdf", named: "EDP a.pdf", labels: Self.readRight),
                                     dropped: Self.dropped, seconds: 4)
        var otherSender = Self.readRight
        otherSender[1] = DocumentLabel(kind: .sender, value: "EDP")
        let other = Evaluation.score(second, pass: 1, document: try document(from: "fatura-edp-2.pdf", named: "b.pdf", labels: otherSender),
                                     dropped: URL(fileURLWithPath: "/Incoming/fatura-edp-2.pdf"), seconds: 2)
        let lost = Evaluation.score(second, pass: 1, document: nil, dropped: Self.dropped, seconds: 9)
        let summary = Evaluation.summarize(pass: 1, rows: [right, other, lost], corpus: [invoice, second])
        #expect(summary.statusAccuracy == 2.0 / 3 && summary.docTypeAccuracy == 1 && summary.titleAccuracy == 0.5,
                "each share counts the rows that say, a missing one wrong only where it says: \(summary)")
        #expect(summary.labelled == 2.0 / 3 && summary.labelsPerDocument == Double(Self.readRight.count),
                "of the documents to be filed, those labelled, and how many labels each got")
        #expect(summary.senderWritings == 2, "the one sender was written two ways over its two documents")
        #expect(summary.coverage[LabelKind.amount.rawValue] == 1 && summary.distinctByKind[LabelKind.sender.rawValue] == 2,
                "every labelled document got an amount, and two senders were given in all")
        #expect(summary.expectedFound == 1 && summary.medianSeconds == 4, "every expected label found; the middle time")
        #expect(Evaluation.droppedName("pt/fatura-edp.pdf", pass: 1) == "fatura-edp.pdf"
                    && Evaluation.droppedName("pt/fatura-edp.pdf", pass: 3) == "fatura-edp pass3.pdf",
                "a later pass drops each file under a name of its own")
    }
}
