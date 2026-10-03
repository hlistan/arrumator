import ArrumatorCore
@testable import ArrumatorExtract
import Foundation
import Testing

@Suite("Language, encodings and plain text")
struct TextAndLanguageTests {
    private let russian = """
    Уважаемый клиент! Настоящим сообщаем, что договор страхования продлён до 31 декабря 2025 года. \
    С уважением, отдел обслуживания клиентов.
    """
    private let portuguese = """
    Caro cliente, informamos que a sua fatura de eletricidade já está disponível para pagamento. \
    Obrigado pela preferência e até breve.
    """
    private let english = """
    Dear customer, we are pleased to confirm that your insurance policy has been renewed until the end of \
    December. Kind regards, customer service.
    """

    @Test("Detects any language, not only the OCR hints; no letters is undetermined")
    func languages() throws {
        let config = try TestConfig.pipeline().extraction
        let detector = LanguageDetector(config: config)
        #expect(detector.detect(english).primary == "en", "English is detected as English")
        #expect(detector.detect(russian).primary == "ru", "Russian is detected as Russian")
        #expect(detector.detect(portuguese).primary == "pt", "Portuguese is detected as Portuguese")
        #expect(detector.detect(portuguese).confidence > 0.5, "a paragraph of Portuguese is detected with confidence")
        #expect(detector.detect(german).primary == "de", "a language outside the hints is itself, not other")
        #expect(detector.detect(japanese).primary == "ja", "in any script")
        #expect(detector.detect(chinese).primary == "zh", "a script variant is its language's ISO 639-1 code")
        #expect(detector.detect("12345 / 67.89").primary == "und", "text without letters has no language")
        #expect(detector.ranked(for: russian).first == "ru", "OCR tries the document's own language first")
        #expect(detector.ranked(for: german) == ["de"] + config.ocrLanguages, "a document's own language goes ahead of the hints")
        #expect(detector.ranked(for: "") == config.ocrLanguages, "without text, the hints alone, in their order")
    }

    private let german = """
    Sehr geehrte Damen und Herren, hiermit bestätigen wir den Eingang Ihrer Kündigung zum Ende des Monats.     Mit freundlichen Grüßen, Ihr Kundenservice.
    """
    private let chinese = "本合同为固定期限劳动合同，甲方每月十日以货币形式支付乙方工资，双方按照国家规定参加社会保险。"
    private let japanese = "拝啓 平素より格別のご高配を賜り、厚く御礼申し上げます。ご請求書を同封いたしましたので、ご確認ください。"

    @Test("Below the confidence floor the primary language is 'other'")
    func otherLanguage() throws {
        let config = try TestConfig.context { extraction, _ in extraction.languageMinConfidence = 1.01 }.config
        #expect(LanguageDetector(config: config).detect(english).primary == "other", "a guess below languageMinConfidence is not trusted")
    }

    @Test("KOI8-R and CP1251 are told apart by Russian bigrams")
    func cyrillicEncodings() async throws {
        let scratch = try Scratch()
        let koi8 = try #require(TextEncodingDetector.encoding(named: "koi8R"))
        let registry = try TestConfig.registry()
        let context = try TestConfig.context()
        for (name, encoding, iana) in [("koi8.txt", koi8, "koi8-r"), ("cp1251.txt", String.Encoding.windowsCP1251, "windows-1251")] {
            let url = try scratch.write(name, russian, encoding: encoding)
            let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
            #expect(content.metadata["text:encoding"] == iana, "\(name): the Cyrillic code page is told apart by Russian bigrams")
            #expect(content.text.contains("Уважаемый клиент"), "\(name): the text is decoded, not mojibake")
            #expect(content.warnings.map(\.code) == [.encodingGuessed], "\(name): a guessed encoding is noted, since it may be wrong")
            #expect(content.language.primary == "ru", "\(name): the decoded text is detected as Russian")
        }
    }

    @Test("Latin-1 Portuguese is not mistaken for Cyrillic; UTF-8 needs no guess")
    func latinAndUTF8() async throws {
        let scratch = try Scratch()
        let registry = try TestConfig.registry()
        let context = try TestConfig.context()
        let latin = try scratch.write("latin1.txt", "Informação: fatura nº 12, emissão 20/05/2026. Obrigação cumprida.",
                                      encoding: .isoLatin1)
        let latinContent = try await registry.extract(latin, sha256: "x", context: context, trace: .disabled)
        #expect(latinContent.text.contains("Informação"), "Latin-1 accents are decoded")
        #expect(latinContent.metadata["text:encoding"] != "koi8-r", "Portuguese bytes are not read as KOI8-R")
        #expect(latinContent.metadata["text:encoding"] != "windows-1251", "nor as CP1251")

        let utf8 = try scratch.write("utf8.md", "# Nota\n\n" + portuguese)
        let utf8Content = try await registry.extract(utf8, sha256: "x", context: context, trace: .disabled)
        #expect(utf8Content.metadata["text:encoding"] == "utf-8", "valid UTF-8 is read as UTF-8")
        #expect(utf8Content.warnings.map(\.code) == [], "valid UTF-8 needs no guess, so nothing is noted")
        #expect(utf8Content.kind == .textDocument, "Markdown is a text document")
        #expect(utf8Content.textOrigin == .textLayer, "plain text is read as it is")
    }

    @Test("CSV keeps the header plus csvMaxRows rows as TSV, handling quotes and semicolons")
    func csv() async throws {
        let scratch = try Scratch()
        var csv = "Data;Descrição;Valor\n"
        for index in 1...10 { csv += "0\(index % 9 + 1)/05/2026;\"Pagamento; ref \(index)\";\(index),50\n" }
        let url = try scratch.write("movimentos.csv", csv)
        let context = try TestConfig.context { extraction, _ in extraction.csvMaxRows = 3 }
        let content = try await TestConfig.registry().extract(url, sha256: "x", context: context, trace: .disabled)
        let lines = content.text.split(separator: "\n")
        #expect(content.kind == .spreadsheet, "a CSV is a spreadsheet")
        #expect(lines.count == 4, "the header and csvMaxRows rows are kept")
        #expect(lines.first == "Data\tDescrição\tValor", "semicolon-separated cells become tab-separated")
        #expect(lines[1] == "02/05/2026\tPagamento; ref 1\t1,50", "a quoted cell keeps its semicolon and loses its quotes")
        let table = try #require(content.structure?.tables.first)
        #expect(table.hasPrefix("Data\tDescrição\tValor\n"), "the table starts with its header row")
    }

    @Test("A CRLF CSV's delimiter is its first line's; rows past csvMaxRows are noted, and no cell keeps a line break")
    func csvLinesAndCuts() async throws {
        let scratch = try Scratch()
        // One semicolon on the header; more commas than that on the rows after it, which must not decide.
        let rows = ["Conta;Saldo", "Ordem;1,234,567.00", "\"Poupança\r\nhabitação\rjovem\";2,500,000.00", "Prazo;10,000.00"]
        let url = try scratch.write("saldos.csv", rows.joined(separator: "\r\n") + "\r\n")
        let cut = try TestConfig.context { extraction, _ in extraction.csvMaxRows = 2 }
        let content = try await TestConfig.registry().extract(url, sha256: "x", context: cut, trace: .disabled)
        #expect(content.text.split(separator: "\n") == ["Conta\tSaldo", "Ordem\t1,234,567.00", "Poupança habitação jovem\t2,500,000.00"],
                "the semicolon of the first line separates the cells, and a cell's line breaks, CR and CRLF too, are spaces")
        #expect(content.warnings.map(\.detail) == ["kept the header and the first 2 rows"],
                "the rows left out are noted, so the model knows it saw part of the table (\(content.warningSummary))")

        let whole = try TestConfig.context { extraction, _ in extraction.csvMaxRows = 3 }
        let all = try await TestConfig.registry().extract(url, sha256: "x", context: whole, trace: .disabled)
        #expect(all.text.split(separator: "\n").count == 4, "with room for every row, every row is kept")
        #expect(all.warnings.isEmpty, "and nothing is noted, the line break that ends the file being no row (\(all.warningSummary))")
    }

    @Test("Russian plausibility separates real text from KOI8-R/CP1251 mix-ups, even for short samples")
    func plausibility() throws {
        let koi8 = try #require(TextEncodingDetector.encoding(named: "koi8R"))
        for sample in [russian, "Привет", "Счёт на оплату 15"] {
            let data = try #require(sample.data(using: koi8))
            let misread = try #require(String(data: data, encoding: .windowsCP1251))
            #expect(TextEncodingDetector.russianPlausibility(sample) > TextEncodingDetector.russianPlausibility(misread), "\(sample): real Russian scores above its KOI8-R bytes read as CP1251")
        }
        #expect(TextEncodingDetector.russianPlausibility("Informação cumprida") <= 0, "Latin text is not plausible Russian")
    }

    @Test("Short KOI8-R text is still decoded correctly")
    func shortKOI8() async throws {
        let scratch = try Scratch()
        let koi8 = try #require(TextEncodingDetector.encoding(named: "koi8R"))
        let url = try scratch.write("short.txt", "Счёт на оплату 15", encoding: koi8)
        let content = try await TestConfig.registry().extract(url, sha256: "x", context: try TestConfig.context(),
                                                            trace: .disabled)
        #expect(content.text == "Счёт на оплату 15", "a few KOI8-R words are enough to decode them")
        #expect(content.metadata["text:encoding"] == "koi8-r", "and the encoding is named")
    }
}
