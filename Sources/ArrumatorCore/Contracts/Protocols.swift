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

/// The time of day and the passing of time. Everything that stamps a record, schedules work or waits takes one, so a
/// test sets the time and waits for nothing (AGENTS.md §3, determinism). `SystemTime` is the one the app runs on.
public protocol TimeSource: Sendable {
    func now() -> Date
    /// Suspends for `seconds`; throws `CancellationError` when the task is cancelled.
    func sleep(seconds: Double) async throws
}

/// The Mac's clock.
public struct SystemTime: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// Where a file the app has no more use for goes, so the user can still take it back: never deleted (AGENTS.md §4.2).
/// `SystemTrash` is the one the app runs on; `FolderTrash` keeps what it is given in a folder of its own, for a run that
/// must leave nothing outside its own folders, as `eval` and the tests.
public protocol Trashing: Sendable {
    /// Moves the file at `url` to the Trash; where it went, when that can be told.
    func trash(_ url: URL) throws -> URL?
}
