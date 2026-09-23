import CoreGraphics
import Foundation
import ImageIO
import Vision

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
    /// Orientation that produced the result (`up` unless the orientation retry won).
    var orientation: String
    /// Recognition languages in the order given to Vision.
    var languages: [String]
}

enum OCREngine: String, Sendable, Encodable {
    case recognizeDocuments = "vision.RecognizeDocumentsRequest"
    case recognizeText = "vision.RecognizeTextRequest"
}

/// Options for one recognition.
struct OCRRequest: Sendable {
    /// Configured language codes (`en`, `ru`, `pt`), most likely first.
    var languages: [String]
    var lowConfidenceLine: Double
    /// Retry the other three orientations when the mean confidence is below this (nil = never).
    var orientationRetryBelow: Double?
}

/// On-device OCR with Vision. Uses `RecognizeDocumentsRequest` (paragraphs, tables) when it supports every
/// configured language, else `RecognizeTextRequest`; always accurate, with language correction and automatic
/// language detection, languages ordered by the caller's hint.
actor OCRService {
    private var engineByLanguages: [[String]: OCREngine] = [:]

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

    // MARK: Engines

    private func engine(for languages: [String]) -> OCREngine {
        let key = languages.sorted()
        if let cached = engineByLanguages[key] { return cached }
        let supported = Set(RecognizeDocumentsRequest().supportedRecognitionLanguages.compactMap(\.languageCode?.identifier))
        let engine: OCREngine = languages.allSatisfy(supported.contains) ? .recognizeDocuments : .recognizeText
        engineByLanguages[key] = engine
        return engine
    }

    private func perform(_ image: CGImage, orientation: CGImagePropertyOrientation, engine: OCREngine,
                         request: OCRRequest) async throws -> OCRPageResult {
        switch engine {
        case .recognizeDocuments:
            var vision = RecognizeDocumentsRequest()
            let languages = Self.locales(request.languages, supported: vision.supportedRecognitionLanguages)
            vision.textRecognitionOptions.recognitionLanguages = languages
            vision.textRecognitionOptions.automaticallyDetectLanguage = true
            vision.textRecognitionOptions.useLanguageCorrection = true
            let documents = try await vision.perform(on: image, orientation: orientation)
            let lines = documents.flatMap(\.document.text.lines)
            let paragraphs = documents.flatMap(\.document.paragraphs).map(\.transcript)
            let tables = documents.flatMap(\.document.tables).map { table in
                table.rows.map { row in
                    row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
                }
                .joined(separator: "\n")
            }
            let text = documents.map(\.document.text.transcript).joined(separator: "\n")
            return Self.result(text: text, paragraphs: paragraphs, tables: tables,
                               lines: lines.map { ($0.transcript, Double($0.confidence)) }, engine: engine,
                               orientation: orientation, languages: languages, request: request)
        case .recognizeText:
            var vision = RecognizeTextRequest()
            let languages = Self.locales(request.languages, supported: vision.supportedRecognitionLanguages)
            vision.recognitionLevel = .accurate
            vision.recognitionLanguages = languages
            vision.automaticallyDetectsLanguage = true
            vision.usesLanguageCorrection = true
            let observations = try await vision.perform(on: image, orientation: orientation)
            let lines = observations.map { ($0.transcript, Double($0.confidence)) }
            let text = lines.map(\.0).joined(separator: "\n")
            return Self.result(text: text, paragraphs: lines.map(\.0), tables: [], lines: lines, engine: engine,
                               orientation: orientation, languages: languages, request: request)
        }
    }

    // MARK: Helpers

    /// Supported Vision locales for each configured language code, in the caller's order.
    private static func locales(_ codes: [String], supported: [Locale.Language]) -> [Locale.Language] {
        codes.flatMap { code in supported.filter { $0.languageCode?.identifier == code } }
    }

    private static func result(text: String, paragraphs: [String], tables: [String], lines: [(String, Double)],
                               engine: OCREngine, orientation: CGImagePropertyOrientation,
                               languages: [Locale.Language], request: OCRRequest) -> OCRPageResult {
        let weights = lines.map { Double(max(1, $0.0.count)) }
        let totalWeight = weights.reduce(0, +)
        let mean = totalWeight > 0 ? zip(lines, weights).reduce(0) { $0 + $1.0.1 * $1.1 } / totalWeight : 0
        let low = lines.isEmpty ? 0 : Double(lines.count { $0.1 < request.lowConfidenceLine }) / Double(lines.count)
        return OCRPageResult(text: text, paragraphs: paragraphs, tables: tables, meanConfidence: mean,
                             lowConfidenceShare: low, lineCount: lines.count, engine: engine,
                             orientation: orientationName(orientation),
                             languages: languages.map(\.minimalIdentifier))
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
