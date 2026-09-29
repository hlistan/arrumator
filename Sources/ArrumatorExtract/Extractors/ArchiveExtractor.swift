import ArrumatorCore
import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

/// Archives: ZIP entry listing (names and sizes, up to `archiveMaxEntries`) as text and attachments; other archive
/// formats are reported metadata-only. Nothing is ever unpacked.
struct ArchiveExtractor: FileExtractor {
    let name = "archive"
    let version = 1
    var supportedTypes: [UTType] { [.archive, .zip] }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        guard job.type.conforms(to: .zip) else {
            return .metadataOnly(kind: .archive, warnings: [ExtractionWarning(.unsupportedFormat, job.type.identifier)])
        }
        let zip: ZipReader
        do {
            zip = try ZipReader(url: job.url, entryCap: job.config.zipEntryCapBytes)
        } catch {
            return .metadataOnly(kind: .archive, warnings: [ExtractionWarning(.corrupted, error.description)])
        }
        let files = zip.entries.filter { $0.type == .file && !Self.isSystemJunk($0.path) }
        let listed = files.prefix(job.config.archiveMaxEntries)
        let lines = listed.map { "\($0.path)\t\($0.uncompressedSize)" }
        var draft = ExtractionDraft(kind: .archive, textOrigin: .metadataOnly,
                                   text: (["Archive entries (\(files.count)):"] + lines).joined(separator: "\n"))
        draft.attachments = listed.map(\.path)
        draft.metadata["archive:entries"] = String(files.count)
        draft.metadata["archive:uncompressedBytes"] = String(files.reduce(UInt64(0)) { $0 + $1.uncompressedSize })
        if files.count > listed.count {
            draft.warnings.append(ExtractionWarning(.textTruncated, "listed \(listed.count) of \(files.count) entries"))
        }
        return draft
    }

    /// Finder resource forks and metadata that say nothing about the content.
    private static func isSystemJunk(_ path: String) -> Bool {
        path.hasPrefix("__MACOSX/") || path.hasSuffix(".DS_Store")
    }
}
