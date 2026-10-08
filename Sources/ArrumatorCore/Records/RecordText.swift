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
            case .add: "added"
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

    static let sidecarNote = "Written by Arrumator beside the document it is named after: what the model read it as, and its text as it "
        + "was recognised. It is written again whenever either changes, and a copy changed by hand goes to the Trash then."
    /// The headings of a sidecar's parts.
    static let interpretationHeading = "What it is"
    static let imageHeading = "What it shows"
    static let textHeading = "Recognised text"

    /// A document's sidecar below its data: its name, what the model read it as, what the vision model saw in an image
    /// (`imageDescription`, in English, as it describes every image), and its text as it was recognised, in a fence that
    /// keeps it as it is. Nothing in it becomes active where Markdown is shown, as the models' words and the document's are
    /// untrusted (AGENTS.md §4.5): what would make a link, an image or HTML of the name, the interpretation and the image's
    /// description is escaped (`inert`), and the text is code.
    static func sidecar(file: String, interpretation: String?, imageDescription: String?, text: String) -> String {
        var lines = ["# \(inert(file))", "", sidecarNote, "", "## \(interpretationHeading)", ""]
        lines.append(interpretation.map(inert) ?? "_The model has not said what it is._")
        if let imageDescription { lines += ["", "## \(imageHeading)", "", inert(imageDescription)] }
        lines += ["", "## \(textHeading)", ""]
        if text.isEmpty {
            lines.append("_No text was recognised in it._")
        } else {
            let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: text) + 1))
            lines += [fence + "text", text, fence]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The characters that open a link, an image, an autolink or HTML in Markdown (CommonMark 0.31, §§ 6.3–6.6), and a
    /// code span or fence (§§ 4.5, 6.1), which one line that begins with three of them would open, and a fence in the text
    /// below close, leaving what follows it to be read as Markdown.
    static let active: Set<Character> = ["\\", "[", "]", "<", ">", "`", "~"]

    /// `text` with each character that would make it active in Markdown escaped by a backslash, as CommonMark escapes any
    /// ASCII punctuation (§ 2.4), so it shows as written: those that open a link, an image or HTML (`active`), and the
    /// colon of a scheme's `://` and the dot after `www`, by which GitHub's Markdown, and Apple's, link a web address
    /// written alone (GFM 0.29, § 6.9). Nothing then loads by itself or hides where it goes. An e-mail address, which they
    /// link however it is escaped, shows as it is written, and opens nothing but a message to it.
    static func inert(_ text: String) -> String {
        String(text.flatMap { active.contains($0) ? ["\\", $0] : [$0] })
            .replacingOccurrences(of: "://", with: "\\://")
            .replacing(#/(?i)\b(www)\./#) { "\($0.output.1)\\." }
    }

    /// The longest run of `character` in `text`, which a code fence must be longer than to hold it (CommonMark 0.31, § 4.5).
    static func longestRun(of character: Character, in text: String) -> Int {
        var (longest, run) = (0, 0)
        for c in text {
            run = c == character ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
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
