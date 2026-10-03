import ArrumatorCore
@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Audio and video: duration, creation (capture) date and common title/artist/album metadata via AVFoundation.
/// No transcription.
struct MediaExtractor: FileExtractor {
    let name = "media"
    let version = 3
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
        if let seconds = Self.wholeSeconds(duration) { metadata["media:durationSeconds"] = String(seconds) }
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
            // The capture date as written (`2024-05-20T01:30:00+0200`), the day the camera's clock showed; the moment
            // AVFoundation makes of it, in the Mac's time zone, only where it is not written so.
            let written = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierCreationDate).first
            let text = if let written { try? await written.load(.stringValue) } else { String?.none }
            draft.metadataDates = [MetadataDate(day: text.flatMap(Self.writtenDay) ?? job.calendar.day(of: date), source: .exif,
                                                label: "media capture date")]
        }
        draft.metadata = metadata
        return draft
    }

    /// The day an ISO 8601 date and time writes (`2024-05-20T01:30:00+0200`), if it is one.
    static func writtenDay(_ text: String) -> CalendarDay? {
        guard let match = isoDate.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else {
            return nil
        }
        let field = { (index: Int) in Int((text as NSString).substring(with: match.range(at: index))) }
        guard let year = field(1), let month = field(2), let day = field(3) else { return nil }
        return CalendarDay(year: year, month: month, day: day)
    }

    /// The year, month and day of an ISO 8601 date (`YYYY-MM-DD`), a time after it or not.
    private static let isoDate: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^\s*([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[T ]|$)"#)
        } catch {
            preconditionFailure("Invalid ISO date pattern: \(error)")
        }
    }()

    /// A duration in whole seconds, when it is a number an `Int` holds: the file declares it, up to `Int64.max`
    /// units of one second, which round past `Int.max` as a `Double`.
    static func wholeSeconds(_ duration: CMTime) -> Int? {
        duration.isNumeric ? Int(exactly: duration.seconds.rounded()) : nil
    }
}
