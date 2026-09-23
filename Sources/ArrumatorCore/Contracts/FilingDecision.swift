import Foundation

/// Controlled vocabulary for the *form* of a document (paperless-ngx style). Topic lives in the folder.
public enum DocumentType: String, Sendable, Codable, CaseIterable {
    case idDocument = "id-document"
    case certificate, attestation, contract, invoice, receipt, statement
    case taxReturn = "tax-return"
    case taxAssessment = "tax-assessment"
    case payslip, letter, application, policy
    case medicalReport = "medical-report"
    case prescription, ticket, license, manual, quote, legal, other

    /// English Title Case label, for people.
    public var label: String {
        switch self {
        case .idDocument: "ID Document"
        default: rawValue.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    public init(lenient raw: String) {
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        self = DocumentType(rawValue: normalized) ?? .other
    }
}

public enum Band: String, Sendable, Codable, CaseIterable {
    /// File automatically.
    case auto
    /// File, but flag for a later glance.
    case check
    /// Hold in Needs review until the user decides.
    case review
}

public enum DecidedBy: String, Sendable, Codable {
    case rule, llm, knnOnly, review, dummy, user
}

public struct Thresholds: Sendable, Codable, Hashable {
    public var auto: Double
    public var review: Double
    public init(auto: Double, review: Double) {
        self.auto = auto
        self.review = review
    }
    public func band(for score: Double) -> Band {
        score >= auto ? .auto : (score >= review ? .check : .review)
    }
}

public struct ConfidenceReport: Sendable, Codable, Hashable {
    public var llm: Double?
    public var knnAgreement: Double?
    public var simAgreement: Double?
    public var ruleHit: Int64?
    public var modifiers: [String: Double]
    public var final: Double
    public var band: Band
    public var thresholds: Thresholds

    public init(llm: Double? = nil, knnAgreement: Double? = nil, simAgreement: Double? = nil, ruleHit: Int64? = nil,
                modifiers: [String: Double] = [:], final: Double, band: Band, thresholds: Thresholds) {
        self.llm = llm
        self.knnAgreement = knnAgreement
        self.simAgreement = simAgreement
        self.ruleHit = ruleHit
        self.modifiers = modifiers
        self.final = final
        self.band = band
        self.thresholds = thresholds
    }
}

public struct FolderAlternative: Sendable, Codable, Hashable {
    public var code: String
    public var score: Double
    public init(code: String, score: Double) {
        self.code = code
        self.score = score
    }
}

/// A folder to create on demand, as proposed by the model or described by the user.
public struct FolderSpec: Sendable, Codable, Hashable {
    /// Existing area code, or nil to create `newArea`.
    public var areaCode: String?
    public var newAreaName: String?
    public var newAreaDescription: String?
    public var name: String
    public var description: String
    public var yearSubfolders: Bool
    public var yearRule: YearRule?

    public init(areaCode: String?, newAreaName: String?, newAreaDescription: String?, name: String, description: String,
                yearSubfolders: Bool, yearRule: YearRule?) {
        self.areaCode = areaCode
        self.newAreaName = newAreaName
        self.newAreaDescription = newAreaDescription
        self.name = name
        self.description = description
        self.yearSubfolders = yearSubfolders
        self.yearRule = yearRule
    }
}

/// Where a document should go and what it is. Produced by the classifier, stored with the document and trace.
public struct FilingDecision: Sendable, Codable, Hashable {
    /// Target category code; `nil` means "hold for review".
    public var folderCode: String?
    /// A folder the model wants created because no existing one fits.
    public var proposedNewFolder: FolderSpec?
    public var alternatives: [FolderAlternative]
    public var correspondent: String?
    public var correspondentID: Int64?
    public var documentType: DocumentType
    /// `YYYY-MM-DD`, `YYYY-MM` or `YYYY`.
    public var documentDate: String?
    public var dateSource: DateSource
    /// Fiscal / reporting year when it differs from the document date (tax returns, annual statements).
    public var periodYear: Int?
    public var title: String
    /// File name (without extension) chosen by the model; nil when the document was placed by learned evidence.
    public var fileName: String?
    public var tags: [String]
    public var language: String
    public var confidence: ConfidenceReport
    public var decidedBy: DecidedBy
    public var rationale: String
    public var modelInfo: String?
    public var reviewReasons: [String]

    public init(folderCode: String?, proposedNewFolder: FolderSpec? = nil, alternatives: [FolderAlternative] = [],
                correspondent: String? = nil, correspondentID: Int64? = nil, documentType: DocumentType = .other,
                documentDate: String? = nil, dateSource: DateSource = .none, periodYear: Int? = nil, title: String,
                fileName: String? = nil, tags: [String] = [], language: String = "und", confidence: ConfidenceReport, decidedBy: DecidedBy,
                rationale: String, modelInfo: String? = nil, reviewReasons: [String] = []) {
        self.folderCode = folderCode
        self.proposedNewFolder = proposedNewFolder
        self.alternatives = alternatives
        self.correspondent = correspondent
        self.correspondentID = correspondentID
        self.documentType = documentType
        self.documentDate = documentDate
        self.dateSource = dateSource
        self.periodYear = periodYear
        self.title = title
        self.fileName = fileName
        self.tags = tags
        self.language = language
        self.confidence = confidence
        self.decidedBy = decidedBy
        self.rationale = rationale
        self.modelInfo = modelInfo
        self.reviewReasons = reviewReasons
    }

    public var band: Band { confidence.band }
    public var year: Int? {
        guard let documentDate, documentDate.count >= 4 else { return nil }
        return Int(documentDate.prefix(4))
    }
}

/// Output of the classification stage, including the document embedding reused for indexing and memories.
public struct ClassificationOutcome: Sendable, Codable {
    public var decision: FilingDecision
    public var embedding: [Float]?
    public var embeddingModel: String?
    public init(decision: FilingDecision, embedding: [Float]? = nil, embeddingModel: String? = nil) {
        self.decision = decision
        self.embedding = embedding
        self.embeddingModel = embeddingModel
    }
}
