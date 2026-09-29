import ArrumatorCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Photos, scans and screenshots: EXIF `DateTimeOriginal`, OCR on an orientation-corrected, downscaled image,
/// and — when the OCR text is sparse and a vision model is configured — a schema-constrained description from the
/// local vision model.
struct ImageExtractor: FileExtractor {
    let ocr: OCRService
    let vision: VisionDescriber?

    let name = "image"
    let version = 1
    var supportedTypes: [UTType] { [.jpeg, .png, .heic, .heif, .tiff, .webP, .gif, .bmp] }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let config = job.config.image
        guard let source = CGImageSourceCreateWithURL(job.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = ImageTools.orientedImage(source, maxPixel: config.ocrMaxPixel) else {
            return .metadataOnly(kind: .image, warnings: [ExtractionWarning(.corrupted, "ImageIO cannot decode the image")])
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var metadata = Self.metadata(properties)
        let captured = Self.captureDay(properties)
        if let captured { metadata["exif:DateTimeOriginal"] = captured.iso }

        // An image is recognised like one page, under the page OCR timeout; EXIF orientation is already applied,
        // so no orientation retry.
        var pass = OCRPass(service: ocr, config: job.config)
        let languages = LanguageDetector(config: job.config).ranked(for: job.source.stem)
        let result = try await pass.recognize(image, page: 1, languages: languages, timeout: job.config.pdf.ocrPageTimeout,
                                              orientationRetryBelow: nil)
        await pass.record(on: job.trace, input: ["width": image.width, "height": image.height])
        let text = result?.text ?? ""

        var draft = ExtractionDraft(kind: .image, textOrigin: text.isEmpty ? .none : .ocr, text: text)
        draft.pageCount = 1
        draft.pagesOCRed = pass.recognisedPages
        draft.ocr = pass.stats
        draft.metadata = metadata
        draft.metadataDates = captured.map { [MetadataDate(day: $0, source: .exif, label: "EXIF DateTimeOriginal")] } ?? []
        draft.warnings = pass.allWarnings
        draft.structure = ContentStructure(paragraphCount: result?.paragraphs.count ?? 0,
                                           tables: (result?.tables ?? []).prefix(job.config.maxTables)
                                               .map { String($0.prefix(job.config.tableSnippetChars)) })
        draft.timings["ocr"] = pass.elapsedMs

        guard Self.isSparse(text: text, confidence: pass.stats?.meanConfidence ?? 0, config: config) else { return draft }
        guard let options = job.context.vision else {
            draft.warnings.append(ExtractionWarning(.vlmSkipped, "sparse OCR text and no vision model configured"))
            return draft
        }
        guard let vision else {
            draft.warnings.append(ExtractionWarning(.vlmSkipped, "sparse OCR text and no Ollama client available"))
            return draft
        }
        try Task.checkCancellation()
        let vlmStarted = Date()
        guard let small = ImageTools.orientedImage(source, maxPixel: config.vlmMaxPixel),
              let jpeg = ImageTools.jpegData(small, quality: config.jpegQuality) else {
            draft.warnings.append(ExtractionWarning(.vlmFailed, "cannot encode the image for the vision model"))
            return draft
        }
        let outcome = await vision.describe(jpeg: jpeg, ocrText: text, options: options, timeout: config.vlmTimeout)
        draft.timings["vlm"] = outcome.durationMs
        await Self.recordVLM(outcome, startedAt: vlmStarted, pixels: (small.width, small.height), on: job.trace)
        if let summary = outcome.summary {
            draft.visual = summary
            if text.isEmpty { draft.textOrigin = .vlmOnly }
        } else {
            draft.warnings.append(ExtractionWarning(.vlmFailed, outcome.error ?? "no usable answer"))
        }
        return draft
    }

    /// Too little text for OCR alone to identify the image (thresholds from `ExtractionConfig.Image`).
    static func isSparse(text: String, confidence: Double, config: ExtractionConfig.Image) -> Bool {
        let characters = text.count { !$0.isWhitespace }
        let words = text.split(whereSeparator: \.isWhitespace).count
        return characters < config.sparseChars || words < config.sparseWords || confidence < config.lowConfidence
    }

    // MARK: Trace

    private static func recordVLM(_ outcome: VisionOutcome, startedAt: Date, pixels: (Int, Int),
                                  on trace: TraceContext) async {
        struct Input: Encodable {
            var model: String
            var thinkDisabled: Bool
            var imageBytes: Int
            var width: Int
            var height: Int
            var schema: JSONValue
        }
        struct Output: Encodable {
            var raw: String?
            var visual: VisualSummary?
            var metrics: OllamaMetrics?
        }
        await trace.record(.vlm, status: outcome.summary == nil ? .error : .ok, startedAt: startedAt,
                           input: Input(model: outcome.model, thinkDisabled: outcome.thinkDisabled,
                                        imageBytes: outcome.imageBytes, width: pixels.0, height: pixels.1,
                                        schema: VisionDescriber.schema),
                           output: Output(raw: outcome.rawResponse, visual: outcome.summary, metrics: outcome.metrics),
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
