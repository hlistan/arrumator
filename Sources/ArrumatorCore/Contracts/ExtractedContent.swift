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

    /// What the file is, in words, as History says it: “a scanned PDF”.
    public var described: String {
        switch self {
        case .textDocument: "a text document"
        case .pdfText: "a PDF"
        case .pdfScanned: "a scanned PDF"
        case .pdfMixed: "a partly scanned PDF"
        case .image: "an image"
        case .spreadsheet: "a spreadsheet"
        case .presentation: "a presentation"
        case .email: "an e-mail"
        case .archive: "an archive"
        case .media: "a media file"
        case .unknown: "a file"
        }
    }
}

public enum TextOrigin: String, Sendable, Codable {
    case textLayer, ocr, mixed, vlmOnly, metadataOnly, none
}

/// The Vision request that recognised a document's text.
public enum OCREngine: String, Sendable, Codable, Hashable {
    case recognizeDocuments = "vision.RecognizeDocumentsRequest"
    case recognizeText = "vision.RecognizeTextRequest"
}

public struct OCRStats: Sendable, Codable, Hashable {
    public var engine: OCREngine
    public var meanConfidence: Double
    public var lowConfidenceShare: Double
    public var pages: [Int]
    public var perPageConfidence: [Double]

    public init(engine: OCREngine, meanConfidence: Double, lowConfidenceShare: Double, pages: [Int], perPageConfidence: [Double]) {
        self.engine = engine
        self.meanConfidence = meanConfidence
        self.lowConfidenceShare = lowConfidenceShare
        self.pages = pages
        self.perPageConfidence = perPageConfidence
    }
}

public struct LanguageGuess: Sendable, Codable, Hashable {
    /// The ISO 639-1 code of the language most of the text is in, of any NaturalLanguage recognises; `und` when there is
    /// too little text to tell.
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
    case label, prominence, exif, pdfMeta, fileCreated, mtime
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

public enum StableKeyKind: String, Sendable, Codable, CaseIterable {
    case iban, ptNIF, ruINN, ruOGRN, ruKPP, ruBIK, ruAccount, vatEU, accountNumber, policyOrContract

    /// The identifier in words, as the model is told of it: given a code name, it copies it into a label.
    public var described: String {
        switch self {
        case .iban: "IBAN"
        case .ptNIF: "Portuguese tax number (NIF)"
        case .ruINN: "Russian taxpayer number (ИНН)"
        case .ruOGRN: "Russian company registration number (ОГРН)"
        case .ruKPP: "Russian tax registration reason code (КПП)"
        case .ruBIK: "Russian bank code (БИК)"
        case .ruAccount: "Russian bank account number"
        case .vatEU: "EU VAT number"
        case .accountNumber: "account number"
        case .policyOrContract: "policy or contract number"
        }
    }
}

/// A checksum-validated or label-anchored identifier (IBAN, NIF, ИНН, …): shown to the model with the document, and
/// part of the text its embedding is made from.
public struct StableKey: Sendable, Codable, Hashable {
    public var kind: StableKeyKind
    public var value: String
    public init(kind: StableKeyKind, value: String) {
        self.kind = kind
        self.value = value
    }
    public var token: String { "\(kind.rawValue):\(value)" }
}

/// What the extractor finds in a document's text without a model: its dates, the one it was issued on, and its
/// identifiers. The model reads the rest.
public struct Entities: Sendable, Codable, Hashable {
    public var dates: [DetectedDate]
    public var documentDate: DetectedDate?
    public var stableKeys: [StableKey]

    public init(dates: [DetectedDate] = [], documentDate: DetectedDate? = nil, stableKeys: [StableKey] = []) {
        self.dates = dates
        self.documentDate = documentDate
        self.stableKeys = stableKeys
    }

    public static let empty = Entities()
}

public struct ContentStructure: Sendable, Codable, Hashable {
    public var paragraphCount: Int
    /// First tables rendered as TSV, each at most `extraction.tableSnippetChars`.
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

/// What an image shows, as the vision model classes it (the `image_kind` its answer is constrained to).
public enum ImageKind: String, CaseIterable, Sendable, Codable, Hashable {
    case photo, screenshot, scannedDocument = "scanned_document", receipt, idCard = "id_card", whiteboard, diagram, other
}

public struct VisualSummary: Sendable, Codable, Hashable {
    public var imageKind: ImageKind
    public var description: String
    public var visibleTextSummary: String
    public var organisations: [String]
    public var unverifiedOrganisations: [String]
    public var dates: [String]

    public init(imageKind: ImageKind, description: String, visibleTextSummary: String,
                organisations: [String], unverifiedOrganisations: [String] = [], dates: [String]) {
        self.imageKind = imageKind
        self.description = description
        self.visibleTextSummary = visibleTextSummary
        self.organisations = organisations
        self.unverifiedOrganisations = unverifiedOrganisations
        self.dates = dates
    }
}

public enum WarningCode: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    case unsupportedFormat, corrupted, encrypted, tooLarge, toolFailed, ocrLowConfidence, ocrFailed
    case textTruncated, vlmFailed, vlmSkipped, encodingGuessed, emptyText, timeout
}

/// Soft, non-fatal extraction problem: recorded in the trace, told to the model with the document, and counted in
/// Statistics.
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

    public func hasWarning(_ code: WarningCode) -> Bool { warnings.contains { $0.code == code } }

    /// Whether its text is not all of it: cut to `extraction.maxIndexChars`, or not every page read.
    public var isPartial: Bool { textTruncated || hasWarning(.textTruncated) }

    /// How its text was recognised: from its text layer, by OCR, or both; nil when it has none, as an image only the
    /// vision model described, whose words are no text of its own.
    public var recognition: TextOrigin? { [.textLayer, .ocr, .mixed].contains(textOrigin) ? textOrigin : nil }

    /// Excerpt for the prompt: the head and the tail of the text, at most `maxChars`, of which the tail gets
    /// `1 / tailDivisor`; the head alone when `maxChars` leaves no room for it beside the tail and the separator. The
    /// configuration gives only a `maxChars` that holds a head (`excerptHasHead`).
    public func classificationExcerpt(maxChars: Int, tailDivisor: Int) -> String {
        var body = text
        if let visual {
            body = "[Image: \(visual.imageKind.rawValue)] \(visual.description)\nVisible text: \(visual.visibleTextSummary)\n" + body
        }
        guard body.count > maxChars else { return body }
        // Head carries titles, parties and dates; the tail carries totals and signatures.
        let tailCount = maxChars / tailDivisor
        let headCount = maxChars - tailCount - Self.excerptSeparator.count
        guard headCount > 0 else { return String(body.prefix(max(0, maxChars))) }
        return String(body.prefix(headCount)) + Self.excerptSeparator + String(body.suffix(tailCount))
    }

    /// What stands between the head and the tail of an excerpt.
    static let excerptSeparator = "\n…\n"

    /// Whether an excerpt of `maxChars`, of which the tail gets `1 / tailDivisor`, has room for its head beside the tail
    /// and the separator.
    static func excerptHasHead(maxChars: Int, tailDivisor: Int) -> Bool {
        tailDivisor > 0 && maxChars - maxChars / tailDivisor - excerptSeparator.count >= 0
    }

    /// The text a document's embedding is made from: what it is, who sent it, what the model read it as
    /// (`DocumentAnalysis.interpretation`), its first `identifiersLimit` identifiers and date, then its text, at most
    /// `maxChars` in all.
    public func embeddingSummary(senders: [String], interpretation: String?, maxChars: Int, identifiersLimit: Int) -> String {
        var lines: [String] = []
        lines.append("filename: \(source.originalFilename)")
        var typeLine = "type: \(source.fileExtension.isEmpty ? kind.rawValue : source.fileExtension)"
        if let pageCount { typeLine += ", \(pageCount) pages" }
        typeLine += ", language: \(language.primary)"
        lines.append(typeLine)
        if !senders.isEmpty { lines.append("from: " + senders.joined(separator: "; ")) }
        if let interpretation { lines.append("about: " + interpretation) }
        if !entities.stableKeys.isEmpty {
            lines.append("identifiers: " + entities.stableKeys.prefix(identifiersLimit).map(\.token).joined(separator: "; "))
        }
        if let date = entities.documentDate?.date { lines.append("document date: \(date)") }
        lines.append("---")
        var body = text
        if let visual {
            body = "\(visual.imageKind.rawValue): \(visual.description) \(visual.visibleTextSummary)\n" + body
        }
        let header = lines.joined(separator: "\n")
        let remaining = max(0, maxChars - header.count - 1)
        return header + "\n" + String(body.prefix(remaining))
    }
}

/// Keys of `ExtractedContent.metadata` that one module writes and another reads.
public enum MetadataKey {
    /// An e-mail's headers, decoded: `email:from`, `email:to`, `email:cc`, `email:subject`, and its date and message ID.
    public static func email(_ header: String) -> String { "email:" + header }
    public static let emailFrom = email("from")
    public static let emailSubject = email("subject")
    public static let emailDate = email("date")
    public static let emailMessageID = email("messageId")
}

/// Per-call inputs for extraction: tunables plus the optional vision model for image understanding.
public struct ExtractionContext: Sendable {
    public var config: ExtractionConfig
    public var entities: EntityConfig
    public var vision: VisionModelOptions?
    public var whenOllamaIsAway: WhenOllamaIsAway

    public init(config: ExtractionConfig, entities: EntityConfig, vision: VisionModelOptions?, whenOllamaIsAway: WhenOllamaIsAway) {
        self.config = config
        self.entities = entities
        self.vision = vision
        self.whenOllamaIsAway = whenOllamaIsAway
    }
}

/// What extraction does when Ollama cannot be reached to describe an image.
public enum WhenOllamaIsAway: Sendable {
    /// Throw Ollama's error, so the document's job waits for Ollama, as it does to be read, rather than being filed
    /// without the description for good: the ingest pipeline.
    case wait
    /// Read the image without its description, and note why: `arrumatorcli extract`, which shows what is read now.
    case note
}

public struct VisionModelOptions: Sendable {
    public var model: String
    public var keepAlive: String
    public var numPredict: Int
    /// The context the model is asked with: `analysis.numCtx`, the one documents are read with, so a model that does
    /// both stays loaded once (`PipelineConfig.extractionContext`).
    public var numCtx: Int
    public var options: AnalysisConfig.LLMOptions
    /// What a model that can think is told about thinking before it describes an image, sent as the model allows
    /// (`OllamaShowResponse.think(sending:)`): `analysis.think`, as documents are read.
    public var think: OllamaThink

    public init(model: String, keepAlive: String, numPredict: Int, numCtx: Int, options: AnalysisConfig.LLMOptions, think: OllamaThink) {
        self.model = model
        self.keepAlive = keepAlive
        self.numPredict = numPredict
        self.numCtx = numCtx
        self.options = options
        self.think = think
    }
}
