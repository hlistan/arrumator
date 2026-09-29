import Foundation

/// Controlled vocabulary for the *form* of a document (paperless-ngx style). What it is about lives in its labels.
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

/// What a document is and what it is to be called, as the local model read it; its labels are kept beside it.
/// Produced by the analyzer, stored with the document and its trace, and corrected by the user on its card.
public struct DocumentAnalysis: Sendable, Codable, Hashable {
    public var correspondent: String?
    public var correspondentID: Int64?
    public var documentType: DocumentType
    /// `YYYY-MM-DD`, `YYYY-MM` or `YYYY`.
    public var documentDate: String?
    public var dateSource: DateSource
    /// Fiscal or reporting year when it differs from the document date (tax returns, annual statements).
    public var periodYear: Int?
    public var title: String
    /// The file name the model chose, without extension; nil when it gave none, and the file keeps its own.
    public var fileName: String?
    public var language: String
    /// The model that answered; nil when none did.
    public var model: String?
    /// Why the document waits for the user; empty when it does not.
    public var problems: [String]

    public init(correspondent: String? = nil, correspondentID: Int64? = nil, documentType: DocumentType = .other,
                documentDate: String? = nil, dateSource: DateSource = .none, periodYear: Int? = nil, title: String,
                fileName: String? = nil, language: String = "und", model: String? = nil, problems: [String] = []) {
        self.correspondent = correspondent
        self.correspondentID = correspondentID
        self.documentType = documentType
        self.documentDate = documentDate
        self.dateSource = dateSource
        self.periodYear = periodYear
        self.title = title
        self.fileName = fileName
        self.language = language
        self.model = model
        self.problems = problems
    }
}

/// Output of the analysis stage: the analysis, the labels (nil without a valid answer), and the document's embedding
/// for search by meaning.
public struct AnalysisOutcome: Sendable, Codable {
    public var analysis: DocumentAnalysis
    public var labels: [DocumentLabel]?
    public var embedding: [Float]?
    public var embeddingModel: String?

    public init(analysis: DocumentAnalysis, labels: [DocumentLabel]?, embedding: [Float]? = nil, embeddingModel: String? = nil) {
        self.analysis = analysis
        self.labels = labels
        self.embedding = embedding
        self.embeddingModel = embeddingModel
    }
}
