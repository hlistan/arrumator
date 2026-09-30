import Foundation

/// Controlled vocabulary for the *form* of a document (paperless-ngx style), the values of its `type` label.
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
}

/// How the local model read a document, besides the labels it gave it: the name its file is to have, which model
/// read it, and why it waits for the user, if it does. Stored with the document and its trace.
public struct DocumentAnalysis: Sendable, Codable, Hashable {
    /// The file name the model chose, without extension; nil when it gave none, and the file keeps its own.
    public var fileName: String?
    /// The model that answered; nil when none did.
    public var model: String?
    /// Why the document waits for the user; empty when it does not.
    public var problems: [String]

    public init(fileName: String? = nil, model: String? = nil, problems: [String] = []) {
        self.fileName = fileName
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
