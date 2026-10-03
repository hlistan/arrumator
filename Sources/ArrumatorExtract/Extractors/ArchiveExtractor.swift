import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// Archives: ZIP entry listing (names and sizes, up to `archiveMaxEntries`) as text and attachments; other archive
/// formats are reported metadata-only. Nothing is ever unpacked: the listing is the ZIP's central directory, read and
/// checked against the file by `ZipDirectory`, and a ZIP whose directory does not check out, or that lists more than
/// `zipMaxEntries`, is refused.
struct ArchiveExtractor: FileExtractor {
    let name = "archive"
    let version = 2
    var supportedTypes: [UTType] { [.archive, .zip] }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        guard job.type.conforms(to: .zip) else {
            return .metadataOnly(kind: .archive, warnings: [ExtractionWarning(.unsupportedFormat, job.type.identifier)])
        }
        let directory: ZipDirectory
        do {
            directory = try ZipDirectory.read(job.url, maxEntries: job.config.zipMaxEntries)
        } catch {
            return .metadataOnly(kind: .archive, warnings: [error.warning])
        }
        let files = directory.entries.filter { $0.kind == .file && !Self.isSystemJunk($0.path) }
        let listed = files.prefix(job.config.archiveMaxEntries)
        let lines = listed.map { "\($0.path)\t\($0.uncompressedSize)" }
        var draft = ExtractionDraft(kind: .archive, textOrigin: .metadataOnly,
                                   text: (["Archive entries (\(files.count)):"] + lines).joined(separator: "\n"))
        draft.attachments = listed.map(\.path)
        draft.metadata["archive:entries"] = String(files.count)
        // What the entries declare, added up without overflow; sizes that overflow are no total at all.
        if let unpacked = ZipDirectory.sum(files.map(\.uncompressedSize)) {
            draft.metadata["archive:uncompressedBytes"] = String(unpacked)
        }
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
