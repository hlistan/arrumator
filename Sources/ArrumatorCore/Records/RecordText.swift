import Foundation

/// The Markdown below each record file's data, written for people browsing the archive. The app never reads it back:
/// the front matter above it is the record.
enum RecordText {
    static let note = "Written by Arrumator. The data at the top of this file is the record the app reads; "
        + "it rebuilds its index from it, so a correction made there is picked up. This list is regenerated."

    static func documents(_ entries: [DocumentEntry], in directory: URL) -> String {
        var lines = ["# \(directory.lastPathComponent)", "", note, "",
                     "| File | Date | From | Type | Labels | Status |", "|---|---|---|---|---|---|"]
        for e in entries {
            lines.append("| \(cell(e.file)) | \(cell(e.date)) | \(cell(e.sender)) | \(cell(e.documentType)) | "
                + "\(cell(e.labels?.map(\.value).joined(separator: ", "))) | \(e.status.rawValue) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func senders(_ entries: [Correspondent]) -> String {
        var lines = ["# Senders", "", note, ""]
        for s in entries {
            var parts = ["**\(s.canonicalName)**"]
            if !s.aliases.isEmpty { parts.append("also " + s.aliases.joined(separator: ", ")) }
            if !s.stableKeys.isEmpty { parts.append("identifiers " + s.stableKeys.joined(separator: ", ")) }
            lines.append("- " + parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func history(_ entries: [EventEntry], month: String) -> String {
        var lines = ["# History \(month)", "", note, ""]
        for e in entries {
            lines.append("- \(e.at.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))) · \(e.kind.rawValue) · \(e.summary)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A table cell: a pipe or a line break would end it.
    private static func cell(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
