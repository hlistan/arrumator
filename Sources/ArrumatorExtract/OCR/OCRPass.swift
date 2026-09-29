import ArrumatorCore
import CoreGraphics
import Foundation

/// Per-page OCR outcome recorded in the `ocr` trace step.
struct OCRPageTrace: Sendable, Encodable {
    var page: Int
    var chars: Int
    var lines: Int
    var meanConfidence: Double
    var lowConfidenceShare: Double
    var orientation: String?
    var languages: [String]
    var engine: String?
    var durationMs: Double
    var error: String?
}

/// Runs OCR over the pages of one document with per-page timeouts, turning failures into warnings and
/// aggregating statistics for `ExtractedContent.ocr` and the `ocr` trace step.
struct OCRPass {
    private let service: OCRService
    private let config: ExtractionConfig
    private let startedAt = Date()
    private(set) var pages: [OCRPageTrace] = []
    private(set) var warnings: [ExtractionWarning] = []
    private var engine: OCREngine?

    init(service: OCRService, config: ExtractionConfig) {
        self.service = service
        self.config = config
    }

    /// Recognises `image` as page `page` (1-based). Returns nil (and records a warning) when OCR fails or times
    /// out; only cancellation is thrown.
    mutating func recognize(_ image: CGImage, page: Int, languages: [String], timeout: Double,
                            orientationRetryBelow: Double?) async throws -> OCRPageResult? {
        let started = Date()
        let request = OCRRequest(languages: languages, lowConfidenceLine: config.ocr.lowConfidenceLine,
                                 orientationRetryBelow: orientationRetryBelow)
        let service = service
        do {
            let result = try await Deadline.run(seconds: timeout) {
                try await service.recognize(image, request: request)
            }
            engine = result.engine
            pages.append(OCRPageTrace(page: page, chars: result.text.count, lines: result.lineCount,
                                      meanConfidence: result.meanConfidence,
                                      lowConfidenceShare: result.lowConfidenceShare, orientation: result.orientation,
                                      languages: result.languages, engine: result.engine.rawValue,
                                      durationMs: started.elapsedMs, error: nil))
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DeadlineExceeded {
            fail(page: page, languages: languages, started: started,
                 warning: ExtractionWarning(.timeout, "OCR of page \(page) exceeded \(error.seconds) s"))
        } catch {
            fail(page: page, languages: languages, started: started,
                 warning: ExtractionWarning(.ocrFailed, "page \(page): \(error.localizedDescription)"))
        }
        return nil
    }

    private mutating func fail(page: Int, languages: [String], started: Date, warning: ExtractionWarning) {
        warnings.append(warning)
        pages.append(OCRPageTrace(page: page, chars: 0, lines: 0, meanConfidence: 0, lowConfidenceShare: 0,
                                  orientation: nil, languages: languages, engine: nil,
                                  durationMs: started.elapsedMs, error: warning.detail))
    }

    /// Aggregate statistics over the pages that produced lines (character-weighted confidence).
    var stats: OCRStats? {
        let recognised = pages.filter { $0.lines > 0 }
        guard let engine, !recognised.isEmpty else { return nil }
        let chars = recognised.map { Double(max(1, $0.chars)) }
        let totalChars = chars.reduce(0, +)
        let mean = zip(recognised, chars).reduce(0) { $0 + $1.0.meanConfidence * $1.1 } / totalChars
        let totalLines = Double(recognised.reduce(0) { $0 + $1.lines })
        let low = recognised.reduce(0) { $0 + $1.lowConfidenceShare * Double($1.lines) } / totalLines
        return OCRStats(engine: engine.rawValue, meanConfidence: mean, lowConfidenceShare: low,
                        pages: recognised.map(\.page), perPageConfidence: recognised.map(\.meanConfidence))
    }

    /// Warnings including `ocrLowConfidence` when the document-level confidence is below the configured bound.
    var allWarnings: [ExtractionWarning] {
        guard let stats, stats.meanConfidence < config.ocr.lowConfidenceWarning else { return warnings }
        let mean = stats.meanConfidence.formatted(.number.precision(.fractionLength(2)))
        return warnings + [ExtractionWarning(.ocrLowConfidence, "mean confidence \(mean)")]
    }

    /// Pages OCR completed on (1-based), whether or not they held text.
    var recognisedPages: [Int] { pages.filter { $0.error == nil }.map(\.page) }

    var elapsedMs: Double { startedAt.elapsedMs }

    /// Records the `ocr` trace step (skipped when no page was attempted).
    func record(on trace: TraceContext, input: some Encodable & Sendable) async {
        guard !pages.isEmpty else { return }
        let stats = stats
        let output = TraceOutput(engine: stats?.engine, meanConfidence: stats?.meanConfidence,
                            lowConfidenceShare: stats?.lowConfidenceShare, pages: pages, warnings: allWarnings)
        let status: TraceStatus = allWarnings.isEmpty ? .ok : (stats == nil ? .error : .warn)
        await trace.record(.ocr, status: status, startedAt: startedAt, input: input, output: output)
    }

    private struct TraceOutput: Encodable {
        var engine: String?
        var meanConfidence: Double?
        var lowConfidenceShare: Double?
        var pages: [OCRPageTrace]
        var warnings: [ExtractionWarning]
    }
}
