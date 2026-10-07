import ArrumatorCore
@testable import ArrumatorExtract
import ArrumatorTesting
import CoreGraphics
import Foundation
import PDFKit
import Testing

@Suite("PDF extraction")
struct PDFExtractionTests {
    private let registry: ExtractorRegistry

    init() throws { registry = try TestConfig.registry() }

    @Test("Text PDF: text layer, metadata, entities and label date")
    func textPDF() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.writeTextPDF("invoice.pdf", pages: [
            ["EDP Comercial", "Fatura FT 2026/0042", "Data de emissão: 20/05/2026", "Data de vencimento: 10/06/2026",
             "NIF: 503 504 564", "IBAN PT50 0002 0123 1234 5678 9015 4", "Total a pagar: 45,90 €"],
            ["Condições gerais do contrato de fornecimento de energia elétrica."],
        ], info: [kCGPDFContextTitle: "Fatura EDP", kCGPDFContextAuthor: "EDP"])
        let sink = MemoryTraceSink()
        let content = try await registry.extract(url, sha256: "abc", context: try TestConfig.context(),
                                                 trace: TraceContext(traceID: 1, sink: sink))
        #expect(content.kind == .pdfText, "a PDF whose pages all have text is a text PDF")
        #expect(content.textOrigin == .textLayer, "text comes from the text layer, with no OCR")
        #expect(content.pageCount == 2, "every page is counted, not only the ones read")
        #expect(content.pagesOCRed == [], "a page with a text layer is never OCRed")
        #expect(content.text.contains("Fatura FT 2026/0042"), "the invoice number reaches the model as written")
        #expect(content.metadata["pdf:title"] == "Fatura EDP", "the PDF's own title is kept as metadata")
        #expect(content.metadata["pdf:author"] == "EDP", "the PDF's author is kept as metadata")
        #expect(content.language.primary == "pt", "a Portuguese invoice is detected as Portuguese")
        #expect(content.entities.documentDate?.date == "2026-05-20", "the issue date, not the due date, dates the document")
        #expect(content.entities.documentDate?.source == .label, "the date comes from its label, Data de emissão")
        #expect(content.entities.stableKeys.contains(StableKey(kind: .iban, value: "PT50000201231234567890154")),
                "the IBAN in the text layer is a stable key")
        #expect(content.entities.stableKeys.contains(StableKey(kind: .ptNIF, value: "503504564")), "the supplier's NIF is a stable key")
        #expect(content.source.sha256 == "abc", "the content is tied to the file's hash it was read from")
        #expect(content.extractorName == "pdf", "the trace names the PDF extractor")
        let stages = await sink.steps.map(\.stage)
        #expect(stages == [.extract, .entities], "a text PDF records no OCR step")
    }

    /// QA 2026-10-05, READ-6: an invoice's sender and its customer, printed side by side, were read as one line joined
    /// by a space, and a weak model gave "EDP Comercial Maria Exemplo" as a party.
    @Test("Text a page sets apart on one line, as two columns or a value beside its label, is kept apart by a tab")
    func columnsApart() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.writeTextPDF("fatura.pdf", pages: [[
            "EDP Comercial\tMaria Exemplo", "Avenida Exemplo 24\tRua Exemplo 12, 3.º Esq.", "Fatura n.º\tFT EDPC2026/926804564",
            "Pode pagar esta fatura no Multibanco, no MB WAY ou no seu homebanking até 25/08/2026.",
        ]])
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.text.contains("EDP Comercial\tMaria Exemplo\nAvenida Exemplo 24\tRua Exemplo 12, 3.º Esq."),
                "two address blocks side by side are two columns: \(content.text.debugDescription)")
        #expect(content.text.contains("Fatura n.º\tFT EDPC2026/926804564"), "a value is apart from its label")
        #expect(content.text.contains("Pode pagar esta fatura no Multibanco, no MB WAY ou no seu homebanking até 25/08/2026."),
                "the words of a sentence keep the spaces between them")
        #expect(content.extractorVersion == 4, "a reading of the text layer before columns were kept apart is told by its version")

        var config = try TestConfig.pipeline()
        config.extraction.pdf.columnGap = 0
        #expect(config.problems == ["extraction.pdf.columnGap must be more than 0"], "a gap of nothing would part every word")
    }

    @Test("Scanned Russian PDF is OCRed and key words are recovered", .enabled(VisionOCR.unavailable) { await VisionOCR.available.value })
    func scannedRussian() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.writeImagePDF("scan-ru.pdf", pages: [[
            "ПАО Сбербанк", "Счёт на оплату № 1234 от 15 мая 2024 г.", "ИНН 7707083893 КПП 773601001",
            "Итого к оплате: 12 500,00 руб.", "Срок оплаты: 30.05.2024",
        ]])
        let sink = MemoryTraceSink()
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(),
                                                 trace: TraceContext(traceID: 7, sink: sink))
        #expect(content.kind == .pdfScanned, "a PDF of page images is a scan")
        #expect(content.textOrigin == .ocr, "a scanned page is read by OCR (\(content.warningSummary))")
        #expect(content.pagesOCRed == [1], "the one scanned page is OCRed")
        #expect(content.text.contains("Сбербанк"), "Cyrillic text is read from the scan (\(content.warningSummary))")
        #expect(content.text.contains("оплату"), "the invoice wording is read from the scan")
        #expect(content.language.primary == "ru", "OCR text in Russian is detected as Russian")
        #expect(content.entities.stableKeys.contains(StableKey(kind: .ruINN, value: "7707083893")), "an ИНН read by OCR is a stable key")
        #expect(content.entities.documentDate?.date == "2024-05-15", "a Russian date written in words dates the document")
        let ocr = try #require(content.ocr)
        #expect(ocr.pages == [1], "the OCR statistics cover the page that was read")
        #expect(ocr.meanConfidence > 0.3, "clean printed text is read with some confidence")
        let steps = await sink.steps
        #expect(steps.map(\.stage) == [.ocr, .extract, .entities], "OCR is traced before extraction and entities")
        let ocrStep = try #require(steps.first)
        let ocrOutput = try #require(ocrStep.output)
        let ocrInput = try #require(ocrStep.input)
        #expect(ocrOutput.contains("\"page\":1"), "the OCR step shows each page it read")
        #expect(ocrInput.contains("fewCharacters"), "the OCR step says why the page counts as scanned")
    }

    @Test("Scanned Portuguese PDF is OCRed and key words are recovered", .enabled(VisionOCR.unavailable) { await VisionOCR.available.value })
    func scannedPortuguese() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.writeImagePDF("scan-pt.pdf", pages: [[
            "Autoridade Tributária e Aduaneira", "Data de emissão: 20 de maio de 2026", "NIF 999999990",
            "Total a pagar: 1.234,56 €", "Obrigado pela preferência",
        ]])
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.kind == .pdfScanned, "a PDF of page images is a scan")
        #expect(content.text.contains("Tributária"), "OCR reads the scanned page (\(content.warningSummary))")
        #expect(content.text.contains("preferência"), "accented Portuguese is read from the scan")
        #expect(content.language.primary == "pt", "OCR text in Portuguese is detected as Portuguese")
        #expect(content.entities.documentDate?.date == "2026-05-20", "a Portuguese date written in words dates the document")
        #expect(content.entities.stableKeys.contains(StableKey(kind: .ptNIF, value: "999999990")), "a NIF read by OCR is a stable key")
    }

    @Test("Mixed PDF: text page plus scanned page", .enabled(VisionOCR.unavailable) { await VisionOCR.available.value })
    func mixed() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let text = try scratch.writeTextPDF("text.pdf", pages: [[
            "Relatório anual de atividades da associação de moradores do bairro.",
            "Este documento resume as atividades realizadas durante o ano.",
        ]])
        let scan = try scratch.writeImagePDF("scan.pdf", pages: [["Anexo digitalizado", "Assinatura do presidente"]])
        let merged = try #require(PDFMerge.merge([text, scan], into: scratch.url("mixed.pdf")))
        let content = try await registry.extract(merged, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.kind == .pdfMixed, "a PDF with text and scanned pages is mixed")
        #expect(content.textOrigin == .mixed, "the scanned page is read by OCR, the other from its text (\(content.warningSummary))")
        #expect(content.pagesOCRed == [2], "only the scanned page is OCRed")
        #expect(content.text.contains("Relatório anual"), "the text page is read from its text layer")
        #expect(content.text.contains("Anexo digitalizado"), "the scanned page is read by OCR")
    }

    /// A statement's page: a few words and lines of figures, a text layer too few of whose characters are letters to be
    /// trusted as the page's text (`extraction.pdf.minLetterShare`).
    private static func figures(page: Int) -> [String] {
        ["Página \(page)"] + (1...12).map { "0\($0 % 9 + 1)/0\(page)/2026 \(page)\($0)4,50 1\($0)8,90 -2\($0)7,15" }
    }

    @Test("A page of figures keeps its text layer where OCR does not read it or reads less, and the pages left out are named")
    func textLayerKept() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.writeTextPDF("extrato.pdf", pages: (1...4).map(Self.figures(page:)))
        let context = try TestConfig.context { extraction, _ in
            extraction.pdf.ocrAllIfAtMost = 1
            extraction.pdf.ocrHeadPages = 1
        }
        let blind = RecordingRecognizer()
        let content = try await TestConfig.registry(recognizer: blind).extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(content.metadata["pdf:imagePages"] == "1,2,3,4", "every page of figures is taken for a scan")
        #expect(await blind.widths.count == 2, "OCR reads the first page and the last alone")
        for page in 1...4 {
            #expect(content.text.contains("Página \(page)\n"), "page \(page)'s text layer is kept: OCR did not read it or read nothing")
            #expect(content.text.contains("\(page)34,50"), "and its figures with it")
        }
        #expect(content.textOrigin == .textLayer, "all the text is the layer's")
        #expect(content.warnings.map(\.detail) == ["scanned pages 2–3 not read by OCR: their text layer is kept"],
                "the pages OCR did not read are named (\(content.warningSummary))")

        let page = "Extrato integral da conta à ordem, lido na imagem da página. "
            + String(repeating: "Movimento de 01/07/2026, transferência recebida de 1.234,50 euros. ", count: 8)
        let reader = RecordingRecognizer { _ in page }
        let read = try await TestConfig.registry(recognizer: reader).extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(read.text.components(separatedBy: "Extrato integral").count == 3, "where OCR reads anything, the first and last pages are its text")
        #expect(read.text.contains("Página 2\n") && read.text.contains("Página 3\n"), "the pages it did not read keep their layer")
        #expect(!read.text.contains("Página 1\n") && !read.text.contains("Página 4\n"), "and the pages it read are not given twice")
        #expect(read.textOrigin == .mixed, "the text is OCR's and the layer's")
    }

    /// A text layer whose glyphs name the wrong characters: one character for each glyph, so more than OCR reads of
    /// the page, and too few of them letters for it to be trusted (`extraction.pdf.minLetterShare`).
    private static let garbledLayer = Array(repeating: "1$ 7# 2% &9 4@ 0! 3* 5^ 8&", count: 6)

    @Test("A scanned page's text is what OCR read of it, however little; its text layer only where OCR read nothing",
          arguments: [("Fatura FT 2026/0042", "ocr"), ("7", "ocr"), ("", "textLayer"), (" \n ", "textLayer"), ("\u{FFFD}", "textLayer")])
    func ocrOverTheTextLayer(ocrRead: String, source: String) async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.writeTextPDF("fatura.pdf", pages: [Self.garbledLayer])
        let sink = MemoryTraceSink()
        let content = try await TestConfig.registry(recognizer: RecordingRecognizer { _ in ocrRead })
            .extract(url, sha256: "x", context: try TestConfig.context(), trace: TraceContext(traceID: 8, sink: sink))
        let layer = PageTextQuality(try #require(PDFDocument(url: url)?.page(at: 0)?.string)).readable
        if source == "ocr" {
            #expect(content.text == ocrRead, "OCR read \(ocrRead.count) characters of a page whose layer has \(layer), and its reading wins")
            #expect(content.textOrigin == .ocr, "so the page's text is OCR's")
        } else {
            #expect(content.text.hasPrefix("1$ 7# 2%"), "OCR read nothing readable, so the page keeps the text layer it has")
            #expect(content.textOrigin == .textLayer, "and the page's text is its layer's")
        }
        let input = try #require(await sink.steps.first { $0.stage == .ocr }?.input)
        let ocrChars = PageTextQuality(ocrRead).readable
        #expect(input.contains(#""imagePageTexts":[{"ocrChars":\#(ocrChars),"page":1,"source":"\#(source)","textLayerChars":\#(layer)}]"#),
                "the trace says what each held and which the page's text is: \(input)")
    }

    @Test("A scanned page OCR does not read, with no text layer, is named without saying a layer is kept")
    func scannedPagesWithoutLayerLeftOut() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.writeImagePDF("digitalizado.pdf", pages: (1...4).map { ["Página \($0)"] })
        let context = try TestConfig.context { extraction, _ in
            extraction.pdf.ocrAllIfAtMost = 1
            extraction.pdf.ocrHeadPages = 1
        }
        let sink = MemoryTraceSink()
        let content = try await TestConfig.registry(recognizer: RecordingRecognizer { _ in "Página digitalizada lida por OCR" })
            .extract(url, sha256: "x", context: context, trace: TraceContext(traceID: 9, sink: sink))
        #expect(content.warnings.map(\.detail) == ["scanned pages 2–3 not read by OCR"],
                "pages with no text of their own are named, and no layer is said to be kept (\(content.warningSummary))")
        let input = try #require(await sink.steps.first { $0.stage == .ocr }?.input)
        #expect(input.contains(#""page":2"#) && input.contains(#""source":"none""#), "and the trace says page 2 has no text: \(input)")
        #expect(!input.contains(#""source":"textLayer""#), "no page is said to keep a text layer it does not have: \(input)")
    }

    @Test("The pages whose text layer is not read are named")
    func textLayerPagesLeftOut() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let pages = (1...5).map { ["Relatório de atividades, capítulo \($0), sobre o trabalho feito durante o ano inteiro."] }
        let url = try scratch.writeTextPDF("relatorio.pdf", pages: pages)
        let context = try TestConfig.context { extraction, _ in
            extraction.pdf.textLayerHeadPages = 1
            extraction.pdf.textLayerTailPages = 1
        }
        let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(content.text.contains("capítulo 1,") && content.text.contains("capítulo 5,"), "the first page and the last are read")
        #expect(!content.text.contains("capítulo 3,"), "the pages between are not")
        #expect(content.warnings.map(\.detail) == ["pages 2–4 not read: the text of 2 of 5 pages is read"],
                "and they are named, so the model knows it saw part of the document (\(content.warningSummary))")
    }

    @Test("A page whose crop box no count of pixels can hold is not drawn for OCR, and stops nothing")
    func boundlessPage() throws {
        let config = try TestConfig.pipeline().extraction
        for size in [CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 100, height: CGFloat.infinity)] {
            let page = PDFPage()
            page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
            page.setBounds(CGRect(origin: .zero, size: size), for: .cropBox)
            #expect(PDFPageRenderer.render(page, config: config)?.dpi == nil, "a page \(size) is left unread, not converted to pixels that trap")
        }
    }

    @Test("Encrypted PDF yields an encrypted warning, not an error")
    func encrypted() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.writeTextPDF("secret.pdf", pages: [["Confidential"]], password: "s3cret")
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.warnings.map(\.code) == [.encrypted], "a password-protected PDF is filed with a warning, not failed")
        #expect(content.textOrigin == .metadataOnly, "a locked PDF is described by its metadata alone")
        #expect(content.text == "", "nothing is read past the password")
        #expect(content.entities.documentDate?.source == .fileCreated, "without text, the file's creation date dates it")
    }

    @Test("Corrupt PDF yields a corrupted warning, not an error")
    func corrupt() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.write("broken.pdf", "%PDF-1.7\nthis is not a real pdf body\n%%EOF")
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.warnings.map(\.code) == [.corrupted], "a broken PDF is filed with a warning, not failed")
        #expect(content.textOrigin == .metadataOnly, "a PDF PDFKit cannot open is described by its metadata alone")
    }

    @Test("Per-file timeout is a hard ExtractionError.timeout", .timeLimit(.minutes(1)))
    func timeout() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.writeImagePDF("slow.pdf", pages: [["Página lenta"]])
        // OCR that never ends, on time that runs out at once: the deadline, not the machine's speed, decides. A page's
        // own OCR deadline is left unbounded, so only the file's can end the reading.
        let expiring = try TestConfig.registry(recognizer: EndlessRecognizer(), time: TestTime(.advances))
        let context = try TestConfig.context { extraction, _ in extraction.pdf.ocrPageTimeout = 0 }
        await #expect("a file that outlasts its deadline is a hard timeout, not a partial result") {
            _ = try await expiring.extract(url, sha256: "x", context: context, trace: .disabled)
        } throws: { error in
            guard case .timeout? = error as? ExtractionError else { return false }
            return true
        }
    }

    @Test("Scanned-page rules follow the configuration")
    func pageRules() throws {
        let config = try TestConfig.pipeline().extraction.pdf
        #expect(PageTextQuality("abc").imagePageReason(config) { 0 } == .fewCharacters, "a page with almost no text is scanned")
        #expect(PageTextQuality(String(repeating: "12 34 56 78 ", count: 10)).imagePageReason(config) { 0 } == .lowLetterShare,
                "a text layer of mostly digits is not trusted as the page's text")
        let garbled = String(repeating: "Texto normal ", count: 8) + String(repeating: "\u{FFFD}", count: 10)
        #expect(PageTextQuality(garbled).imagePageReason(config) { 0 } == .replacementCharacters, "a text layer of broken glyphs is scanned")
        let short = String(repeating: "Digitalizado ", count: 6)
        #expect(PageTextQuality(short).imagePageReason(config) { 1 } == .fullPageImage,
                "a full-page image with a little text on it is a scan")
        #expect(PageTextQuality(short).imagePageReason(config) { 0.2 } == nil, "short text beside a small image is a text page")
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
