import ArrumatorCore
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// PDFs: per-page text layer, its columns kept apart (`PDFPageText`), scanned-page detection, OCR of image pages (first `ocrHeadPages` and the last page,
/// or all when the document has at most `ocrAllIfAtMost` pages), info-dictionary metadata. An image page's text is what
/// OCR read of it, unless OCR did not read it, failed or read nothing: then its text layer is kept. The pages left out,
/// of the text layer or of OCR, are named in a warning. Encrypted documents are opened with an empty password when
/// possible, otherwise returned metadata-only with an `encrypted` warning.
struct PDFExtractor: FileExtractor {
    let ocr: OCRService

    let name = "pdf"
    let version = 4
    var supportedTypes: [UTType] { [.pdf] }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        guard let document = PDFDocument(url: job.url) else {
            return .metadataOnly(kind: .unknown, warnings: [ExtractionWarning(.corrupted, "PDFKit cannot open the file")])
        }
        var metadata = Self.metadata(of: document)
        if document.isLocked, !document.unlock(withPassword: "") {
            return .metadataOnly(kind: .unknown, warnings: [ExtractionWarning(.encrypted, "password required")],
                                 metadata: metadata)
        }
        metadata = metadata.merging(Self.metadata(of: document)) { _, unlocked in unlocked }
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            return .metadataOnly(kind: .unknown, warnings: [ExtractionWarning(.corrupted, "no pages")], metadata: metadata)
        }

        let pdf = job.config.pdf
        let scans = try scanTextLayer(document, config: pdf)
        let ocrCandidates = Set(pdf.ocrPages(of: pageCount))
        let imagePages = scans.filter { $0.reason != nil }.map(\.index)
        let languages = LanguageDetector(config: job.config)
        var hint = scans.filter { $0.reason == nil }.map(\.text).joined(separator: "\n")
        if hint.isEmpty { hint = job.source.stem }

        var pass = OCRPass(service: ocr, config: job.config, time: job.time)
        var recognised: [Int: OCRPageResult] = [:]
        var renderedDPI: [Int: Double] = [:]
        for index in imagePages where ocrCandidates.contains(index) {
            try Task.checkCancellation()
            // What PDFKit and Core Graphics autorelease while a page is drawn goes with the page.
            guard let page = document.page(at: index),
                  let rendered = autoreleasepool(invoking: { PDFPageRenderer.render(page, config: job.config) })
            else { continue }
            renderedDPI[index + 1] = rendered.dpi
            let result = try await pass.recognize(rendered.image, page: index + 1, languages: languages.ranked(for: hint),
                                                  timeout: pdf.ocrPageTimeout,
                                                  orientationRetryBelow: pdf.orientationRetryBelowConfidence)
            guard let result else { continue }
            recognised[index] = result
            if !result.text.isEmpty { hint = result.text }
        }

        let pages = Self.pageTexts(scans, recognised: recognised)
        var draft = ExtractionDraft(kind: Self.kind(textPages: scans.count { $0.reason == nil }, imagePages: imagePages.count),
                                   textOrigin: Self.origin(layerPages: pages.layerPages, ocrPages: pages.ocrPages),
                                   text: pages.texts.joined(separator: "\n\n"))
        draft.firstPageLength = pages.firstPageLength
        draft.pageCount = pageCount
        draft.pagesOCRed = pass.recognisedPages
        draft.ocr = pass.stats
        draft.metadata = metadata
        draft.metadata["pdf:pagesRead"] = String(scans.count)
        draft.metadata["pdf:imagePages"] = imagePages.map { String($0 + 1) }.joined(separator: ",")
        draft.metadataDates = Self.metadataDates(of: document, calendar: job.calendar)
        draft.warnings = Self.pagesLeftOut(scans, pageCount: pageCount, ocrCandidates: ocrCandidates) + pass.allWarnings
        let snippetTables = pages.tables.prefix(job.config.maxTables).map { String($0.prefix(job.config.tableSnippetChars)) }
        draft.structure = ContentStructure(paragraphCount: TextNormalizer.nonEmptyLineCount(draft.text),
                                           tables: Array(snippetTables))
        if !pass.pages.isEmpty { draft.timings["ocr"] = pass.elapsedMs }

        struct OCRInput: Encodable, Sendable {
            var pageCount: Int
            var imagePages: [ImagePageTrace]
            var ocrCandidates: [Int]
            // Where each image page's text came from, with what its text layer and OCR read of it.
            var imagePageTexts: [ImagePageText]
            var dpi: [Int: Double]
        }
        await pass.record(on: job.trace, input: OCRInput(
            pageCount: pageCount,
            imagePages: scans.compactMap { scan in scan.reason.map { ImagePageTrace(page: scan.index + 1, reason: $0, quality: scan.quality) } },
            ocrCandidates: ocrCandidates.sorted().map { $0 + 1 }, imagePageTexts: pages.imagePages, dpi: renderedDPI))
        return draft
    }

    // MARK: Text of each page

    /// Where an image page's text came from: OCR, its text layer, or neither, when neither holds any.
    enum ImagePageSource: String, Encodable, Sendable {
        case ocr, textLayer, none
    }

    /// What an image page's text layer held and OCR read of it, in readable characters (`PageTextQuality.readable`;
    /// nil when OCR did not read it or failed), and which of them its text is.
    struct ImagePageText: Encodable, Sendable {
        var page: Int
        var textLayerChars: Int
        var ocrChars: Int?
        var source: ImagePageSource
    }

    /// The text each page read gives, in page order, and where it came from.
    private struct PageTexts {
        var texts: [String] = []
        var firstPageLength: Int?
        var tables: [String] = []
        /// Pages whose text is their text layer's, and pages whose text is OCR's, among those with any.
        var layerPages = 0
        var ocrPages = 0
        var imagePages: [ImagePageText] = []
    }

    /// A text page's text is its text layer. An image page's is what OCR read of it whenever OCR read anything
    /// readable, as a text layer judged an image page's can be glyphs mapped to the wrong characters, as many as OCR
    /// reads or more; its text layer only where OCR did not read it, failed or read nothing, such as a statement's page
    /// of figures past the pages OCR reads.
    private static func pageTexts(_ scans: [PageScan], recognised: [Int: OCRPageResult]) -> PageTexts {
        var pages = PageTexts()
        for scan in scans {
            let read = recognised[scan.index].map { (result: $0, readable: PageTextQuality($0.text).readable) }
            let source: ImagePageSource = if scan.reason != nil, let read, read.readable > 0 {
                .ocr
            } else {
                scan.quality.readable > 0 ? .textLayer : .none
            }
            let text = source == .ocr ? read?.result.text ?? "" : scan.text
            switch source {
            case .ocr:
                pages.tables += read?.result.tables ?? []
                pages.ocrPages += 1
            case .textLayer: pages.layerPages += 1
            case .none: break
            }
            if scan.reason != nil {
                pages.imagePages.append(ImagePageText(page: scan.index + 1, textLayerChars: scan.quality.readable,
                                                      ocrChars: read?.readable, source: source))
            }
            if scan.index == 0 { pages.firstPageLength = (text as NSString).length }
            if !text.isEmpty { pages.texts.append(text) }
        }
        return pages
    }

    /// The pages whose text layer is not read (past `textLayerHeadPages` and before the last `textLayerTailPages`), and
    /// the image pages OCR does not read (past `ocrHeadPages`), each named, with those of them whose text layer, which
    /// they keep, holds any text.
    private static func pagesLeftOut(_ scans: [PageScan], pageCount: Int, ocrCandidates: Set<Int>) -> [ExtractionWarning] {
        var warnings: [ExtractionWarning] = []
        let scanned = Set(scans.map(\.index))
        let unread = (0..<pageCount).filter { !scanned.contains($0) }
        if !unread.isEmpty {
            warnings.append(ExtractionWarning(.textTruncated,
                                              "pages \(pageList(unread)) not read: the text of \(scans.count) of \(pageCount) pages is read"))
        }
        let notOCRed = scans.filter { $0.reason != nil && !ocrCandidates.contains($0.index) }
        if !notOCRed.isEmpty {
            let kept = notOCRed.filter { $0.quality.readable > 0 }.map(\.index)
            let layers = switch kept.count {
            case 0: ""
            case notOCRed.count: ": their text layer is kept"
            default: ": the text layer of pages \(pageList(kept)) is kept"
            }
            warnings.append(ExtractionWarning(.textTruncated, "scanned pages \(pageList(notOCRed.map(\.index))) not read by OCR" + layers))
        }
        return warnings
    }

    /// 0-based page indexes as 1-based pages, a run written as a range: `2–4, 7`.
    private static func pageList(_ indexes: [Int]) -> String {
        var runs: [ClosedRange<Int>] = []
        for page in indexes.map({ $0 + 1 }).sorted() {
            if let last = runs.last, last.upperBound + 1 == page {
                runs[runs.count - 1] = last.lowerBound...page
            } else {
                runs.append(page...page)
            }
        }
        return runs.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }.joined(separator: ", ")
    }

    // MARK: Text layer

    private struct PageScan {
        var index: Int
        var text: String
        var quality: PageTextQuality
        var reason: ImagePageReason?
    }

    private struct ImagePageTrace: Encodable, Sendable {
        var page: Int
        var reason: ImagePageReason
        var quality: PageTextQuality
    }

    /// Reads the text layer of the first `textLayerHeadPages` and last `textLayerTailPages` pages and classifies
    /// each as text or image page.
    private func scanTextLayer(_ document: PDFDocument, config: ExtractionConfig.PDF) throws -> [PageScan] {
        let count = document.pageCount
        let head = 0..<min(count, config.textLayerHeadPages)
        let tail = max(head.upperBound, count - config.textLayerTailPages)..<count
        var scans: [PageScan] = []
        for index in Array(head) + Array(tail) {
            try Task.checkCancellation()
            // What PDFKit autoreleases while a page's text is read goes with the page, however many pages are read.
            let scan = autoreleasepool { () -> PageScan? in
                guard let page = document.page(at: index) else { return nil }
                let text = PDFPageText.columned(page, gap: config.columnGap)
                let quality = PageTextQuality(text)
                let reason = quality.imagePageReason(config) {
                    page.pageRef.map(PDFImageCoverage.largestImageShare(of:)) ?? 0
                }
                return PageScan(index: index, text: text, quality: quality, reason: reason)
            }
            if let scan { scans.append(scan) }
        }
        return scans
    }

    private static func kind(textPages: Int, imagePages: Int) -> ContentKind {
        if imagePages == 0 { return .pdfText }
        return textPages == 0 ? .pdfScanned : .pdfMixed
    }

    private static func origin(layerPages: Int, ocrPages: Int) -> TextOrigin {
        switch (layerPages > 0, ocrPages > 0) {
        case (true, true): .mixed
        case (true, false): .textLayer
        case (false, true): .ocr
        case (false, false): .none
        }
    }

    // MARK: Metadata

    private static let attributeKeys: [(PDFDocumentAttribute, String)] = [
        (.titleAttribute, "title"), (.authorAttribute, "author"), (.subjectAttribute, "subject"),
        (.creatorAttribute, "creator"), (.producerAttribute, "producer"), (.keywordsAttribute, "keywords"),
        (.creationDateAttribute, "creationDate"), (.modificationDateAttribute, "modificationDate"),
    ]

    private static func metadata(of document: PDFDocument) -> [String: String] {
        guard let attributes = document.documentAttributes else { return [:] }
        var metadata: [String: String] = [:]
        for (key, name) in attributeKeys {
            switch attributes[key] {
            case let date as Date:
                metadata["pdf:\(name)"] = date.formatted(.iso8601)
            case let list as [String] where !list.isEmpty:
                metadata["pdf:\(name)"] = list.joined(separator: ", ")
            case let value as String where !value.trimmingCharacters(in: .whitespaces).isEmpty:
                metadata["pdf:\(name)"] = value
            default:
                continue
            }
        }
        return metadata
    }

    /// The document's creation date, as the day it writes. A PDF date's fields are the local time of whoever wrote it,
    /// with its offset from UT or without, which leaves that unknown (`D:YYYYMMDDHHmmSSOHH'mm'`, PDF Reference 1.7
    /// §3.8.3, ISO 32000-1 §7.9.4); PDFKit reads one without an offset as UT. So the day is read from the date as written,
    /// and from PDFKit's moment, in the Mac's time zone, only where the string cannot be read.
    private static func metadataDates(of document: PDFDocument, calendar: GregorianCalendar) -> [MetadataDate] {
        guard let created = document.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date else {
            return []
        }
        let day = document.documentRef.flatMap { writtenDay(of: $0, key: "CreationDate") } ?? calendar.day(of: created)
        return [MetadataDate(day: day, source: .pdfMeta, label: "PDF CreationDate")]
    }

    /// The day the date at `key` of the document information dictionary writes, if it is one.
    private static func writtenDay(of document: CGPDFDocument, key: String) -> CalendarDay? {
        var string: CGPDFStringRef?
        guard let info = document.info, CGPDFDictionaryGetString(info, key, &string), let string,
              let text = CGPDFStringCopyTextString(string) as String?,
              let match = pdfDate.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        let field = { (index: Int, absent: Int) -> Int? in
            let range = match.range(at: index)
            return range.location == NSNotFound ? absent : Int((text as NSString).substring(with: range))
        }
        // A month or day left out is the first (ISO 32000-1 §7.9.4).
        guard let year = field(1, 0), let month = field(2, 1), let day = field(3, 1) else { return nil }
        return CalendarDay(year: year, month: month, day: day)
    }

    /// The year, month and day of a PDF date (`D:YYYYMMDD…`), the month and day optional.
    private static let pdfDate: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^\s*(?:D:)?([0-9]{4})(?:([0-9]{2})([0-9]{2})?)?"#)
        } catch {
            preconditionFailure("Invalid PDF date pattern: \(error)")
        }
    }()
}
