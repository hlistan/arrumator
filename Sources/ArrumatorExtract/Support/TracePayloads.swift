import ArrumatorCore
import Foundation

/// `extract` step input: which file and which extractor.
struct ExtractTraceInput: Encodable, Sendable {
    var filename: String
    var utType: String
    var byteSize: Int64
    var whereFroms: [String]
    var extractor: String
    var extractorVersion: Int
    var timeoutSeconds: Double
}

/// `extract` step output: shape of the result, never the text itself (only a short preview).
struct ExtractTraceOutput: Encodable, Sendable {
    var kind: ContentKind
    var textOrigin: TextOrigin
    var extractedLength: Int
    var textLength: Int
    var textTruncated: Bool
    var preview: String
    var pageCount: Int?
    var pagesOCRed: [Int]
    var ocr: OCRStats?
    var encoding: String?
    var language: LanguageGuess
    var metadata: [String: String]
    var attachments: Int
    var structure: ContentStructure?
    var visualKind: String?
    var warnings: [ExtractionWarning]
    var timings: [String: Double]
}

/// `entities` step input.
struct EntitiesTraceInput: Encodable, Sendable {
    var textLength: Int
    var firstPageLength: Int?
    var metadataDates: [MetadataDate]
    var fileCreated: Date?
    var fileModified: Date?
}

/// `entities` step output: every scored date occurrence, the chosen date and the identifiers found.
struct EntitiesTraceOutput: Encodable, Sendable {
    var dateCandidates: [ScoredDate]
    var chosen: DetectedDate?
    var stableKeys: [String]
    var amounts: Int
    var currencies: [String]
    var emailDomains: [String]
    var urls: Int
    var phones: Int
}
