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

/// Reads a document with the local model: its labels and the name it is filed under. Implemented by
/// `ArrumatorClassify.DocumentAnalyzer`.
public protocol DocumentAnalyzing: Sendable {
    /// `guidance` is what the model is told of the archive's labels and the user's decisions about them. Without a
    /// valid answer from the model the outcome says why, and has no labels; a model that cannot be reached or is
    /// missing throws, so the document waits.
    func analyse(_ content: ExtractedContent, guidance: LabelGuidance, settings: AppSettings, config: PipelineConfig,
                 trace: TraceContext) async throws -> AnalysisOutcome
    /// The vector the document is searched by meaning with, and the model that made it; nil when none can be made.
    func embedding(for content: ExtractedContent, senders: [String], settings: AppSettings, config: PipelineConfig,
                   trace: TraceContext) async throws -> (vector: [Float], model: String)?
}
