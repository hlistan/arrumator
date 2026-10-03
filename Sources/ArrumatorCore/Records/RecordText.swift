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

    static func history(_ entries: [EventEntry], month: String, in zone: TimeZone) -> String {
        var lines = ["# History \(month)", "", note, ""]
        for e in entries {
            lines.append("- \(time(e.at, in: zone)) · \(e.kind.rawValue) · \(e.summary)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func labelRules(_ entries: [LabelRuleEntry], in zone: TimeZone) -> String {
        var lines = ["# Labels", "", note, "", "| Kind | Label | Decision | Since |", "|---|---|---|---|"]
        for e in entries {
            let decision = switch e.action {
            case .merge: "written as \(e.target ?? "")"
            case .ignore: "not wanted"
            case .keepApart: "kept apart from \(e.target ?? "")"
            }
            lines.append("| \(e.kind.rawValue) | \(cell(e.value)) | \(cell(decision)) | "
                + "\(e.created.formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day())) |")
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

    /// A task's conversation: each question as a quote under when it was asked, its answer below it, then the documents
    /// it draws on and those it found, by name where the index has them, else by number.
    static func conversation(_ entries: [ConversationTurnEntry], task: String, documents: [Int64: String], in zone: TimeZone) -> String {
        func named(_ ids: [Int64]) -> String {
            ids.map { id in documents[id].map { "\($0) (\(id))" } ?? "document \(id)" }.joined(separator: "; ")
        }
        var lines = ["# \(task)", "", note]
        for e in entries {
            lines += ["", "## \(time(e.asked, in: zone))", ""]
            lines += e.question.components(separatedBy: .newlines).map { "> " + $0 }
            if let answer = e.answer { lines += ["", answer] }
            if let sources = e.sources, !sources.isEmpty { lines += ["", "Drawn from: " + named(sources)] }
            if let finding = e.finding {
                lines += ["", "Looked for “\(finding.request)”: " + (finding.problem ?? (finding.documents.isEmpty ? "nothing new" : named(finding.documents)))]
            }
            if e.state.isActive { lines += ["", "_Waiting to be answered._"] }
            if let problem = e.problem { lines += ["", "_\(e.state == .failed ? "Not answered" : "Incomplete"): \(problem)_"] }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A moment as the Mac showed it, in its time zone `zone`, with its offset from UTC ("2026-10-02T11:40:58+01:00"):
    /// read by a person, a bare UTC hour passes for their own.
    private static func time(_ date: Date, in zone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day()
            .time(includingFractionalSeconds: false).timeZone(separator: .colon))
    }

    /// A table cell: a pipe or a line break would end it.
    private static func cell(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
