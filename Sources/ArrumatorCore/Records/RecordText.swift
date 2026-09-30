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
            let labels = e.labels ?? []
            let others = labels.filter { ![.date, .sender, .type].contains($0.kind) }.map(\.value)
            lines.append("| \(cell(e.file)) | \(cell(labels.values(.date).first)) | \(cell(labels.values(.sender).joined(separator: ", "))) | "
                + "\(cell(labels.values(.type).first)) | \(cell(others.joined(separator: ", "))) | \(e.status.rawValue) |")
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

    static func labelRules(_ entries: [LabelRuleEntry]) -> String {
        var lines = ["# Labels", "", note, "", "| Kind | Label | Decision | Since |", "|---|---|---|---|"]
        for e in entries {
            let decision = switch e.action {
            case .merge: "written as \(e.target ?? "")"
            case .ignore: "not wanted"
            case .keepApart: "kept apart from \(e.target ?? "")"
            }
            lines.append("| \(e.kind.rawValue) | \(cell(e.value)) | \(cell(decision)) | "
                + "\(e.created.formatted(.iso8601.year().month().day())) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func searchTasks(_ entries: [SearchTaskEntry]) -> String {
        var lines = ["# Search tasks", "", note, "", "| # | Task | Asked | State | Documents | Exports |", "|---|---|---|---|---|---|"]
        for e in entries {
            let name = [e.title, e.plan?.title].compactMap { $0 }.first { !$0.isEmpty } ?? e.prompt
            lines.append("| \(e.id) | \(cell(name)) | \(cell(e.prompt)) | \(e.state.rawValue) | "
                + "\(e.documents.filter { $0.inclusion != .removed }.count) | \(cell(e.exports.map(\.path).joined(separator: ", "))) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A table cell: a pipe or a line break would end it.
    private static func cell(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
