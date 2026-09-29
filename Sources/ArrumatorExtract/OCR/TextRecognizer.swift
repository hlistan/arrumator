import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// Where Vision runs a recognition.
enum OCRDevice: String, Sendable, Encodable {
    /// Vision's own choice: the Neural Engine or the GPU where the Mac has one.
    case automatic
    /// The CPU alone, for every stage of the request.
    case cpu
}

/// One recognised line and Vision's confidence in it (0…1).
struct RecognizedLine: Sendable {
    var text: String
    var confidence: Double
}

/// What one recognition found, before it is scored.
struct RecognizedText: Sendable {
    var text: String
    var paragraphs: [String]
    /// Tables rendered as TSV.
    var tables: [String]
    var lines: [RecognizedLine]
    /// Recognition languages in the order given to Vision.
    var languages: [String]
}

/// Runs one text recognition. `OCRService` decides the engine, orientation and device; this only asks.
protocol TextRecognizing: Sendable {
    /// Whether `RecognizeDocumentsRequest` reads every one of these language codes.
    func documentsSupport(_ languages: [String]) -> Bool
    func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation, engine: OCREngine, languages: [String],
                   on device: OCRDevice) async throws -> RecognizedText
}

/// Vision's text recognition, always accurate, with language correction and automatic language detection.
struct VisionTextRecognizer: TextRecognizing {
    func documentsSupport(_ languages: [String]) -> Bool {
        let supported = Set(RecognizeDocumentsRequest().supportedRecognitionLanguages.compactMap(\.languageCode?.identifier))
        return languages.allSatisfy(supported.contains)
    }

    func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation, engine: OCREngine, languages: [String],
                   on device: OCRDevice) async throws -> RecognizedText {
        switch engine {
        case .recognizeDocuments:
            var vision = RecognizeDocumentsRequest()
            if device == .cpu { vision.runOnCPU() }
            let locales = Self.locales(languages, supported: vision.supportedRecognitionLanguages)
            vision.textRecognitionOptions.recognitionLanguages = locales
            vision.textRecognitionOptions.automaticallyDetectLanguage = true
            vision.textRecognitionOptions.useLanguageCorrection = true
            let documents = try await vision.perform(on: image, orientation: orientation)
            let lines = documents.flatMap(\.document.text.lines)
            let tables = documents.flatMap(\.document.tables).map { table in
                table.rows.map { row in
                    row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
                }
                .joined(separator: "\n")
            }
            return RecognizedText(text: documents.map(\.document.text.transcript).joined(separator: "\n"),
                                  paragraphs: documents.flatMap(\.document.paragraphs).map(\.transcript), tables: tables,
                                  lines: lines.map { RecognizedLine(text: $0.transcript, confidence: Double($0.confidence)) },
                                  languages: locales.map(\.minimalIdentifier))
        case .recognizeText:
            var vision = RecognizeTextRequest()
            if device == .cpu { vision.runOnCPU() }
            let locales = Self.locales(languages, supported: vision.supportedRecognitionLanguages)
            vision.recognitionLevel = .accurate
            vision.recognitionLanguages = locales
            vision.automaticallyDetectsLanguage = true
            vision.usesLanguageCorrection = true
            let lines = try await vision.perform(on: image, orientation: orientation)
                .map { RecognizedLine(text: $0.transcript, confidence: Double($0.confidence)) }
            return RecognizedText(text: lines.map(\.text).joined(separator: "\n"), paragraphs: lines.map(\.text),
                                  tables: [], lines: lines, languages: locales.map(\.minimalIdentifier))
        }
    }

    /// Supported Vision locales for each configured language code, in the caller's order.
    private static func locales(_ codes: [String], supported: [Locale.Language]) -> [Locale.Language] {
        codes.flatMap { code in supported.filter { $0.languageCode?.identifier == code } }
    }
}

extension VisionRequest {
    /// Runs every stage the request can run on the CPU there
    /// ([Apple: `setComputeDevice(_:for:)`](https://developer.apple.com/documentation/vision/visionrequest/setcomputedevice(_:for:))).
    mutating func runOnCPU() {
        for (stage, devices) in supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                setComputeDevice(cpu, for: stage)
            }
        }
    }
}
