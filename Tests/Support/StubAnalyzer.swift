import ArrumatorCore
import Foundation

/// Analyzer double: reads every document as the same one, an electricity bill from EDP to Maria Exemplo, gives it the
/// labels it is set up with (nil for "the model gave no valid answer", which also makes it wait for the user), or
/// throws `error`. It records an analysis step as the model's analyzer does, and remembers which files it read.
public struct StubAnalyzer: DocumentAnalyzing {
    public actor Calls {
        public private(set) var files: [String] = []
        func read(_ file: String) { files.append(file) }
    }

    public let labels: [DocumentLabel]?
    public let fileName: String?
    public let error: (any Error & Sendable)?
    public let calls = Calls()

    public init(labels: [DocumentLabel]? = StubAnalyzer.edpBill, fileName: String? = StubAnalyzer.edpFileName,
                error: (any Error & Sendable)? = nil) {
        self.labels = labels
        self.fileName = fileName
        self.error = error
    }

    public func analyse(_ content: ExtractedContent, settings: AppSettings, config: PipelineConfig,
                        trace: TraceContext) async throws -> AnalysisOutcome {
        await calls.read(content.source.originalFilename)
        if let error { throw error }
        await trace.record(.analyse, status: labels == nil ? .error : .ok, startedAt: Date(), output: labels)
        let analysis = DocumentAnalysis(correspondent: "EDP Comercial", documentType: .invoice, documentDate: "2026-07-05",
                                        dateSource: .label, title: "Fatura eletricidade julho", fileName: fileName, language: "pt",
                                        model: labels == nil ? nil : "stub", problems: labels == nil ? ["the model gave no valid answer"] : [])
        return AnalysisOutcome(analysis: analysis, labels: labels, embedding: [1, 0, 0], embeddingModel: Self.embeddingModel)
    }

    public func embedding(for content: ExtractedContent, sender: String?, settings: AppSettings, config: PipelineConfig,
                          trace: TraceContext) async throws -> (vector: [Float], model: String)? {
        ([1, 0, 0], Self.embeddingModel)
    }

    public static let embeddingModel = "stub-embed"
    public static let edpFileName = "2026-07-05 EDP Comercial - Fatura eletricidade julho"

    /// What an electricity bill from EDP to Maria Exemplo is labelled with.
    public static let edpBill = [
        DocumentLabel(kind: .subject, value: "Maria Exemplo"),
        DocumentLabel(kind: .object, value: "electricity supply point PT0002000012345678"),
        DocumentLabel(kind: .jurisdiction, value: "Portugal"),
        DocumentLabel(kind: .language, value: "pt"),
    ]
}
