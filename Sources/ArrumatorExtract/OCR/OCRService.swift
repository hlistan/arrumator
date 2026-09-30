import ArrumatorCore
import CoreGraphics
import Foundation
import ImageIO

/// Text recognised on one image.
struct OCRPageResult: Sendable {
    var text: String
    var paragraphs: [String]
    /// Tables rendered as TSV.
    var tables: [String]
    /// Character-weighted mean line confidence (0…1).
    var meanConfidence: Double
    /// Share of lines below the low-confidence threshold.
    var lowConfidenceShare: Double
    var lineCount: Int
    var engine: OCREngine
    var device: OCRDevice
    /// Orientation that produced the result (`up` unless the orientation retry won).
    var orientation: String
    /// Recognition languages in the order given to Vision.
    var languages: [String]
}

/// Options for one recognition.
struct OCRRequest: Sendable {
    /// Language codes to expect, most likely first: the document's own, then `extraction.ocrLanguages`.
    var languages: [String]
    var lowConfidenceLine: Double
    /// Retry the other three orientations when the mean confidence is below this (nil = never).
    var orientationRetryBelow: Double?
}

/// On-device OCR with Vision. Uses `RecognizeDocumentsRequest` (paragraphs, tables) when it supports every
/// configured language, else `RecognizeTextRequest`; always accurate, with language correction and automatic
/// language detection, languages ordered by the caller's hint.
///
/// Vision runs on its default device, the Neural Engine or GPU, until that fails: then the page is read again on the
/// CPU, and so is every later page. On physical Macs the Neural Engine path can fail when its model does not compile,
/// and then keeps failing until the process restarts, while the CPU path still reads text (E5RT error 13 in
/// `CRImageReaderError`; [TRex #95](https://github.com/amebalabs/TRex/pull/95),
/// [phone-harness #9](https://github.com/alexbejan/phone-harness/pull/9)). Virtual Macs, such as GitHub's runners,
/// cannot run Vision's text recognition on either device.
actor OCRService {
    private let recognizer: any TextRecognizing
    private var engineByLanguages: [[String]: OCREngine] = [:]
    private var device = OCRDevice.automatic

    init(recognizer: any TextRecognizing) {
        self.recognizer = recognizer
    }

    func recognize(_ image: CGImage, request: OCRRequest) async throws -> OCRPageResult {
        let engine = engine(for: request.languages)
        var best = try await perform(image, orientation: .up, engine: engine, request: request)
        if let threshold = request.orientationRetryBelow, best.lineCount > 0, best.meanConfidence < threshold {
            for orientation in [CGImagePropertyOrientation.right, .left, .down] {
                try Task.checkCancellation()
                let attempt = try await perform(image, orientation: orientation, engine: engine, request: request)
                if attempt.meanConfidence > best.meanConfidence { best = attempt }
            }
        }
        return best
    }

    // MARK: Engines and devices

    private func engine(for languages: [String]) -> OCREngine {
        let key = languages.sorted()
        if let cached = engineByLanguages[key] { return cached }
        let engine: OCREngine = recognizer.documentsSupport(languages) ? .recognizeDocuments : .recognizeText
        engineByLanguages[key] = engine
        return engine
    }

    private func perform(_ image: CGImage, orientation: CGImagePropertyOrientation, engine: OCREngine,
                         request: OCRRequest) async throws -> OCRPageResult {
        let device = device
        do {
            let found = try await recognizer.recognize(image, orientation: orientation, engine: engine,
                                                       languages: request.languages, on: device)
            return Self.result(found, engine: engine, device: device, orientation: orientation, request: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch where device == .automatic {
            Log.warning(.extract, "OCR failed on Vision's default device; reading on the CPU from now on",
                        ["engine": engine.rawValue, "error": error.localizedDescription])
            self.device = .cpu
            let found = try await recognizer.recognize(image, orientation: orientation, engine: engine,
                                                       languages: request.languages, on: .cpu)
            return Self.result(found, engine: engine, device: .cpu, orientation: orientation, request: request)
        }
    }

    // MARK: Helpers

    private static func result(_ found: RecognizedText, engine: OCREngine, device: OCRDevice,
                               orientation: CGImagePropertyOrientation, request: OCRRequest) -> OCRPageResult {
        let lines = found.lines
        let weights = lines.map { Double(max(1, $0.text.count)) }
        let totalWeight = weights.reduce(0, +)
        let mean = totalWeight > 0 ? zip(lines, weights).reduce(0) { $0 + $1.0.confidence * $1.1 } / totalWeight : 0
        let low = lines.isEmpty ? 0 : Double(lines.count { $0.confidence < request.lowConfidenceLine }) / Double(lines.count)
        return OCRPageResult(text: found.text, paragraphs: found.paragraphs, tables: found.tables, meanConfidence: mean,
                             lowConfidenceShare: low, lineCount: lines.count, engine: engine, device: device,
                             orientation: orientationName(orientation), languages: found.languages)
    }

    private static func orientationName(_ orientation: CGImagePropertyOrientation) -> String {
        switch orientation {
        case .up: "up"
        case .right: "right"
        case .left: "left"
        case .down: "down"
        default: "other"
        }
    }
}
