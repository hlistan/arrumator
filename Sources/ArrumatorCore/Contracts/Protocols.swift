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

/// Reads a document with the local model: what it is, its labels and the name it is filed under. Implemented by
/// `ArrumatorClassify.DocumentAnalyzer`.
public protocol DocumentAnalyzing: Sendable {
    /// Without a valid answer from the model the outcome says why, and has no labels; a model that cannot be reached
    /// or is missing throws, so the document waits.
    func analyse(_ content: ExtractedContent, settings: AppSettings, config: PipelineConfig,
                 trace: TraceContext) async throws -> AnalysisOutcome
    /// The vector the document is searched by meaning with, and the model that made it; nil when none can be made.
    func embedding(for content: ExtractedContent, sender: String?, settings: AppSettings, config: PipelineConfig,
                   trace: TraceContext) async throws -> (vector: [Float], model: String)?
}

/// Learns who documents come from. Implemented by `ArrumatorClassify.SenderLearner`.
public protocol LearningSink: Sendable {
    /// A document was analysed and filed: it is linked to its sender, and what identifies the sender is learned.
    func documentFiled(documentID: Int64, analysis: DocumentAnalysis, content: ExtractedContent, trace: TraceContext) async
    /// The user named a document's sender `to` where the model read `from`: `from` becomes another name for `to`.
    func senderRenamed(documentID: Int64, from: String, to: String) async
    /// A filing was undone: what it taught about its sender is learned again without it.
    func documentForgotten(documentID: Int64) async
}
