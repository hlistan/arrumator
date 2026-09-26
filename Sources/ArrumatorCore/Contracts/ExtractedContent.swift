import Foundation

/// Identity and file-system facts about an ingested file, captured before extraction.
public struct SourceFile: Sendable, Codable, Hashable {
    public var path: String
    public var originalFilename: String
    public var fileExtension: String
    public var utType: String
    public var byteSize: Int64
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var sha256: String
    public var whereFroms: [String]

    public init(path: String, originalFilename: String, fileExtension: String, utType: String,
                byteSize: Int64, createdAt: Date?, modifiedAt: Date?, sha256: String, whereFroms: [String] = []) {
        self.path = path
        self.originalFilename = originalFilename
        self.fileExtension = fileExtension
        self.utType = utType
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
        self.whereFroms = whereFroms
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var stem: String { (originalFilename as NSString).deletingPathExtension }
}

public enum ContentKind: String, Sendable, Codable, CaseIterable {
    case textDocument, pdfText, pdfScanned, pdfMixed, image, spreadsheet, presentation, email, archive, media, unknown
}

public enum TextOrigin: String, Sendable, Codable {
    case textLayer, ocr, mixed, vlmOnly, metadataOnly, none
}

public struct OCRStats: Sendable, Codable, Hashable {
    public var engine: String
    public var meanConfidence: Double
    public var lowConfidenceShare: Double
    public var pages: [Int]
    public var perPageConfidence: [Double]

    public init(engine: String, meanConfidence: Double, lowConfidenceShare: Double, pages: [Int], perPageConfidence: [Double]) {
        self.engine = engine
        self.meanConfidence = meanConfidence
        self.lowConfidenceShare = lowConfidenceShare
        self.pages = pages
        self.perPageConfidence = perPageConfidence
    }
}

public struct LanguageGuess: Sendable, Codable, Hashable {
    /// "en" | "ru" | "pt" | "other" | "und"
    public var primary: String
    public var confidence: Double
    public var hypotheses: [String: Double]

    public init(primary: String, confidence: Double, hypotheses: [String: Double] = [:]) {
        self.primary = primary
        self.confidence = confidence
        self.hypotheses = hypotheses
    }

    public static let undetermined = LanguageGuess(primary: "und", confidence: 0)
}

public enum DateSource: String, Sendable, Codable {
    case label, prominence, exif, pdfMeta, fileCreated, mtime, llm, rule, none
}

public struct DetectedDate: Sendable, Codable, Hashable {
    /// ISO date `YYYY-MM-DD`.
    public var date: String
    public var score: Double
    public var source: DateSource
    public var context: String

    public init(date: String, score: Double, source: DateSource, context: String) {
        self.date = date
        self.score = score
        self.source = source
        self.context = context
    }
}

public struct MoneyAmount: Sendable, Codable, Hashable {
    public var value: String
    public var currency: String
    public init(value: String, currency: String) {
        self.value = value
        self.currency = currency
    }
}

public enum StableKeyKind: String, Sendable, Codable, CaseIterable {
    case iban, ptNIF, ruINN, ruOGRN, ruKPP, ruBIK, ruAccount, vatEU, accountNumber, policyOrContract
}

/// A checksum-validated or label-anchored identifier (IBAN, NIF, ИНН, …) used for deterministic matching.
public struct StableKey: Sendable, Codable, Hashable {
    public var kind: StableKeyKind
    public var value: String
    public init(kind: StableKeyKind, value: String) {
        self.kind = kind
        self.value = value
    }
    public var token: String { "\(kind.rawValue):\(value)" }
    public init?(token: String) {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = StableKeyKind(rawValue: parts[0]) else { return nil }
        self.init(kind: kind, value: parts[1])
    }
}

public struct Entities: Sendable, Codable, Hashable {
    public var dates: [DetectedDate]
    public var documentDate: DetectedDate?
    public var amounts: [MoneyAmount]
    public var emails: [String]
    public var urls: [String]
    public var phones: [String]
    public var stableKeys: [StableKey]

    public init(dates: [DetectedDate] = [], documentDate: DetectedDate? = nil, amounts: [MoneyAmount] = [],
                emails: [String] = [], urls: [String] = [], phones: [String] = [], stableKeys: [StableKey] = []) {
        self.dates = dates
        self.documentDate = documentDate
        self.amounts = amounts
        self.emails = emails
        self.urls = urls
        self.phones = phones
        self.stableKeys = stableKeys
    }

    public static let empty = Entities()
}

public struct ContentStructure: Sendable, Codable, Hashable {
    public var paragraphCount: Int
    /// First tables rendered as TSV (each ≤ 2 000 chars).
    public var tables: [String]
    public var sheetNames: [String]
    public var slideCount: Int?

    public init(paragraphCount: Int = 0, tables: [String] = [], sheetNames: [String] = [], slideCount: Int? = nil) {
        self.paragraphCount = paragraphCount
        self.tables = tables
        self.sheetNames = sheetNames
        self.slideCount = slideCount
    }
}

public struct VisualSummary: Sendable, Codable, Hashable {
    public var imageKind: String
    public var description: String
    public var visibleTextSummary: String
    public var organisations: [String]
    public var unverifiedOrganisations: [String]
    public var dates: [String]

    public init(imageKind: String, description: String, visibleTextSummary: String,
                organisations: [String], unverifiedOrganisations: [String] = [], dates: [String]) {
        self.imageKind = imageKind
        self.description = description
        self.visibleTextSummary = visibleTextSummary
        self.organisations = organisations
        self.unverifiedOrganisations = unverifiedOrganisations
        self.dates = dates
    }
}

public enum WarningCode: String, Sendable, Codable, CaseIterable {
    case unsupportedFormat, corrupted, encrypted, tooLarge, toolFailed, ocrLowConfidence, ocrFailed
    case textTruncated, vlmFailed, vlmSkipped, encodingGuessed, emptyText, timeout
}

/// Soft, non-fatal extraction problem. Recorded, shown in the UI, and used by the calibrator.
public struct ExtractionWarning: Sendable, Codable, Hashable {
    public var code: WarningCode
    public var detail: String
    public init(_ code: WarningCode, _ detail: String = "") {
        self.code = code
        self.detail = detail
    }
}

/// Hard extraction failure: the pipeline retries the job.
public enum ExtractionError: Error, Sendable, LocalizedError {
    case fileUnreadable(path: String, underlying: String)
    case timeout(stage: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .fileUnreadable(path, underlying): "Cannot read \(path): \(underlying)"
        case let .timeout(stage): "Extraction timed out during \(stage)"
        case .cancelled: "Extraction cancelled"
        }
    }
}

/// Everything the pipeline learned about a file's content. Pure value, safe to persist and replay.
public struct ExtractedContent: Sendable, Codable {
    public var source: SourceFile
    public var kind: ContentKind
    public var textOrigin: TextOrigin
    /// NFC-normalised full text, capped at `ExtractionConfig.maxIndexChars`.
    public var text: String
    public var textTruncated: Bool
    public var pageCount: Int?
    public var pagesOCRed: [Int]
    public var ocr: OCRStats?
    public var language: LanguageGuess
    public var entities: Entities
    public var structure: ContentStructure?
    public var metadata: [String: String]
    public var visual: VisualSummary?
    public var attachments: [String]
    public var warnings: [ExtractionWarning]
    public var timings: [String: Double]
    public var extractorName: String
    public var extractorVersion: Int

    public init(source: SourceFile, kind: ContentKind, textOrigin: TextOrigin, text: String,
                textTruncated: Bool = false, pageCount: Int? = nil, pagesOCRed: [Int] = [], ocr: OCRStats? = nil,
                language: LanguageGuess = .undetermined, entities: Entities = .empty, structure: ContentStructure? = nil,
                metadata: [String: String] = [:], visual: VisualSummary? = nil, attachments: [String] = [],
                warnings: [ExtractionWarning] = [], timings: [String: Double] = [:],
                extractorName: String, extractorVersion: Int = 1) {
        self.source = source
        self.kind = kind
        self.textOrigin = textOrigin
        self.text = text
        self.textTruncated = textTruncated
        self.pageCount = pageCount
        self.pagesOCRed = pagesOCRed
        self.ocr = ocr
        self.language = language
        self.entities = entities
        self.structure = structure
        self.metadata = metadata
        self.visual = visual
        self.attachments = attachments
        self.warnings = warnings
        self.timings = timings
        self.extractorName = extractorName
        self.extractorVersion = extractorVersion
    }

    /// Content for a file whose bytes could not be understood at all.
    public static func metadataOnly(_ source: SourceFile, kind: ContentKind = .unknown,
                                    warnings: [ExtractionWarning] = [], metadata: [String: String] = [:]) -> ExtractedContent {
        ExtractedContent(source: source, kind: kind, textOrigin: .metadataOnly, text: "",
                         metadata: metadata, warnings: warnings, extractorName: "metadata-only")
    }

    public func hasWarning(_ code: WarningCode) -> Bool { warnings.contains { $0.code == code } }

    /// Share of the excerpt budget given to the end of the document (1/6).
    private static let excerptTailDivisor = 6

    /// Excerpt for the classification prompt: head + tail + first table, ≤ `maxChars`.
    public func classificationExcerpt(maxChars: Int) -> String {
        var body = text
        if let visual {
            body = "[Image: \(visual.imageKind)] \(visual.description)\nVisible text: \(visual.visibleTextSummary)\n" + body
        }
        guard body.count > maxChars else { return body }
        // Head carries titles, parties and dates; the tail carries totals and signatures.
        let separator = "\n…\n"
        let tailCount = maxChars / Self.excerptTailDivisor
        let headCount = maxChars - tailCount - separator.count
        return String(body.prefix(headCount)) + separator + String(body.suffix(tailCount))
    }

    /// Compact description used for embeddings, identical in shape for documents and memories.
    public func embeddingSummary(correspondentHint: String?, maxChars: Int) -> String {
        var lines: [String] = []
        lines.append("filename: \(source.originalFilename)")
        var typeLine = "type: \(source.fileExtension.isEmpty ? kind.rawValue : source.fileExtension)"
        if let pageCount { typeLine += ", \(pageCount) pages" }
        typeLine += ", language: \(language.primary)"
        lines.append(typeLine)
        if let correspondentHint, !correspondentHint.isEmpty { lines.append("correspondent hints: \(correspondentHint)") }
        if !entities.stableKeys.isEmpty {
            lines.append("identifiers: " + entities.stableKeys.prefix(6).map(\.token).joined(separator: "; "))
        }
        if let date = entities.documentDate?.date { lines.append("document date: \(date)") }
        lines.append("---")
        var body = text
        if let visual {
            body = "\(visual.imageKind): \(visual.description) \(visual.visibleTextSummary)\n" + body
        }
        let header = lines.joined(separator: "\n")
        let remaining = max(0, maxChars - header.count - 1)
        return header + "\n" + String(body.prefix(remaining))
    }
}

/// Per-call inputs for extraction: tunables plus the optional vision model for image understanding.
public struct ExtractionContext: Sendable {
    public var config: ExtractionConfig
    public var entities: EntityConfig
    public var vision: VisionModelOptions?

    public init(config: ExtractionConfig, entities: EntityConfig, vision: VisionModelOptions?) {
        self.config = config
        self.entities = entities
        self.vision = vision
    }
}

public struct VisionModelOptions: Sendable {
    public var model: String
    public var keepAlive: String
    public var numPredict: Int
    /// The context the model is asked with (`ResolvedModels.visionNumCtx`).
    public var numCtx: Int
    public var options: ClassificationConfig.LLMOptions

    public init(model: String, keepAlive: String, numPredict: Int, numCtx: Int, options: ClassificationConfig.LLMOptions) {
        self.model = model
        self.keepAlive = keepAlive
        self.numPredict = numPredict
        self.numCtx = numCtx
        self.options = options
    }
}
