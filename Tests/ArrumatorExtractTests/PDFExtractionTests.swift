import ArrumatorCore
@testable import ArrumatorExtract
import CoreGraphics
import Foundation
import PDFKit
import Testing

@Suite("PDF extraction")
struct PDFExtractionTests {
    private let registry = ExtractorRegistry()

    @Test("Text PDF: text layer, metadata, entities and label date")
    func textPDF() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeTextPDF("invoice.pdf", pages: [
            ["EDP Comercial", "Fatura FT 2026/0042", "Data de emissão: 20/05/2026", "Data de vencimento: 10/06/2026",
             "NIF: 503 504 564", "IBAN PT50 0002 0123 1234 5678 9015 4", "Total a pagar: 45,90 €"],
            ["Condições gerais do contrato de fornecimento de energia elétrica."],
        ], info: [kCGPDFContextTitle: "Fatura EDP", kCGPDFContextAuthor: "EDP"])
        let sink = MemoryTraceSink()
        let content = try await registry.extract(url, sha256: "abc", context: try TestConfig.context(),
                                                 trace: TraceContext(traceID: 1, sink: sink))
        #expect(content.kind == .pdfText)
        #expect(content.textOrigin == .textLayer)
        #expect(content.pageCount == 2)
        #expect(content.pagesOCRed.isEmpty)
        #expect(content.text.contains("Fatura FT 2026/0042"))
        #expect(content.metadata["pdf:title"] == "Fatura EDP")
        #expect(content.metadata["pdf:author"] == "EDP")
        #expect(content.language.primary == "pt")
        #expect(content.entities.documentDate?.date == "2026-05-20")
        #expect(content.entities.documentDate?.source == .label)
        #expect(content.entities.stableKeys.contains(StableKey(kind: .iban, value: "PT50000201231234567890154")))
        #expect(content.entities.stableKeys.contains(StableKey(kind: .ptNIF, value: "503504564")))
        #expect(content.entities.amounts.contains(MoneyAmount(value: "45.90", currency: "EUR")))
        #expect(content.source.sha256 == "abc")
        #expect(content.extractorName == "pdf")
        let stages = await sink.steps.map(\.stage)
        #expect(stages == [.extract, .entities])
    }

    @Test("Scanned Russian PDF is OCRed and key words are recovered")
    func scannedRussian() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImagePDF("scan-ru.pdf", pages: [[
            "ПАО Сбербанк", "Счёт на оплату № 1234 от 15 мая 2024 г.", "ИНН 7707083893 КПП 773601001",
            "Итого к оплате: 12 500,00 руб.", "Срок оплаты: 30.05.2024",
        ]])
        let sink = MemoryTraceSink()
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(),
                                                 trace: TraceContext(traceID: 7, sink: sink))
        #expect(content.kind == .pdfScanned)
        #expect(content.textOrigin == .ocr, "a scanned page is read by OCR (\(content.warningSummary))")
        #expect(content.pagesOCRed == [1])
        #expect(content.text.contains("Сбербанк"))
        #expect(content.text.contains("оплату"))
        #expect(content.language.primary == "ru")
        #expect(content.entities.stableKeys.contains(StableKey(kind: .ruINN, value: "7707083893")))
        #expect(content.entities.documentDate?.date == "2024-05-15")
        let ocr = try #require(content.ocr)
        #expect(ocr.pages == [1])
        #expect(ocr.meanConfidence > 0.3)
        let steps = await sink.steps
        #expect(steps.map(\.stage) == [.ocr, .extract, .entities])
        let ocrStep = try #require(steps.first)
        #expect(ocrStep.output?.contains("\"page\":1") == true)
        #expect(ocrStep.input?.contains("fewCharacters") == true)
    }

    @Test("Scanned Portuguese PDF is OCRed and key words are recovered")
    func scannedPortuguese() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImagePDF("scan-pt.pdf", pages: [[
            "Autoridade Tributária e Aduaneira", "Data de emissão: 20 de maio de 2026", "NIF 999999990",
            "Total a pagar: 1.234,56 €", "Obrigado pela preferência",
        ]])
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.kind == .pdfScanned)
        #expect(content.text.contains("Tributária"), "OCR reads the scanned page (\(content.warningSummary))")
        #expect(content.text.contains("preferência"))
        #expect(content.language.primary == "pt")
        #expect(content.entities.documentDate?.date == "2026-05-20")
        #expect(content.entities.stableKeys.contains(StableKey(kind: .ptNIF, value: "999999990")))
    }

    @Test("Mixed PDF: text page plus scanned page")
    func mixed() async throws {
        let scratch = try Scratch()
        let text = try scratch.writeTextPDF("text.pdf", pages: [[
            "Relatório anual de atividades da associação de moradores do bairro.",
            "Este documento resume as atividades realizadas durante o ano.",
        ]])
        let scan = try scratch.writeImagePDF("scan.pdf", pages: [["Anexo digitalizado", "Assinatura do presidente"]])
        let merged = try #require(PDFMerge.merge([text, scan], into: scratch.url("mixed.pdf")))
        let content = try await registry.extract(merged, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.kind == .pdfMixed)
        #expect(content.textOrigin == .mixed, "the scanned page is read by OCR, the other from its text (\(content.warningSummary))")
        #expect(content.pagesOCRed == [2])
        #expect(content.text.contains("Relatório anual"))
        #expect(content.text.contains("Anexo digitalizado"))
    }

    @Test("Encrypted PDF yields an encrypted warning, not an error")
    func encrypted() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeTextPDF("secret.pdf", pages: [["Confidential"]], password: "s3cret")
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.hasWarning(.encrypted))
        #expect(content.textOrigin == .metadataOnly)
        #expect(content.text.isEmpty)
        #expect(content.entities.documentDate?.source == .fileCreated)
    }

    @Test("Corrupt PDF yields a corrupted warning, not an error")
    func corrupt() async throws {
        let scratch = try Scratch()
        let url = try scratch.write("broken.pdf", "%PDF-1.7\nthis is not a real pdf body\n%%EOF")
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.hasWarning(.corrupted))
        #expect(content.textOrigin == .metadataOnly)
    }

    @Test("Per-file timeout is a hard ExtractionError.timeout")
    func timeout() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImagePDF("slow.pdf", pages: [["Página lenta"]])
        let context = try TestConfig.context { extraction, _ in extraction.perFileTimeout = 0.001 }
        await #expect {
            _ = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
        } throws: { error in
            guard case .timeout? = error as? ExtractionError else { return false }
            return true
        }
    }

    @Test("Scanned-page rules follow the configuration")
    func pageRules() throws {
        let config = try TestConfig.pipeline().extraction.pdf
        #expect(PageTextQuality("abc").imagePageReason(config) { 0 } == .fewCharacters)
        #expect(PageTextQuality(String(repeating: "12 34 56 78 ", count: 10)).imagePageReason(config) { 0 } == .lowLetterShare)
        let garbled = String(repeating: "Texto normal ", count: 8) + String(repeating: "\u{FFFD}", count: 10)
        #expect(PageTextQuality(garbled).imagePageReason(config) { 0 } == .replacementCharacters)
        let short = String(repeating: "Digitalizado ", count: 6)
        #expect(PageTextQuality(short).imagePageReason(config) { 1 } == .fullPageImage)
        #expect(PageTextQuality(short).imagePageReason(config) { 0.2 } == nil)
    }
}

/// Concatenates PDFs with PDFKit (used to build a mixed text/scan document).
enum PDFMerge {
    static func merge(_ urls: [URL], into output: URL) -> URL? {
        let merged = PDFDocument()
        for url in urls {
            guard let document = PDFDocument(url: url) else { return nil }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { return nil }
                merged.insert(page, at: merged.pageCount)
            }
        }
        return merged.write(to: output) ? output : nil
    }
}
