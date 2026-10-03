import ArrumatorCore
import Foundation

/// Analyzer double: gives every document the labels it is set up with (by default those of an electricity bill from
/// EDP to Maria Exemplo; nil for "the model gave no valid answer", which also makes it wait for the user), or throws
/// `error`. It records an analysis step as the model's analyzer does, and remembers which files it read and what it was
/// told of the archive's labels. `during` runs while a file is read, given its name, as the app being stopped then.
public struct StubAnalyzer: DocumentAnalyzing {
    public actor Calls {
        public private(set) var files: [String] = []
        public private(set) var guidance: [LabelGuidance] = []
        func read(_ file: String, guidance: LabelGuidance) {
            files.append(file)
            self.guidance.append(guidance)
        }
    }

    public let labels: [DocumentLabel]?
    public let fileName: String?
    public let error: (any Error & Sendable)?
    public let during: (@Sendable (String) async throws -> Void)?
    public let calls = Calls()

    public init(labels: [DocumentLabel]? = StubAnalyzer.edpBill, fileName: String? = StubAnalyzer.edpFileName,
                error: (any Error & Sendable)? = nil, during: (@Sendable (String) async throws -> Void)? = nil) {
        self.labels = labels
        self.fileName = fileName
        self.error = error
        self.during = during
    }

    public func analyse(_ content: ExtractedContent, guidance: LabelGuidance, settings: AppSettings, config: PipelineConfig,
                        trace: TraceContext) async throws -> AnalysisOutcome {
        await calls.read(content.source.originalFilename, guidance: guidance)
        try await during?(content.source.originalFilename)
        if let error { throw error }
        await trace.record(.analyse, status: labels == nil ? .error : .ok, startedAt: TestTime.start, output: labels)
        let analysis = DocumentAnalysis(fileName: fileName, model: labels == nil ? nil : "stub",
                                        problems: labels == nil ? ["the model gave no valid answer"] : [])
        return AnalysisOutcome(analysis: analysis, labels: labels, embedding: Self.embedding, embeddingModel: Self.embeddingModel)
    }

    public func embedding(for content: ExtractedContent, senders: [String], settings: AppSettings, config: PipelineConfig,
                          trace: TraceContext) async throws -> (vector: [Float], model: String)? {
        (Self.embedding, Self.embeddingModel)
    }

    public static let embeddingModel = "stub-embed"
    /// What every document is embedded as.
    public static let embedding: [Float] = [1, 0, 0]
    public static let edpFileName = "2026-07-05 EDP Comercial - Fatura eletricidade julho"

    /// What an electricity bill from EDP to Maria Exemplo is labelled with.
    public static let edpBill = [
        DocumentLabel(kind: .sender, value: "EDP Comercial"),
        DocumentLabel(kind: .party, value: "Maria Exemplo"),
        DocumentLabel(kind: .type, value: "invoice"),
        DocumentLabel(kind: .topic, value: "electricity"),
        DocumentLabel(kind: .object, value: "electricity supply point PT0002000012345678"),
        DocumentLabel(kind: .reference, value: "invoice FT 2026/926804564"),
        DocumentLabel(kind: .date, value: "2026-07-05"),
        DocumentLabel(kind: .period, value: "2026-06"),
        DocumentLabel(kind: .deadline, value: "2026-07-25"),
        DocumentLabel(kind: .amount, value: "54.21 EUR"),
        DocumentLabel(kind: .jurisdiction, value: "Portugal"),
        DocumentLabel(kind: .language, value: "pt"),
    ]
}
