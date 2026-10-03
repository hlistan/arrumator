import ArrumatorCore
import Foundation
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers

/// Photos, scans and screenshots: EXIF `DateTimeOriginal`, OCR on an orientation-corrected, downscaled image,
/// and — when the OCR text is sparse and a vision model is configured — a schema-constrained description from the
/// local vision model. A TIFF's pages are each read, as many as a scanned PDF's (`pdf.ocrAllIfAtMost`, else the first
/// `pdf.ocrHeadPages` and the last). An image that declares more than `image.maxPixels` pixels is not decoded.
struct ImageExtractor: FileExtractor {
    let ocr: OCRService
    let vision: VisionDescriber?

    let name = "image"
    let version = 3
    var supportedTypes: [UTType] { [.jpeg, .png, .heic, .heif, .tiff, .webP, .gif, .bmp] }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let config = job.config.image
        let unreadable = ExtractionDraft.metadataOnly(kind: .image, warnings: [
            ExtractionWarning(.corrupted, "ImageIO cannot decode the image"),
        ])
        guard let source = CGImageSourceCreateWithURL(job.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let size = ImageTools.pixelSize(of: source, at: 0) else { return unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var metadata = Self.metadata(properties)
        let captured = Self.captureDay(properties)
        if let captured { metadata["exif:DateTimeOriginal"] = captured.iso }
        let metadataDates = captured.map { [MetadataDate(day: $0, source: .exif, label: "EXIF DateTimeOriginal")] } ?? []
        // What an image declares is checked before it is decoded, for the OCR image and the vision model's alike:
        // decoding takes time in proportion to the pixels, and a small file can declare billions of them.
        guard Self.fits(size, maxPixels: config.maxPixels) else {
            var draft = ExtractionDraft.metadataOnly(kind: .image, warnings: [Self.tooLarge(size, config: config)],
                                                     metadata: metadata)
            draft.metadataDates = metadataDates
            return draft
        }
        // A TIFF holds a document's pages, read as a scanned PDF's are; the further frames of other formats are an
        // animation or other renditions of one picture, so their first is the image.
        let frameCount = CGImageSourceGetCount(source)
        let isPaged = job.type.conforms(to: .tiff)
        let pages = isPaged ? job.config.pdf.ocrPages(of: frameCount) : [0]
        var pass = OCRPass(service: ocr, config: job.config, time: job.time)
        let read = try await Self.read(pages, of: source, job: job, pass: &pass)
        guard let first = read.first else { return unreadable }
        var traced = ["width": first.image.width, "height": first.image.height]
        if isPaged, frameCount > 1 { traced["pages"] = frameCount }
        await pass.record(on: job.trace, input: traced)

        let text = read.texts.joined(separator: "\n\n")
        var draft = ExtractionDraft(kind: .image, textOrigin: text.isEmpty ? .none : .ocr, text: text)
        draft.pageCount = isPaged ? frameCount : 1
        // As a PDF's: where the first page's text ends, for the dates found early on it.
        if isPaged, frameCount > 1 { draft.firstPageLength = read.firstPageLength }
        draft.pagesOCRed = pass.recognisedPages
        draft.ocr = pass.stats
        draft.metadata = metadata
        draft.metadataDates = metadataDates
        draft.warnings = pass.allWarnings + read.warnings
        if isPaged, pages.count < frameCount {
            draft.warnings.append(ExtractionWarning(.textTruncated, "read \(pages.count) of \(frameCount) pages"))
        }
        draft.structure = ContentStructure(paragraphCount: read.paragraphs,
                                           tables: read.tables.prefix(job.config.maxTables)
                                               .map { String($0.prefix(job.config.tableSnippetChars)) })
        draft.timings["ocr"] = pass.elapsedMs
        guard Self.isSparse(text: text, confidence: pass.stats?.meanConfidence ?? 0, config: config) else { return draft }
        try await describe(page: first.index, of: source, into: &draft, job: job)
        return draft
    }

    /// What OCR read of an image's pages.
    private struct PagesRead {
        /// The first page decoded, which the vision model is shown.
        var first: (index: Int, image: CGImage)?
        /// The text of each page that had any, in order.
        var texts: [String] = []
        var firstPageLength: Int?
        var paragraphs = 0
        var tables: [String] = []
        var warnings: [ExtractionWarning] = []
    }

    /// Recognises each of `pages` (0-based; the first was checked against the pixel budget already) under the page
    /// OCR timeout. EXIF orientation is applied when a page is decoded, so there is no orientation retry. A page that
    /// cannot be decoded, or is over the budget, is left out with a warning.
    private static func read(_ pages: [Int], of source: CGImageSource, job: ExtractionJob,
                             pass: inout OCRPass) async throws -> PagesRead {
        let config = job.config.image
        let languages = LanguageDetector(config: job.config)
        var hint = job.source.stem
        var read = PagesRead()
        for index in pages {
            try Task.checkCancellation()
            if index > 0 {
                guard let size = ImageTools.pixelSize(of: source, at: index) else {
                    read.warnings.append(ExtractionWarning(.corrupted, "page \(index + 1): ImageIO cannot decode it"))
                    continue
                }
                guard fits(size, maxPixels: config.maxPixels) else {
                    read.warnings.append(tooLarge(size, config: config, page: index + 1))
                    continue
                }
            }
            guard let image = ImageTools.orientedImage(source, at: index, maxPixel: config.ocrMaxPixel) else {
                if index > 0 { read.warnings.append(ExtractionWarning(.corrupted, "page \(index + 1): ImageIO cannot decode it")) }
                continue
            }
            if read.first == nil { read.first = (index, image) }
            let result = try await pass.recognize(image, page: index + 1, languages: languages.ranked(for: hint),
                                                  timeout: job.config.pdf.ocrPageTimeout, orientationRetryBelow: nil)
            let text = result?.text ?? ""
            if index == 0 { read.firstPageLength = (text as NSString).length }
            if !text.isEmpty {
                read.texts.append(text)
                hint = text
            }
            read.paragraphs += result?.paragraphs.count ?? 0
            read.tables += result?.tables ?? []
        }
        return read
    }

    /// Asks the vision model, when one is configured, to describe the page at `index` of an image whose text is too
    /// sparse to identify it. A description the model fails to give is a warning; Ollama away is thrown, for the job to
    /// wait for, or noted as a warning where the context says so (`WhenOllamaIsAway`).
    private func describe(page index: Int, of source: CGImageSource, into draft: inout ExtractionDraft,
                          job: ExtractionJob) async throws {
        let config = job.config.image
        guard let options = job.context.vision else {
            draft.warnings.append(ExtractionWarning(.vlmSkipped, "sparse OCR text and no vision model configured"))
            return
        }
        guard let vision else {
            draft.warnings.append(ExtractionWarning(.vlmSkipped, "sparse OCR text and no Ollama client available"))
            return
        }
        try Task.checkCancellation()
        let vlmStarted = Date()
        guard let small = ImageTools.orientedImage(source, at: index, maxPixel: config.vlmMaxPixel),
              let jpeg = ImageTools.jpegData(small, quality: config.jpegQuality) else {
            draft.warnings.append(ExtractionWarning(.vlmFailed, "cannot encode the image for the vision model"))
            return
        }
        let outcome = try await vision.describe(jpeg: jpeg, ocrText: draft.text, options: options, timeout: config.vlmTimeout)
        draft.timings["vlm"] = outcome.durationMs
        await Self.recordVLM(outcome, startedAt: vlmStarted, pixels: (small.width, small.height), on: job.trace)
        if let away = outcome.waitsFor {
            guard job.context.whenOllamaIsAway == .note else { throw away }
            draft.warnings.append(ExtractionWarning(.vlmFailed, "Ollama is away: \(away.localizedDescription)"))
            return
        }
        if let summary = outcome.summary {
            draft.visual = summary
            if draft.text.isEmpty { draft.textOrigin = .vlmOnly }
        } else {
            draft.warnings.append(ExtractionWarning(.vlmFailed, outcome.error ?? "no usable answer"))
        }
    }

    /// Why an image, or one of its pages, is not decoded.
    private static func tooLarge(_ size: (width: Int, height: Int), config: ExtractionConfig.Image,
                                 page: Int? = nil) -> ExtractionWarning {
        let pixels = "\(size.width) × \(size.height) pixels, more than \(config.maxPixels)"
        return ExtractionWarning(.tooLarge, page.map { "page \($0): \(pixels)" } ?? pixels)
    }

    /// Whether an image of `size` is within `maxPixels`; a product that overflows is not.
    static func fits(_ size: (width: Int, height: Int), maxPixels: Int) -> Bool {
        let (pixels, overflowed) = size.width.multipliedReportingOverflow(by: size.height)
        return size.width > 0 && size.height > 0 && !overflowed && pixels <= maxPixels
    }

    /// Too little text for OCR alone to identify the image (thresholds from `ExtractionConfig.Image`).
    static func isSparse(text: String, confidence: Double, config: ExtractionConfig.Image) -> Bool {
        let characters = text.count { !$0.isWhitespace }
        return characters < config.sparseChars || words(in: text) < config.sparseWords || confidence < config.lowConfidence
    }

    /// The words of `text` as NaturalLanguage tells them apart in every script, those written without spaces between
    /// words (Chinese, Japanese, Thai) among them, in which splitting at spaces finds a whole line one word.
    private static func words(in text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    // MARK: Trace

    private static func recordVLM(_ outcome: VisionOutcome, startedAt: Date, pixels: (Int, Int),
                                  on trace: TraceContext) async {
        struct Input: Encodable {
            var model: String
            // What the model was told about thinking; absent when nothing was sent.
            var think: OllamaThink?
            var imageBytes: Int
            var width: Int
            var height: Int
            var schema: JSONValue
        }
        // The raw answer is kept under `TraceStep.exchangeKey`, which retention clears.
        struct Output: Encodable {
            var exchange: String?
            var visual: VisualSummary?
            var metrics: OllamaMetrics?
        }
        await trace.record(.vlm, status: outcome.summary == nil ? .error : .ok, startedAt: startedAt,
                           input: Input(model: outcome.model, think: outcome.think,
                                        imageBytes: outcome.imageBytes, width: pixels.0, height: pixels.1,
                                        schema: VisionDescriber.schema),
                           output: Output(exchange: outcome.rawResponse, visual: outcome.summary, metrics: outcome.metrics),
                           error: outcome.error)
    }

    // MARK: Metadata

    private static func captureDay(_ properties: [CFString: Any]) -> CalendarDay? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        guard let raw = exif?[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        // EXIF format: "yyyy:MM:dd HH:mm:ss" in the camera's local time.
        let parts = raw.split(whereSeparator: { $0 == ":" || $0 == " " }).prefix(3).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return CalendarDay(year: parts[0], month: parts[1], day: parts[2])
    }

    private static func metadata(_ properties: [CFString: Any]) -> [String: String] {
        var metadata: [String: String] = [:]
        if let width = properties[kCGImagePropertyPixelWidth] as? Int { metadata["image:width"] = String(width) }
        if let height = properties[kCGImagePropertyPixelHeight] as? Int { metadata["image:height"] = String(height) }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if let make = tiff?[kCGImagePropertyTIFFMake] as? String { metadata["image:make"] = make }
        if let model = tiff?[kCGImagePropertyTIFFModel] as? String { metadata["image:model"] = model }
        if let software = tiff?[kCGImagePropertyTIFFSoftware] as? String { metadata["image:software"] = software }
        return metadata
    }
}
