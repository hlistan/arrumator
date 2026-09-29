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

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let config = job.config
        let result: ShellResult
        do {
            result = try await shell.run(Self.executable,
                                         arguments: ["-convert", "txt", "-encoding", "UTF-8", "-stdout", job.url.path],
                                         timeout: config.toolTimeout, killGrace: config.toolKillGrace,
                                         outputCap: config.toolOutputCapBytes)
        } catch {
            return .metadataOnly(kind: .textDocument, warnings: [ExtractionWarning(.toolFailed, String(describing: error))])
        }
        var metadata = Self.docx.map { job.type.conforms(to: $0) } == true
            ? OOXMLCoreProperties.metadata(of: job.url, entryCap: config.zipEntryCapBytes, prefix: "doc") : [:]
        metadata["textutil:ms"] = String(Int(result.durationMs))
        if result.timedOut {
            return .metadataOnly(kind: .textDocument,
                                 warnings: [ExtractionWarning(.timeout, "textutil exceeded \(config.toolTimeout) s")],
                                 metadata: metadata)
        }
        guard result.status == 0 else {
            let detail = "textutil exit \(result.status): " + result.stderr.prefix(config.tracePreviewChars)
            return .metadataOnly(kind: .textDocument, warnings: [ExtractionWarning(.toolFailed, detail)], metadata: metadata)
        }
        let text = String(decoding: result.stdout, as: UTF8.self)
        var draft = ExtractionDraft(kind: .textDocument, textOrigin: .textLayer, text: text)
        draft.metadata = metadata
        draft.structure = ContentStructure(paragraphCount: TextNormalizer.nonEmptyLineCount(text))
        draft.timings["tool"] = result.durationMs
        if result.stdoutTruncated {
            draft.warnings.append(ExtractionWarning(.textTruncated, "textutil output capped at \(config.toolOutputCapBytes) bytes"))
        }
        return draft
    }
}
