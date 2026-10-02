import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// Word processing and web formats through `/usr/bin/textutil -convert txt` (doc, docx, rtf, rtfd, odt, html,
/// webarchive), plus Dublin Core title/creator/dates from `docProps/core.xml` for docx.
struct TextutilExtractor: FileExtractor {
    let shell: ShellRunner

    let name = "textutil"
    let version = 1
    var supportedTypes: [UTType] {
        [.rtf, .rtfd, .flatRTFD, .html, .webArchive, Self.docx, Self.doc, Self.odt, Self.wordML].compactMap { $0 }
    }

    private static let docx = UTType("org.openxmlformats.wordprocessingml.document")
    private static let doc = UTType("com.microsoft.word.doc")
    private static let odt = UTType("org.oasis-open.opendocument.text")
    private static let wordML = UTType("com.microsoft.word.wordml")
    private static let executable = URL(fileURLWithPath: "/usr/bin/textutil")

    /// What `textutil` is run with: `file` converted to UTF-8 plain text on standard output. `-noload` ("do not load
    /// subsidiary resources", `man textutil`) keeps an HTML page or web archive from fetching the images, style sheets
    /// and frames it refers to, so reading one never reaches the network (AGENTS.md §4.1), whatever textutil's default.
    static func arguments(for file: URL) -> [String] {
        ["-convert", "txt", "-noload", "-encoding", "UTF-8", "-stdout", file.path]
    }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let config = job.config
        let result: ShellResult
        do {
            result = try await shell.run(Self.executable, arguments: Self.arguments(for: job.url),
                                         timeout: config.toolTimeout, killGrace: config.toolKillGrace,
                                         outputCap: config.toolOutputCapBytes)
        } catch {
            return .metadataOnly(kind: .textDocument, warnings: [ExtractionWarning(.toolFailed, String(describing: error))])
        }
        let core = Self.docx.map { job.type.conforms(to: $0) } == true
            ? OOXMLCoreProperties.metadata(of: job.url, config: config, prefix: "doc") : (metadata: [:], warnings: [])
        var metadata = core.metadata
        metadata["textutil:ms"] = String(Int(result.durationMs))
        if result.timedOut {
            return .metadataOnly(kind: .textDocument,
                                 warnings: [ExtractionWarning(.timeout, "textutil exceeded \(config.toolTimeout) s")]
                                     + core.warnings,
                                 metadata: metadata)
        }
        guard result.status == 0 else {
            let detail = "textutil exit \(result.status): " + result.stderr.prefix(config.tracePreviewChars)
            return .metadataOnly(kind: .textDocument, warnings: [ExtractionWarning(.toolFailed, detail)] + core.warnings,
                                 metadata: metadata)
        }
        let text = String(decoding: result.stdout, as: UTF8.self)
        var draft = ExtractionDraft(kind: .textDocument, textOrigin: .textLayer, text: text)
        draft.metadata = metadata
        draft.warnings = core.warnings
        draft.structure = ContentStructure(paragraphCount: TextNormalizer.nonEmptyLineCount(text))
        draft.timings["tool"] = result.durationMs
        if result.stdoutTruncated {
            draft.warnings.append(ExtractionWarning(.textTruncated, "textutil output capped at \(config.toolOutputCapBytes) bytes"))
        }
        return draft
    }
}
