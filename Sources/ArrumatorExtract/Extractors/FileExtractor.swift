import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// One file-format family. Adding a format means adding one conforming type and listing it in `ExtractorRegistry.init`;
/// nothing else changes.
protocol FileExtractor: Sendable {
    /// Stable identifier recorded in `ExtractedContent.extractorName` and traces.
    var name: String { get }
    /// Bumped whenever the output for the same input changes, so stored content can be re-extracted.
    var version: Int { get }
    /// Types handled by this extractor. The registry prefers an exact match, then the most specific conformance.
    var supportedTypes: [UTType] { get }
    /// Extracts content. Soft problems become warnings on the draft; only `ExtractionError` and
    /// `CancellationError` are thrown.
    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft
}

/// Everything a per-type extractor needs to process one file.
struct ExtractionJob: Sendable {
    let url: URL
    let source: SourceFile
    let type: UTType
    let context: ExtractionContext
    let trace: TraceContext
    /// What deadlines are measured by.
    let time: any TimeSource

    var config: ExtractionConfig { context.config }

    /// The first `cap` bytes of the file, and whether it goes on past them; a file that cannot be read fails the stage.
    func head(upTo cap: Int) throws -> (data: Data, truncated: Bool) {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: cap) ?? Data()
        } catch {
            throw ExtractionError.fileUnreadable(path: url.path, underlying: error.localizedDescription)
        }
        return (data, source.byteSize > Int64(data.count))
    }
}

extension ExtractionWarning {
    /// Only the first `read` bytes of a file of `size` were read.
    static func headRead(_ read: Int, of size: Int64) -> ExtractionWarning {
        ExtractionWarning(.textTruncated, "read the first \(read) of \(size) bytes")
    }
}

/// What a per-type extractor found. The registry normalises and caps the text, then adds language and entities.
struct ExtractionDraft: Sendable {
    var kind: ContentKind
    var textOrigin: TextOrigin
    var text = ""
    /// Length (UTF-16 units) of the first page's text, for the "first portion of page 1" date heuristic.
    var firstPageLength: Int?
    var pageCount: Int?
    var pagesOCRed: [Int] = []
    var ocr: OCRStats?
    var structure: ContentStructure?
    var metadata: [String: String] = [:]
    var metadataDates: [MetadataDate] = []
    var visual: VisualSummary?
    var attachments: [String] = []
    var warnings: [ExtractionWarning] = []
    /// Stage durations in milliseconds.
    var timings: [String: Double] = [:]

    init(kind: ContentKind, textOrigin: TextOrigin, text: String = "") {
        self.kind = kind
        self.textOrigin = textOrigin
        self.text = text
    }

    /// A draft carrying no content, only the reason and whatever metadata is known.
    static func metadataOnly(kind: ContentKind, warnings: [ExtractionWarning],
                             metadata: [String: String] = [:]) -> ExtractionDraft {
        var draft = ExtractionDraft(kind: kind, textOrigin: .metadataOnly)
        draft.warnings = warnings
        draft.metadata = metadata
        return draft
    }
}

extension ContentKind {
    /// Best guess of the content kind from the type alone, used when the content itself could not be read.
    /// PDFs stay `.unknown`: whether they are text or scans is only known after reading them.
    static func estimated(for type: UTType) -> ContentKind {
        if type.conforms(to: .pdf) { return .unknown }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audiovisualContent) { return .media }
        if type.conforms(to: .emailMessage) { return .email }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .presentation) { return .presentation }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .textDocument }
        return .unknown
    }
}

extension Date {
    /// Milliseconds elapsed since `self`.
    /// Durations report how long the Mac worked, which only its own clock can tell.
    var elapsedMs: Double { milliseconds(until: Date()) }
}
