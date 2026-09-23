import Foundation

/// Turns a file into `ExtractedContent`. Implemented by `ArrumatorExtract.ExtractorRegistry`.
public protocol ContentExtracting: Sendable {
    func extract(_ url: URL, sha256: String, context: ExtractionContext, trace: TraceContext) async throws -> ExtractedContent
}

/// Produces L2-normalised embedding vectors.
public protocol Embedder: Sendable {
    var modelId: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// Why a document is being classified.
public enum ClassificationMode: Sendable, Hashable {
    /// A new arrival: confident learned evidence may place it without asking the model.
    case arrival
    /// Deciding a filed document again: the model always decides from the archive's logic, learned evidence only
    /// advises, and the document's own past filing is not offered as evidence.
    case rethink(documentID: Int64)
}

/// Decides where a document goes. Implemented by `ArrumatorClassify.FilingClassifier`.
public protocol DocumentClassifier: Sendable {
    func classify(_ content: ExtractedContent, taxonomy: TaxonomySnapshot, settings: AppSettings,
                  config: PipelineConfig, mode: ClassificationMode, trace: TraceContext) async throws -> ClassificationOutcome
    /// The vector the document is compared with others by, computed as filing computes it, and the model that made
    /// it; nil when no embedding can be made.
    func embedding(for content: ExtractedContent, sender: String?, settings: AppSettings, config: PipelineConfig,
                   trace: TraceContext) async throws -> (vector: [Float], model: String)?
}

/// A filed document that a rethink moved from one folder to another.
public struct PlacementMove: Sendable, Codable, Hashable {
    public var documentID: Int64
    public var fromFolderID: Int64
    public var toFolderID: Int64
    public var correspondentID: Int64?
    public var documentType: DocumentType?

    public init(documentID: Int64, fromFolderID: Int64, toFolderID: Int64, correspondentID: Int64?, documentType: DocumentType?) {
        self.documentID = documentID
        self.fromFolderID = fromFolderID
        self.toFolderID = toFolderID
        self.correspondentID = correspondentID
        self.documentType = documentType
    }
}

/// Receives filings and corrections to learn from. Implemented by `ArrumatorClassify.Learner`.
public protocol LearningSink: Sendable {
    func documentFiled(documentID: Int64, folderID: Int64, outcome: ClassificationOutcome, content: ExtractedContent,
                       confirmedByUser: Bool, trace: TraceContext) async
    func correctionRecorded(_ correction: CorrectionEvent, trace: TraceContext) async
    func documentForgotten(documentID: Int64) async
    /// Folders appeared, were renamed or removed on disk.
    func taxonomyChanged(_ changes: [TaxonomyChange], taxonomy: TaxonomySnapshot) async
    /// Periodic upkeep: filings left untouched long enough become evidence, which can strengthen or form rules.
    func settleUntouchedFilings() async
    /// A document's embedding was computed again, as after a rebuilt index: its memories take the new vector.
    func documentReembedded(documentID: Int64, vector: [Float], model: String) async
    /// A rethink moved documents and removed the folders it emptied: rules follow their documents.
    func placementsRearranged(_ moves: [PlacementMove], removedFolderIDs: Set<Int64>) async
    /// The user asked the app to forget something it learned.
    func forget(_ fact: LearnedFact) async throws
}
