@testable import ArrumatorClassify
import ArrumatorCore
import Foundation
import Testing

/// An object or a reference is made of a number the document writes (`ReadingGrounds.writesNumber(of:)`).
extension LabelFormTests {
    /// A live reading of 9 October 2026: qwen3:8b gave a Hetzner invoice the reference the prompt gives as an example,
    /// "invoice FT 2026/926804564", which the invoice never writes. An object or a reference is made of a number the
    /// document writes, in whole words, however it groups, spaces or writes its digits; one it does not write is
    /// dropped, and noted, as a name it does not write is. An amount, written in its kind's form, is not checked.
    @Test func aNumberTheDocumentDoesNotWriteIsNone() throws {
        let invoice = Self.hetzner + "\nUSt-IdNr. DE 812871812"
        let v = try Self.validate([.sender: ["Hetzner Online GmbH"], .party: [],
                                   .object: ["electricity supply point PT0002000012345678", "car AA-12-BB"],
                                   .reference: ["invoice FT 2026/926804564", "invoice 042/2026"], .amount: ["54.21 EUR"]],
                                  title: "Invoice cloud services", text: invoice)
        #expect(v.labels.values(.reference) == ["invoice 042/2026"] && v.labels.values(.object).isEmpty,
                "the prompt's examples, which the invoice never writes, are none of its labels, and its own number stands")
        #expect(v.notes == ["objects: “electricity supply point PT0002000012345678” has a number the document does not write, dropped",
                            "objects: “car AA-12-BB” has a number the document does not write, dropped",
                            "references: “invoice FT 2026/926804564” has a number the document does not write, dropped"],
                "a short number inside another is not written either, and the trace says which and why: \(v.notes)")
        #expect(v.labels.values(.amount) == ["54.21 EUR"], "an amount is not checked: a scale or a total may write it otherwise")

        let otherwise = "Referência Multibanco 12345 678 901\nお客さま番号 ０３-３５４２-５５４５\nفاتورة رقم ٢٠٢٦/١٧\nConta 0123456789\n"
            + "Cliente 00012345\nServidor CPX31\nID do servidor: 42368634\n家賃 12万円 · 第Ⅻ号 · ⑩"
        let written = try Self.validate([.sender: [], .party: [], .object: ["cloud server CPX31 #42368634"],
                                         .reference: ["Multibanco reference 12345678901", "customer 03-3542-5545", "invoice 2026/17",
                                                      "account 0123 456 789", "customer 12345", "rent 12"]],
                                        title: "Referência", text: otherwise)
        #expect(written.labels.values(.reference).count == 6 && written.labels.values(.object).count == 1 && written.notes.isEmpty,
                "regrouped, in full width or another script, without its leading zeros, or of numbers written apart, it is written: \(written.notes)")

        let merged = [LabelPreference(from: DocumentLabel(kind: .object, value: "phone line 912345678"), to: "phone line +351 912345678")]
        let preferred = try Self.validate([.sender: [], .party: [], .object: ["phone line +351 912345678"]], title: "Fatura",
                                          text: "Fatura MEO\nLinha 912 345 678", preferred: merged)
        #expect(preferred.labels.values(.object) == ["phone line +351 912345678"],
                "a number written as the owner merged one the document writes stands: \(preferred.notes)")
        let otherMerge = try Self.validate([.sender: [], .party: [], .object: ["phone line 111222333"]], title: "Fatura",
                                           text: "Fatura MEO\nLinha 912 345 678", preferred: merged)
        #expect(otherMerge.labels.values(.object).isEmpty, "a merge whose source the document writes grounds only the label it merges into")
        let unwritten = try Self.validate([.sender: [], .party: [], .object: ["phone line +351 912345678"]], title: "Fatura",
                                          text: "Fatura MEO\nLinha 913 000 000", preferred: merged)
        #expect(unwritten.labels.values(.object).isEmpty, "nor that label where the document does not write the merge's source")

        var seen = Fixtures.content("talao.jpg", text: "", date: nil)
        seen.visual = VisualSummary(imageKind: .photo, description: "A till receipt", visibleTextSummary: "Talão 4711 Total 12,50 €",
                                    organisations: [], dates: [])
        let picture = try Fixtures.validator(PipelineConfig.bundledDefaults().labels, grounds: Fixtures.grounds(seen))
            .validate(Fixtures.answer(Fixtures.otherDocument([.sender: [], .party: [], .reference: ["receipt 4711"]]), title: "Till receipt"))
        #expect(picture.labels.values(.reference) == ["receipt 4711"], "a number the vision model read in a picture is the document's: \(picture.notes)")
        let blank = try Self.validate([.reference: ["invoice FT 2026/926804564"]], title: "Scan", text: "")
        #expect(blank.labels.values(.reference) == ["invoice FT 2026/926804564"],
                "a document nothing was read of has no numbers to tell by, and is not checked: \(blank.notes)")
        #expect(ReadingGrounds.numbers(in: ["Contrato", "0123", "456", "de", "2025"], words: 6) == ["123", "456", "123456", "2025"],
                "a number is written over words with digits that follow one another, without its leading zeros")
        let limited = ReadingGrounds.numbers(in: ["0123", "456", "789"], words: 2)
        #expect(limited.contains("456789") && !limited.contains("123456789"), "and over labels.numberWords of them at most: \(limited)")
    }

    /// The Standard evaluation of 13 October 2026: a statement printing its IBAN in groups of four,
    /// `UA21 3052 9900 0002 6715 7298 5812 7`, lost the object the model wrote of it unbroken, as an IBAN is written in
    /// a machine, its eight words more than a number was told over. An IBAN has up to 34 characters, printed in groups
    /// of four (ISO 13616-1), so nine words; and its groups may be letters alone (`NL91 ABNA 0417 1643 00`), which no
    /// run of digits crosses. A word of the label is written when the document writes its letters and digits over words
    /// that follow one another on a line, in the same order; a word whose letters it writes otherwise is not.
    @Test func aNumberTheDocumentGroupsIsWrittenUnbrokenToo() throws {
        let statement = "Виписка по рахунку\nIBAN UA21 3052 9900 0002 6715 7298 5812 7\nRekening NL91 ABNA 0417 1643 00\n"
            + "Account GB29 NWBK 6016 1331 9268 19 (Natwest)\nNL91 ABNB\n0417 1643 00\nСчёт RU02 0445 2560 0407 0281 0412 3456 7890 1\n"
            + "Servidor CPX31\nID: ٠٤٢٣٦٨٦٣٤\nParcela 12 AB 34 CD"
        let v = try Self.validate([.sender: [], .party: [],
                                   .object: ["savings account UA213052990000026715729858127", "account NL91ABNA0417164300",
                                             "account gb29nwbk60161331926819", "account RU0204452560040702810412345678901",
                                             "cloud server CPX31 #42368634", "parcel 12AB34CD"],
                                   .reference: ["account NL91ABNB0417164300", "account NL91ABNA041716430"]],
                                  title: "Виписка", text: statement)
        #expect(v.labels.values(.object) == ["savings account UA213052990000026715729858127", "account NL91ABNA0417164300",
                                             "account gb29nwbk60161331926819", "account RU0204452560040702810412345678901",
                                             "cloud server CPX31 #42368634", "parcel 12AB34CD"],
                "an IBAN in up to nine groups, cased as it may be, one ending in letters, a number on a line of its own: \(v.notes)")
        #expect(v.labels.values(.reference).isEmpty,
                "but not with letters it does not write so, across a line, or a digit left out of a group: \(v.labels)")
        let limited = ReadingGrounds.writings(in: ["NL91", "ABNA", "0417"].map { ReadingGrounds.spelled($0) }, words: 2)
        #expect(limited.contains("abna0417") && !limited.contains("nl91abna0417"), "over labels.numberWords words at most: \(limited)")
    }
}
