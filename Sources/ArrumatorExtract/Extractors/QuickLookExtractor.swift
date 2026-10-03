import ArrumatorCore
import CoreGraphics
import Foundation
import QuickLookThumbnailing
import Synchronization
import UniformTypeIdentifiers

/// Formats without a native reader (xls, Numbers, Pages, Keynote, ppt, OpenDocument sheets/slides, PSD, AI, SVG,
/// and any other type the system can preview): Quick Look renders a thumbnail at `quickLookPixel`, which is OCRed.
/// When no preview can be produced the file is reported metadata-only as `unsupportedFormat`.
struct QuickLookExtractor: FileExtractor {
    let ocr: OCRService
    let metadataOnly: MetadataOnlyExtractor
    let thumbnails: any Thumbnailing

    let name = "quicklook"
    let version = 1
    var supportedTypes: [UTType] {
        ["xls", "numbers", "pages", "key", "ppt", "ods", "odp", "psd", "ai", "svg", "epub"]
            .compactMap { UTType(filenameExtension: $0) }
    }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let config = job.config
        let preview: CGImage
        let thumbnails = thumbnails
        do {
            preview = try await Deadline.run(config.toolTimeout, time: job.time,
                                             expired: { DeadlineExceeded(seconds: config.toolTimeout) }) {
                try await Self.thumbnail(for: job.url, pixels: config.quickLookPixel, from: thumbnails)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var draft = metadataOnly.draft(for: job)
            draft.warnings.append(ExtractionWarning(.unsupportedFormat, "no Quick Look preview: \(error)"))
            return draft
        }
        var pass = OCRPass(service: ocr, config: config, time: job.time)
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

    /// The best thumbnail of `url` (never an icon) as a `CGImage`. A task cancelled while it is made, as at the
    /// deadline, which then no longer waits for it, cancels the request, so Quick Look stops making it.
    private static func thumbnail(for url: URL, pixels: Int, from thumbnails: any Thumbnailing) async throws -> CGImage {
        let request = PendingThumbnail()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.started(thumbnails.start(url, pixels: pixels) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? QuickLookError.noPreview)
                    }
                })
            }
        } onCancel: {
            request.cancel()
        }
    }

    /// A request that the task may be cancelled before or after it is started: it is cancelled as soon as both are so.
    private final class PendingThumbnail: Sendable {
        private let state = Mutex<(request: (any ThumbnailRequest)?, cancelled: Bool)>((nil, false))

        func started(_ request: any ThumbnailRequest) {
            let cancelled = state.withLock { state in
                state.request = request
                return state.cancelled
            }
            if cancelled { request.cancel() }
        }

        func cancel() {
            let request = state.withLock { state in
                state.cancelled = true
                return state.request
            }
            request?.cancel()
        }
    }

    enum QuickLookError: Error, CustomStringConvertible {
        case noPreview
        var description: String { "Quick Look produced no thumbnail" }
    }
}

/// A thumbnail being made, which can be cancelled while it is.
protocol ThumbnailRequest: Sendable {
    func cancel()
}

/// Makes a file's thumbnail: Quick Look's (`QuickLookThumbnails`), or a test's.
protocol Thumbnailing: Sendable {
    /// Starts making the best thumbnail of `url` within `pixels` square. `completion` is called once, when it is made
    /// or cannot be, a request cancelled included.
    func start(_ url: URL, pixels: Int, completion: @escaping @Sendable (CGImage?, (any Error)?) -> Void) -> any ThumbnailRequest
}

/// Quick Look's thumbnails (`QLThumbnailGenerator`), whose completion handler is "always called when the thumbnail
/// generation is over", a cancelled request with `QLThumbnailError.requestCancelled`.
struct QuickLookThumbnails: Thumbnailing {
    func start(_ url: URL, pixels: Int, completion: @escaping @Sendable (CGImage?, (any Error)?) -> Void) -> any ThumbnailRequest {
        let started = Started(QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels, height: pixels), scale: 1,
                                                           representationTypes: .thumbnail))
        started.request.withLock { request in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                completion(representation?.cgImage, error)
            }
        }
        return started
    }

    /// The request Quick Look was given, which it is told to cancel by: held under a lock, as a request is no
    /// `Sendable` value and the cancel comes from another task.
    private final class Started: ThumbnailRequest {
        let request: Mutex<QLThumbnailGenerator.Request>

        init(_ request: sending QLThumbnailGenerator.Request) { self.request = Mutex(request) }

        func cancel() { request.withLock { QLThumbnailGenerator.shared.cancel($0) } }
    }
}
