import ArrumatorCore
@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Audio and video: duration, creation (capture) date and common title/artist/album metadata via AVFoundation.
/// No transcription.
struct MediaExtractor: FileExtractor {
    let name = "media"
    let version = 1
    var supportedTypes: [UTType] { [.audiovisualContent] }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let asset = AVURLAsset(url: job.url)
        let duration: CMTime
        let common: [AVMetadataItem]
        let creation: AVMetadataItem?
        do {
            (duration, common, creation) = try await asset.load(.duration, .commonMetadata, .creationDate)
        } catch {
            return .metadataOnly(kind: .media, warnings: [ExtractionWarning(.corrupted, error.localizedDescription)])
        }
        var metadata: [String: String] = [:]
        if duration.isNumeric { metadata["media:durationSeconds"] = String(Int(duration.seconds.rounded())) }
        var lines: [String] = []
        let fields: [(AVMetadataIdentifier, String, String)] = [
            (.commonIdentifierTitle, "title", "Title"), (.commonIdentifierArtist, "artist", "Artist"),
            (.commonIdentifierAlbumName, "album", "Album"), (.commonIdentifierCreator, "creator", "Creator"),
        ]
        for (identifier, name, label) in fields {
            guard let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: identifier).first,
                  let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
            metadata["media:\(name)"] = value
            lines.append("\(label): \(value)")
        }
        var draft = ExtractionDraft(kind: .media, textOrigin: .metadataOnly, text: lines.joined(separator: "\n"))
        if let creation, let date = try? await creation.load(.dateValue) {
            metadata["media:creationDate"] = date.formatted(.iso8601)
            draft.metadataDates = [MetadataDate(day: CalendarDay(date: date, calendar: .current), source: .exif,
                                                label: "media capture date")]
        }
        draft.metadata = metadata
        return draft
    }
}
