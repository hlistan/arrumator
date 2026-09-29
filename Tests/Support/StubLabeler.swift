import ArrumatorCore
import Foundation

/// Labeler double: gives every document the same labels (nil for "the model gave no valid answer"), or throws `error`,
/// records a labelling step as the model's labeler does, and remembers which files it was asked about.
public struct StubLabeler: DocumentLabeler {
    public actor Calls {
        public private(set) var files: [String] = []
        func asked(about file: String) { files.append(file) }
    }

    public let labels: [DocumentLabel]?
    public let error: (any Error & Sendable)?
    public let calls = Calls()

    public init(labels: [DocumentLabel]? = StubLabeler.edpBill, error: (any Error & Sendable)? = nil) {
        self.labels = labels
        self.error = error
    }

    public func labels(for content: ExtractedContent, settings: AppSettings, config: PipelineConfig,
                       trace: TraceContext) async throws -> [DocumentLabel]? {
        await calls.asked(about: content.source.originalFilename)
        if let error { throw error }
        await trace.record(.label, status: labels == nil ? .error : .ok, startedAt: Date(), output: labels)
        return labels
    }

    /// What an electricity bill from EDP to Maria Exemplo is labelled with.
    public static let edpBill = [
        DocumentLabel(kind: .subject, value: "Maria Exemplo"),
        DocumentLabel(kind: .object, value: "electricity supply point PT0002000012345678"),
        DocumentLabel(kind: .jurisdiction, value: "Portugal"),
        DocumentLabel(kind: .language, value: "pt"),
    ]
}
