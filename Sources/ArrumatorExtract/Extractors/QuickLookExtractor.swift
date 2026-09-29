import ArrumatorCore
import CoreGraphics
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Formats without a native reader (xls, Numbers, Pages, Keynote, ppt, OpenDocument sheets/slides, PSD, AI, SVG,
/// and any other type the system can preview): Quick Look renders a thumbnail at `quickLookPixel`, which is OCRed.
/// When no preview can be produced the file is reported metadata-only as `unsupportedFormat`.
struct QuickLookExtractor: FileExtractor {
    let ocr: OCRService
    let metadataOnly: MetadataOnlyExtractor

    let name = "quicklook"
    let version = 1
    var supportedTypes: [UTType] {
        ["xls", "numbers", "pages", "key", "ppt", "ods", "odp", "psd", "ai", "svg", "epub"]
            .compactMap { UTType(filenameExtension: $0) }
    }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let config = job.config
        let preview: CGImage
        do {
            preview = try await Deadline.run(seconds: config.toolTimeout) {
                try await Self.thumbnail(for: job.url, pixels: config.quickLookPixel)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var draft = metadataOnly.draft(for: job)
            draft.warnings.append(ExtractionWarning(.unsupportedFormat, "no Quick Look preview: \(error)"))
            return draft
        }
        var pass = OCRPass(service: ocr, config: config)
        let languages = LanguageDetector(config: config).ranked(for: job.source.stem)
        let result = try await pass.recognize(preview, page: 1, languages: languages, timeout: config.pdf.ocrPageTimeout,
                                              orientationRetryBelow: nil)
        await pass.record(on: job.trace, input: ["previewWidth": preview.width, "previewHeight": preview.height])
        let text = result?.text ?? ""
        var draft = ExtractionDraft(kind: ContentKind.estimated(for: job.type), textOrigin: text.isEmpty ? .none : .ocr,
                                   text: text)
        draft.pagesOCRed = pass.recognisedPages
        draft.ocr = pass.stats
        draft.metadata = metadataOnly.draft(for: job).metadata
        draft.metadata["quicklook:preview"] = "\(preview.width)x\(preview.height)"
        draft.warnings = pass.allWarnings
        draft.structure = ContentStructure(paragraphCount: result?.paragraphs.count ?? 0,
                                           tables: (result?.tables ?? []).prefix(config.maxTables)
                                               .map { String($0.prefix(config.tableSnippetChars)) })
        draft.timings["ocr"] = pass.elapsedMs
        return draft
    }

    /// Best Quick Look thumbnail (never an icon) as a `CGImage`.
    private static func thumbnail(for url: URL, pixels: Int) async throws -> CGImage {
        let size = CGSize(width: pixels, height: pixels)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 1, representationTypes: .thumbnail)
        return try await withCheckedThrowingContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let image = representation?.cgImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? QuickLookError.noPreview)
                }
            }
        }
    }

    enum QuickLookError: Error, CustomStringConvertible {
        case noPreview
        var description: String { "Quick Look produced no thumbnail" }
    }
}
