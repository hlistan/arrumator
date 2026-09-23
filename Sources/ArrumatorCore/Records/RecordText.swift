import Foundation

/// The Markdown below each record file's data, written for people browsing the archive. The app never reads it back:
/// the front matter above it is the record.
enum RecordText {
    static let note = "Written by Arrumator. The data at the top of this file is the record the app reads; "
        + "it rebuilds its index from it, so a correction made there is picked up. This list is regenerated."

    static func documents(_ entries: [DocumentEntry], in directory: URL) -> String {
        var lines = ["# \(directory.lastPathComponent)", "", note, "", "| File | Date | From | Type | Decided by |", "|---|---|---|---|---|"]
        for e in entries {
            lines.append("| \(cell(e.file)) | \(cell(e.date)) | \(cell(e.sender)) | \(cell(e.documentType)) | \(cell(decider(e))) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func senders(_ entries: [Correspondent]) -> String {
        var lines = ["# Senders", "", note, ""]
        for s in entries {
            var parts = ["**\(s.canonicalName)**"]
            if !s.aliases.isEmpty { parts.append("also " + s.aliases.joined(separator: ", ")) }
            if !s.stableKeys.isEmpty { parts.append("identifiers " + s.stableKeys.joined(separator: ", ")) }
            if let folder = s.defaultFolderCode { parts.append("usually \(folder)") }
            lines.append("- " + parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func rules(_ entries: [FilingRule]) -> String {
        var lines = ["# Rules", "", note, ""]
        for r in entries {
            let state = r.forgotten ? "forgotten" : (r.enabled ? "on" : "off")
            lines.append("- **\(r.name)** · \(state) · \(r.support) agreeing, \(r.contradictions) against, used \(r.hits) times")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func corrections(_ entries: [CorrectionEntry]) -> String {
        var lines = ["# Corrections", "", note, ""]
        for c in entries {
            let move = c.fromFolder == c.toFolder ? "confirmed in \(c.toFolder ?? "-")" : "\(c.fromFolder ?? "-") → \(c.toFolder ?? "-")"
            lines.append("- \(day(c.at)) · \(c.source) · \(c.toName ?? c.fromName ?? "document \(c.document)") · \(move)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func memories(_ entries: [MemoryEntry]) -> String {
        var lines = ["# Filing memories", "", note, ""]
        for m in entries {
            lines.append("- \(m.folder) · \(m.summary) · counts \(m.weight) (\(m.source))\(m.orphaned ? " · folder gone" : "")")
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

    private static func decider(_ e: DocumentEntry) -> String? {
        guard let by = e.decidedBy.flatMap(DecidedBy.init(rawValue:)) else { return nil }
        let name = StatsService.decisionSource(for: by).name
        guard by == .llm, let confidence = e.confidence else { return name }
        return "\(name), \(Format.percent(confidence)) sure"
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    /// A table cell: a pipe or a line break would end it.
    private static func cell(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
