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
        let detector = LanguageDetector(config: try TestConfig.pipeline().extraction)
        #expect(detector.detect(english).primary == "en")
        #expect(detector.detect(russian).primary == "ru")
        #expect(detector.detect(portuguese).primary == "pt")
        #expect(detector.detect(portuguese).confidence > 0.5)
        #expect(detector.detect(german).primary == "de", "a language outside the hints is itself, not other")
        #expect(detector.detect(japanese).primary == "ja", "in any script")
        #expect(detector.detect(chinese).primary == "zh", "a script variant is its language's ISO 639-1 code")
        #expect(detector.detect("12345 / 67.89").primary == "und")
        #expect(detector.ranked(for: russian).first == "ru")
        #expect(detector.ranked(for: german) == ["de", "en", "ru", "pt"], "a document's own language goes ahead of the hints")
        #expect(detector.ranked(for: "").first == "en")
    }

    private let german = """
    Sehr geehrte Damen und Herren, hiermit bestätigen wir den Eingang Ihrer Kündigung zum Ende des Monats.     Mit freundlichen Grüßen, Ihr Kundenservice.
    """
    private let chinese = "本合同为固定期限劳动合同，甲方每月十日以货币形式支付乙方工资，双方按照国家规定参加社会保险。"
    private let japanese = "拝啓 平素より格別のご高配を賜り、厚く御礼申し上げます。ご請求書を同封いたしましたので、ご確認ください。"

    @Test("Below the confidence floor the primary language is 'other'")
    func otherLanguage() throws {
        let config = try TestConfig.context { extraction, _ in extraction.languageMinConfidence = 1.01 }.config
        #expect(LanguageDetector(config: config).detect(english).primary == "other")
    }

    @Test("KOI8-R and CP1251 are told apart by Russian bigrams")
    func cyrillicEncodings() async throws {
        let scratch = try Scratch()
        let koi8 = try #require(TextEncodingDetector.encoding(named: "koi8R"))
        let registry = ExtractorRegistry()
        let context = try TestConfig.context()
        for (name, encoding, iana) in [("koi8.txt", koi8, "koi8-r"), ("cp1251.txt", String.Encoding.windowsCP1251, "windows-1251")] {
            let url = try scratch.write(name, russian, encoding: encoding)
            let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
            #expect(content.metadata["text:encoding"] == iana, "\(name)")
            #expect(content.text.contains("Уважаемый клиент"), "\(name)")
            #expect(content.hasWarning(.encodingGuessed))
            #expect(content.language.primary == "ru")
        }
    }

    @Test("Latin-1 Portuguese is not mistaken for Cyrillic; UTF-8 needs no guess")
    func latinAndUTF8() async throws {
        let scratch = try Scratch()
        let registry = ExtractorRegistry()
        let context = try TestConfig.context()
        let latin = try scratch.write("latin1.txt", "Informação: fatura nº 12, emissão 20/05/2026. Obrigação cumprida.",
                                      encoding: .isoLatin1)
        let latinContent = try await registry.extract(latin, sha256: "x", context: context, trace: .disabled)
        #expect(latinContent.text.contains("Informação"))
        #expect(latinContent.metadata["text:encoding"] != "koi8-r")
        #expect(latinContent.metadata["text:encoding"] != "windows-1251")

        let utf8 = try scratch.write("utf8.md", "# Nota\n\n" + portuguese)
        let utf8Content = try await registry.extract(utf8, sha256: "x", context: context, trace: .disabled)
        #expect(utf8Content.metadata["text:encoding"] == "utf-8")
        #expect(!utf8Content.hasWarning(.encodingGuessed))
        #expect(utf8Content.kind == .textDocument)
        #expect(utf8Content.textOrigin == .textLayer)
    }

    @Test("CSV keeps the header plus csvMaxRows rows as TSV, handling quotes and semicolons")
    func csv() async throws {
        let scratch = try Scratch()
        var csv = "Data;Descrição;Valor\n"
        for index in 1...10 { csv += "0\(index % 9 + 1)/05/2026;\"Pagamento; ref \(index)\";\(index),50\n" }
        let url = try scratch.write("movimentos.csv", csv)
        let context = try TestConfig.context { extraction, _ in extraction.csvMaxRows = 3 }
        let content = try await ExtractorRegistry().extract(url, sha256: "x", context: context, trace: .disabled)
        let lines = content.text.split(separator: "\n")
        #expect(content.kind == .spreadsheet)
        #expect(lines.count == 4)
        #expect(lines.first == "Data\tDescrição\tValor")
        #expect(lines[1].contains("Pagamento; ref 1"))
        #expect(content.structure?.tables.first?.hasPrefix("Data\tDescrição") == true)
    }

    @Test("Russian plausibility separates real text from KOI8-R/CP1251 mix-ups, even for short samples")
    func plausibility() throws {
        let koi8 = try #require(TextEncodingDetector.encoding(named: "koi8R"))
        for sample in [russian, "Привет", "Счёт на оплату 15"] {
            let data = try #require(sample.data(using: koi8))
            let misread = try #require(String(data: data, encoding: .windowsCP1251))
            #expect(TextEncodingDetector.russianPlausibility(sample) > TextEncodingDetector.russianPlausibility(misread))
        }
        #expect(TextEncodingDetector.russianPlausibility("Informação cumprida") <= 0)
    }

    @Test("Short KOI8-R text is still decoded correctly")
    func shortKOI8() async throws {
        let scratch = try Scratch()
        let koi8 = try #require(TextEncodingDetector.encoding(named: "koi8R"))
        let url = try scratch.write("short.txt", "Счёт на оплату 15", encoding: koi8)
        let content = try await ExtractorRegistry().extract(url, sha256: "x", context: try TestConfig.context(),
                                                            trace: .disabled)
        #expect(content.text == "Счёт на оплату 15")
        #expect(content.metadata["text:encoding"] == "koi8-r")
    }
}
