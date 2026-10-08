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

/// How the local model read a document, besides the labels it gave it: the name its file is to have, what the
/// document is in the model's words, which model read it, and why it waits for the user, if it does. Stored with the
/// document and its trace.
public struct DocumentAnalysis: Sendable, Codable, Hashable {
    /// The file name the reading gave, without extension, made of the labels kept and the model's title
    /// (`FilenameBuilder.made`), or the name the user gave; nil when there is none, and the file keeps its own.
    public var fileName: String?
    /// What the document is and what it says, in a few sentences in its own language, as the model read it; for an image,
    /// what it shows. Nil when the model gave none, or when the document waits for the user, as what the model read of
    /// it is then in doubt; absent from what was read before there were interpretations.
    public var interpretation: String?
    /// The model that answered; nil when none did.
    public var model: String?
    /// Why the document waits for the user; empty when it does not.
    public var problems: [String]

    public init(fileName: String? = nil, interpretation: String? = nil, model: String? = nil, problems: [String] = []) {
        self.fileName = fileName
        self.interpretation = interpretation
        self.model = model
        self.problems = problems
    }

    /// The problems the reading names, as `problems` holds them and the app tells them apart.
    public enum Problem {
        public static let noAnswer = "the model gave no valid answer"
        public static let encrypted = "encrypted"
        public static let corrupted = "corrupted"
        public static let noText = "no text could be read"
        /// A kind of file no extractor reads (`WarningCode.unsupportedFormat`), whose name alone is known: no blank scan,
        /// which reading again cannot change.
        public static let unreadableFormat = "a kind of file Arrumator cannot read"
    }

    /// Why a document read from `content` waits for the user, in the order the card lists them: the model gave no valid
    /// answer (`answered` false), the file is encrypted or damaged, and nothing was read of it, either as it is of a kind
    /// no extractor reads or as it holds no text and no image description, such as a blank scan. Empty when it does not
    /// wait. Decided here, for every reader of documents alike.
    public static func problems(answered: Bool, content: ExtractedContent) -> [String] {
        var problems: [String] = []
        if !answered { problems.append(Problem.noAnswer) }
        if content.hasWarning(.encrypted) { problems.append(Problem.encrypted) }
        if content.hasWarning(.corrupted) { problems.append(Problem.corrupted) }
        if content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && content.visual == nil {
            problems.append(content.hasWarning(.unsupportedFormat) ? Problem.unreadableFormat : Problem.noText)
        }
        return problems
    }

    /// `problems` as a person reads them, joined: an encrypted or damaged file said so, the others as they are. `problems`
    /// keeps each as the identifier the app tells them apart by (`Problem`), so what is stored never changes with the words.
    public static func said(_ problems: [String]) -> String {
        problems.map { problem in
            switch problem {
            case Problem.encrypted: "the file is encrypted"
            case Problem.corrupted: "the file is damaged"
            default: problem
            }
        }.joined(separator: "; ")
    }

    /// The document had no text to give the model, which saw only its name and format.
    public var hadNoText: Bool { problems.contains(Problem.noText) }

    /// The document is of a kind of file Arrumator cannot read, so the model saw only its name.
    public var isUnreadableFormat: Bool { problems.contains(Problem.unreadableFormat) }
}

/// Output of the analysis stage: the analysis, the labels (nil without a valid answer), the title the model gave, and
/// the document's embedding for search by meaning.
public struct AnalysisOutcome: Sendable, Codable {
    public var analysis: DocumentAnalysis
    public var labels: [DocumentLabel]?
    /// The title the model gave a document that does not wait for the user, which the file name is made of once the
    /// user's rules have kept its labels (`PipelineServices.read`). Never stored: the job carries the name made of it.
    public var title: String?
    public var embedding: [Float]?
    public var embeddingModel: String?

    public init(analysis: DocumentAnalysis, labels: [DocumentLabel]?, title: String? = nil, embedding: [Float]? = nil,
                embeddingModel: String? = nil) {
        self.analysis = analysis
        self.labels = labels
        self.title = title
        self.embedding = embedding
        self.embeddingModel = embeddingModel
    }

    /// What a job's payload holds of it: the title is not, as the name made of it is in `analysis`.
    private enum CodingKeys: String, CodingKey { case analysis, labels, embedding, embeddingModel }
}
