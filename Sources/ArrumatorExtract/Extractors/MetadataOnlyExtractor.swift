import ArrumatorCore
import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Fallback for unsupported or oversized files: no content, only Spotlight's title and authors when indexed.
/// The filename, dates, type and `kMDItemWhereFroms` are already on `SourceFile`.
struct MetadataOnlyExtractor: FileExtractor {
    let name = "metadata-only"
    let version = 1
    var supportedTypes: [UTType] { [] }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        draft(for: job)
    }

    func draft(for job: ExtractionJob, warnings: [ExtractionWarning] = []) -> ExtractionDraft {
        .metadataOnly(kind: .estimated(for: job.type), warnings: warnings, metadata: Self.spotlight(job.url))
    }

    private static func spotlight(_ url: URL) -> [String: String] {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return [:] }
        var metadata: [String: String] = [:]
        if let title = MDItemCopyAttribute(item, kMDItemTitle) as? String, !title.isEmpty {
            metadata["spotlight:title"] = title
        }
        if let authors = MDItemCopyAttribute(item, kMDItemAuthors) as? [String], !authors.isEmpty {
            metadata["spotlight:authors"] = authors.joined(separator: ", ")
        }
        return metadata
    }
}
