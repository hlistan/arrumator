import Foundation

/// What a document's sidecar holds, as the index has it: what the model read the document as, what the vision model saw
/// in an image, and its text as it was recognised (`ArchiveRecords.renderSidecar`). What the app's card and `arrumatorcli show` show of it.
public struct DocumentText: Sendable, Codable, Hashable {
    public var id: Int64
    public var file: String
    /// What the model read it as (`DocumentAnalysis.interpretation`); nil when it said nothing of it.
    public var interpretation: String?
    /// What the vision model saw in it, in English, for an image it described (`VisualSummary.description`); nil
    /// otherwise.
    public var imageDescription: String?
    /// Its text as it was recognised, at most `extraction.maxIndexChars` characters; empty when none was.
    public var text: String
    /// How its text was recognised: from its text layer, by OCR, or both; nil before it was read, or when it has none
    /// (`ExtractedContent.recognition`).
    public var textOrigin: TextOrigin?
    /// Whether its text was cut, or not every page read.
    public var truncated: Bool
    /// Where its sidecar is, when one is there.
    public var sidecar: String?
}

extension PipelineServices {
    /// What document `docID`'s sidecar holds, as the index has it now, and where the sidecar is when it is there; nil for
    /// a document the index does not have.
    public func documentText(_ docID: Int64) async throws -> DocumentText? {
        guard let document = try await documents.document(id: docID) else { return nil }
        let content = JSON.decode(ExtractedContent.self, from: document.contentJson)
        let sidecar = ArchiveLayout(root: archive, records: config.records, watcher: config.watcher).sidecar(of: document.path)
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
        return DocumentText(id: docID, file: document.filename, interpretation: document.analysis?.interpretation,
                            imageDescription: content?.visual?.description, text: try await index.body(docID: docID) ?? "",
                            textOrigin: content?.recognition,
                            truncated: content?.isPartial ?? false, sidecar: sidecar)
    }
}
