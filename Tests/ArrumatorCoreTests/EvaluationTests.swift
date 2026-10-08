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
        record.labelsJson = try JSON.string(labels)
        return record
    }

    private static let readRight: [DocumentLabel] = [
        DocumentLabel(kind: .type, value: "invoice"), DocumentLabel(kind: .sender, value: "EDP Comercial"),
        DocumentLabel(kind: .date, value: "2026-03-01"), DocumentLabel(kind: .language, value: "pt"),
        DocumentLabel(kind: .amount, value: "72 EUR"), DocumentLabel(kind: .period, value: "2026-02-01/2026-02-28"),
        DocumentLabel(kind: .object, value: "Contador 123"),
    ]

    private static let dropped = URL(fileURLWithPath: "/Incoming/fatura-edp.pdf")

    /// What tells the language the model said what a document is in.
    private static func languages() throws -> LanguageDetector { LanguageDetector(config: try PipelineConfig.bundledDefaults().extraction) }

    @Test func whatTheModelSaidADocumentIsIsScoredByWhetherItSaidAnyAndInTheDocumentsLanguage() throws {
        let invoice = try fixture(Self.invoice)
        func read(_ interpretation: String?) throws -> Evaluation.Row {
            var doc = try document(from: "fatura-edp.pdf", named: "EDP.pdf", labels: Self.readRight)
            doc.analysisJson = try JSON.string(DocumentAnalysis(interpretation: interpretation, model: "m"))
            return Evaluation.score(invoice, pass: 1, document: doc, dropped: Self.dropped, languages: try Self.languages(), seconds: 1)
        }
        let portuguese = try read("Fatura de eletricidade da EDP Comercial referente a fevereiro de 2026, no valor de 72 euros, a pagar em março.")
        #expect(portuguese.interpreted == true && portuguese.interpretationLanguageOK == true,
                "said, in Portuguese, the language the corpus wrote the invoice in: \(portuguese)")
        let english = try read("An electricity invoice from EDP Comercial for February 2026, for 72 euros, to be paid in March.")
        #expect(english.interpreted == true && english.interpretationLanguageOK == false, "said in English, of a Portuguese invoice, is said in another")
        let unsaid = try read(nil)
        #expect(unsaid.interpreted == false && unsaid.interpretationLanguageOK == nil, "and said nothing is no language right or wrong")
        let summary = Evaluation.summarize(pass: 1, rows: [portuguese, english, unsaid], corpus: [invoice])
        #expect(summary.interpreted == 2.0 / 3 && summary.interpretationLanguage == 0.5,
                "of the documents to be filed, those said, and of those, the share in their language: \(summary)")
    }

    @Test func aDocumentReadRightScoresRightOnEveryDetailAndExpectedLabel() throws {
        let invoice = try fixture(Self.invoice)
        let doc = try document(from: "fatura-edp.pdf", named: "2026-03-01 EDP fatura.pdf", labels: Self.readRight)
        let row = Evaluation.score(invoice, pass: 1, document: doc, dropped: Self.dropped, languages: try Self.languages(), seconds: 2)
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
        let row = Evaluation.score(invoice, pass: 1, document: wrong, dropped: Self.dropped, languages: try Self.languages(), seconds: 2)
        #expect(!row.statusOK && row.docTypeOK == false && row.correspondentOK == false && row.dateOK == false && row.titleOK == false
                    && row.languageOK == false, "each detail read wrong, or not at all, is wrong: \(row)")
        #expect(row.expectedLabels?["amount: 72.00 EUR"] == false, "an amount a cent off is another amount")
        let alsoAccepted = try document(from: "fatura-edp.pdf", named: "EDP.pdf", labels: [DocumentLabel(kind: .sender, value: "Energias de Portugal SA")])
        #expect(Evaluation.score(invoice, pass: 1, document: alsoAccepted, dropped: Self.dropped, languages: try Self.languages(), seconds: 2).correspondentOK == true,
                "a sender the corpus also accepts is right")
        let other = try document(from: "another.pdf", named: "another.pdf", labels: Self.readRight)
        let missing = Evaluation.score(invoice, pass: 1, document: other, dropped: Self.dropped, languages: try Self.languages(), seconds: 2)
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
                                     dropped: Self.dropped, languages: try Self.languages(), seconds: 4)
        var otherSender = Self.readRight
        otherSender[1] = DocumentLabel(kind: .sender, value: "EDP")
        let other = Evaluation.score(second, pass: 1, document: try document(from: "fatura-edp-2.pdf", named: "b.pdf", labels: otherSender),
                                     dropped: URL(fileURLWithPath: "/Incoming/fatura-edp-2.pdf"),
                                     languages: try Self.languages(), seconds: 2)
        let lost = Evaluation.score(second, pass: 1, document: nil, dropped: Self.dropped, languages: try Self.languages(), seconds: 9)
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

    // MARK: Pairs of labels the model judges

    static let corpus = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/expected.json", directoryHint: .notDirectory)

    @Test func everyPairOfTheCorpusIsTwoLabelsTheArchiveCouldHoldOfAKindTheVocabularyKeeps() throws {
        let corpus = try JSONDecoder().decode(Evaluation.Corpus.self, from: Data(contentsOf: Self.corpus))
        let vocabulary = try PipelineConfig.bundledDefaults().labels.vocabulary
        #expect(corpus.labelPairs.count >= 20, "the corpus has pairs to judge: \(corpus.labelPairs.count)")
        for pair in corpus.labelPairs {
            #expect(pair.problem(vocabulary: vocabulary) == nil, "“\(pair.value)” / “\(pair.into)”: \(pair.problem(vocabulary: vocabulary) ?? "")")
            #expect(pair.valueDocuments >= pair.valueNames.count && pair.intoDocuments >= pair.intoNames.count,
                    "as many documents have each as are named, at least: \(pair.value)")
        }
        #expect(Set(corpus.labelPairs.map(\.expected)) == [.same, .different], "both answers are measured")
        #expect(Set(corpus.labelPairs.filter(\.heldOut).map(\.expected)) == [.same, .different], "of what the prompt does not show too")
        #expect(Set(corpus.labelPairs.map(\.kind)) == Set(vocabulary.kinds.keys), "and pairs of every kind the vocabulary keeps")
    }

    @Test func aPairThatCouldNotBeInTheArchiveIsSaidToBeSo() throws {
        let vocabulary = try PipelineConfig.bundledDefaults().labels.vocabulary
        let alike = { (kind: String, value: String, into: String) in
            try JSONDecoder().decode(Evaluation.PairCase.self, from: Data("""
            {"kind": "\(kind)", "value": "\(value)", "into": "\(into)", "value_documents": 1, "value_names": [], "into_documents": 1,
             "into_names": [], "same": true, "why": "a test", "held_out": false}
            """.utf8))
        }
        let pair = { (kind: String, value: String) in try alike(kind, value, "EDP") }
        #expect(try pair("sender", "EDP Comercial").problem(vocabulary: vocabulary) == nil, "two senders in their form")
        #expect(try alike("party", "Ribeiro Marta Lopes", "Marta Lopes Ribeiro").problem(vocabulary: vocabulary)
                    == "“Ribeiro Marta Lopes” and “Marta Lopes Ribeiro” are written alike, so the archive keeps them as one",
                "two labels whose words differ only in order, which a reading merges and the model is never asked about")
        #expect(try pair("sender", " EDP  Comercial").problem(vocabulary: vocabulary) == "“ EDP  Comercial” is no sender as the archive keeps one",
                "a label not as the archive keeps it")
        #expect(try pair("type", "invoice").problem(vocabulary: vocabulary) == "type is no kind the vocabulary keeps", "a kind with one form")
        #expect(try pair("tag", "Taxes").problem(vocabulary: vocabulary) == "tag is no kind the vocabulary keeps", "the user's own tags")
    }

    @Test func pairsAreScoredRightAndWrongByWhatAWrongJudgementWouldDo() throws {
        let pair = { (same: Bool, heldOut: Bool) in
            try JSONDecoder().decode(Evaluation.PairCase.self, from: Data("""
            {"kind": "party", "value": "Mario Silva", "into": "Maria Silva", "value_documents": 1, "value_names": [], "into_documents": 2,
             "into_names": [], "same": \(same), "why": "a test", "held_out": \(heldOut)}
            """.utf8))
        }
        let verdict = { (judgement: LabelJudgement?) in LabelVerdict(judgement: judgement, reason: nil, model: "m", problem: nil) }
        let rows = [
            Evaluation.PairRow(pass: 1, pair: try pair(false, true), verdict: verdict(.different), seconds: 1),
            Evaluation.PairRow(pass: 1, pair: try pair(true, false), verdict: verdict(.same), seconds: 2),
            Evaluation.PairRow(pass: 1, pair: try pair(false, true), verdict: verdict(.same), seconds: 3),
            Evaluation.PairRow(pass: 1, pair: try pair(true, false), verdict: verdict(.different), seconds: 4),
            Evaluation.PairRow(pass: 1, pair: try pair(true, false), verdict: verdict(nil), seconds: 5),
        ]
        let summary = Evaluation.summarize(pass: 1, pairs: rows)
        #expect(summary.pairs == 5 && summary.accuracy == 0.4, "two of five judged right")
        #expect(summary.wronglyMerged == 1 && summary.wronglyKeptApart == 1 && summary.unanswered == 1,
                "a wrong merge, a wrong keeping apart and no answer, each counted on its own")
        #expect(summary.heldOut == 2 && summary.heldOutAccuracy == 0.5, "of the two held out from the prompt, one judged right")
        #expect(summary.medianSeconds == 3, "and the median time")
        #expect(Evaluation.summarize(pass: 1, pairs: []).accuracy == 0, "no pair, nothing right")
    }
}
