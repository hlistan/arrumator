import ArrumatorCore
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// PDFs: per-page text layer, scanned-page detection, OCR of image pages (first `ocrHeadPages` and the last page,
/// or all when the document has at most `ocrAllIfAtMost` pages), info-dictionary metadata. Encrypted documents
/// are opened with an empty password when possible, otherwise returned metadata-only with an `encrypted` warning.
struct PDFExtractor: FileExtractor {
    let ocr: OCRService

    let name = "pdf"
    let version = 1
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
        var ocrText: [Int: String] = [:]
        var renderedDPI: [Int: Double] = [:]
        var tables: [String] = []
        for index in imagePages where ocrCandidates.contains(index) {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let rendered = PDFPageRenderer.render(page, config: job.config)
            else { continue }
            renderedDPI[index + 1] = rendered.dpi
            let result = try await pass.recognize(rendered.image, page: index + 1, languages: languages.ranked(for: hint),
                                                  timeout: pdf.ocrPageTimeout,
                                                  orientationRetryBelow: pdf.orientationRetryBelowConfidence)
            guard let result else { continue }
            ocrText[index] = result.text
            tables += result.tables
            if !result.text.isEmpty { hint = result.text }
        }

        var pieces: [String] = []
        var firstPageLength: Int?
        for scan in scans {
            let text = scan.reason == nil ? scan.text : (ocrText[scan.index] ?? "")
            if scan.index == 0 { firstPageLength = (text as NSString).length }
            if !text.isEmpty { pieces.append(text) }
        }
        let textPages = scans.count { $0.reason == nil }
        let ocrPages = ocrText.values.count { !$0.isEmpty }
        var draft = ExtractionDraft(kind: Self.kind(textPages: textPages, imagePages: imagePages.count),
                                   textOrigin: Self.origin(textPages: textPages, ocrPages: ocrPages),
                                   text: pieces.joined(separator: "\n\n"))
        draft.firstPageLength = firstPageLength
        draft.pageCount = pageCount
        draft.pagesOCRed = pass.recognisedPages
        draft.ocr = pass.stats
        draft.metadata = metadata
        draft.metadata["pdf:pagesRead"] = String(scans.count)
        draft.metadata["pdf:imagePages"] = imagePages.map { String($0 + 1) }.joined(separator: ",")
        draft.metadataDates = Self.metadataDates(of: document)
        draft.warnings = pass.allWarnings
        let snippetTables = tables.prefix(job.config.maxTables).map { String($0.prefix(job.config.tableSnippetChars)) }
        draft.structure = ContentStructure(paragraphCount: TextNormalizer.nonEmptyLineCount(draft.text),
                                           tables: Array(snippetTables))
        if !pass.pages.isEmpty { draft.timings["ocr"] = pass.elapsedMs }

        struct OCRInput: Encodable, Sendable {
            var pageCount: Int
            var imagePages: [ImagePageTrace]
            var ocrCandidates: [Int]
            var dpi: [Int: Double]
        }
        await pass.record(on: job.trace, input: OCRInput(
            pageCount: pageCount,
            imagePages: scans.compactMap { scan in scan.reason.map { ImagePageTrace(page: scan.index + 1, reason: $0, quality: scan.quality) } },
            ocrCandidates: ocrCandidates.sorted().map { $0 + 1 }, dpi: renderedDPI))
        return draft
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
            guard let page = document.page(at: index) else { continue }
            let text = page.string ?? ""
            let quality = PageTextQuality(text)
            let reason = quality.imagePageReason(config) {
                page.pageRef.map(PDFImageCoverage.largestImageShare(of:)) ?? 0
            }
            scans.append(PageScan(index: index, text: text, quality: quality, reason: reason))
        }
        return scans
    }

    private static func kind(textPages: Int, imagePages: Int) -> ContentKind {
        if imagePages == 0 { return .pdfText }
        return textPages == 0 ? .pdfScanned : .pdfMixed
    }

    private static func origin(textPages: Int, ocrPages: Int) -> TextOrigin {
        switch (textPages > 0, ocrPages > 0) {
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

    private static func metadataDates(of document: PDFDocument) -> [MetadataDate] {
        guard let created = document.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date else {
            return []
        }
        return [MetadataDate(day: CalendarDay(date: created, calendar: .current), source: .pdfMeta,
                             label: "PDF CreationDate")]
    }
}
