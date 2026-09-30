import AppKit
import ArrumatorCore
import SwiftUI

/// The visual language, after Things: one quiet list per page under a large title, rows without separators, and an
/// item that opens in place as a card. Colour is kept for the few marks that carry meaning.
enum Style {
    static let pageMaxWidth: CGFloat = 720
    static let pageHorizontalPadding: CGFloat = 44
    static let pageVerticalPadding: CGFloat = 34
    static let sectionSpacing: CGFloat = 28
    static let titleSize: CGFloat = 26
    static let titleSymbolSize: CGFloat = 21
    static let sectionTitleSize: CGFloat = 13
    static let rowHeight: CGFloat = 28
    static let rowCornerRadius: CGFloat = 6
    static let cardCornerRadius: CGFloat = 10
    static let cardPadding: CGFloat = 18
    static let cardShadowRadius: CGFloat = 12
    static let cardShadowOffset: CGFloat = 4
    static let thumbnail = CGSize(width: 66, height: 88)
    /// Narrowest a figure in a grid of them may be, as Statistics lays out labels by kind.
    static let figureMinWidth: CGFloat = 92
    /// Width of the kind chooser where a label is added on a document's card.
    static let labelKindPickerWidth: CGFloat = 130
    /// Width of the field where the label to merge into is written on a label's card.
    static let mergeFieldWidth: CGFloat = 240

    static let page = Color(nsColor: .textBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hover = Color.primary.opacity(0.05)
    static let cardShadow = Color.black.opacity(0.14)
}

extension Destination {
    var title: String {
        switch self {
        case .incoming: "Incoming"
        case .review: "Needs You"
        case .processed: "Processed"
        case .labels: "Labels"
        case .labelled: "Labelled"
        case .history: "History"
        case .statistics: "Statistics"
        }
    }

    var symbol: String {
        switch self {
        case .incoming: "tray.and.arrow.down.fill"
        case .review: "questionmark.circle.fill"
        case .processed: "checkmark.circle.fill"
        case .labels, .labelled: "tag.fill"
        case .history: "clock.fill"
        case .statistics: "chart.bar.fill"
        }
    }

    /// The colour each list is known by, as in Things' sidebar.
    var tint: Color {
        switch self {
        case .incoming: .blue
        case .review: .orange
        case .processed: .green
        case .labels, .labelled: .purple
        case .history, .statistics: .secondary
        }
    }
}

extension DocumentStatus {
    var symbol: String {
        switch self {
        case .filed: "checkmark.circle.fill"
        case .needsReview: "questionmark.circle"
        case .failed, .missing: "exclamationmark.circle"
        case .duplicate: "doc.on.doc"
        case .undone: "arrow.uturn.backward.circle"
        case .held: "pause.circle"
        case .arrived, .processing: "circle.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .filed: Palette.progress
        case .needsReview, .held: Palette.attention
        case .failed, .missing: Palette.problem
        case .duplicate, .undone, .arrived, .processing: Palette.expected
        }
    }
}

/// How documents, what the model read them as, and events are put into words on screen.
enum Wording {
    /// Where Ollama may answer, under the server field.
    static let ollamaServerNote = "This Mac or a machine of yours on the local network, such as http://192.168.1.20:11434. "
        + "Documents are read by the model there; nothing is sent beyond the local network."

    /// The models section's title: where they run.
    static func modelsRun(at url: URL?) -> String {
        guard let url, !OllamaEndpoint.isThisMac(url) else { return "Models (all run on this Mac)" }
        return "Models (all run on \(url.host(percentEncoded: false) ?? url.absoluteString))"
    }

    static let managementOnThisMacOnly = "The app starts and stops Ollama only on this Mac."

    /// Where a file sits: the archive, one of its directories, Incoming, or elsewhere.
    static func place(of document: DocumentRecord, archive: URL?, incoming: URL?) -> String {
        let directory = document.url.deletingLastPathComponent().standardizedFileURL.path
        if let archive {
            let root = archive.standardizedFileURL.path
            if directory == root { return "Archive" }
            if directory.hasPrefix(root + "/") {
                return (["Archive"] + directory.dropFirst(root.count + 1).split(separator: "/").map(String.init)).joined(separator: pathSeparator)
            }
        }
        if let incoming, directory == incoming.standardizedFileURL.path { return "Incoming" }
        return directory
    }

    /// Separates the directories of a path where the app shows one.
    static let pathSeparator = " › "

    /// The short outcome shown at the end of a document's row: where a filed document is, otherwise what happened
    /// to it and where it is now. "Waiting for you: the model gave no valid answer · in Archive".
    static func outcome(of document: DocumentRecord, archive: URL?, incoming: URL?) -> String {
        guard document.status != .missing else { return StatsService.stopReason(for: .missing).text }
        let place = place(of: document, archive: archive, incoming: incoming)
        let reason: String? = switch document.status {
        case .filed: nil
        case .needsReview, .failed:
            document.analysis.flatMap { $0.problems.isEmpty ? nil : "Waiting for you: " + $0.problems.joined(separator: "; ") }
                ?? StatsService.stopReason(for: document.status).text
        default: StatsService.stopReason(for: document.status).text
        }
        guard let reason else { return place }
        let preposition = document.status == .undone && place == "Incoming" ? "back in" : "in"
        return "\(reason) · \(preposition) \(place)"
    }

    /// Who read the document, as a sentence.
    static func reader(_ analysis: DocumentAnalysis) -> String {
        analysis.model.map { "Read by \($0)" } ?? "Not read by the model"
    }

    /// Kinds a document's row names first, in this order, before the rest of its labels.
    static let rowKinds: [LabelKind] = [.date, .sender, .type]

    /// How many labels a document's row shows beyond those of `rowKinds`.
    static let rowExtraLabels = 3

    /// A document's labels on one line, its date, sender and type first: "5 Jul 2026 · EDP · Invoice · Portugal".
    static func labels(_ labels: [DocumentLabel]?) -> String? {
        guard let labels, !labels.isEmpty else { return nil }
        let first = rowKinds.flatMap { kind in labels.filter { $0.kind == kind } }
        let rest = labels.filter { !rowKinds.contains($0.kind) }.prefix(rowExtraLabels)
        return (first + rest).map(label).joined(separator: " · ")
    }

    /// How a kind of label is introduced on a document's card.
    static func labelKind(_ kind: LabelKind) -> String {
        switch kind {
        case .sender: "From"
        case .party: "About"
        case .type: "Type"
        case .topic: "Topic"
        case .object: "Concerns"
        case .reference: "Reference"
        case .date: "Date"
        case .period: "Period"
        case .deadline: "Deadline"
        case .amount: "Amount"
        case .jurisdiction: "Jurisdiction"
        case .language: "Language"
        }
    }

    /// The labels of a kind, as the Labels page heads them.
    static func labelKinds(_ kind: LabelKind) -> String {
        switch kind {
        case .sender: "Senders"
        case .party: "People and Organisations"
        case .type: "Types"
        case .topic: "Topics"
        case .object: "Things"
        case .reference: "References"
        case .date: "Dates"
        case .period: "Periods"
        case .deadline: "Deadlines"
        case .amount: "Amounts"
        case .jurisdiction: "Jurisdictions"
        case .language: "Languages"
        }
    }

    /// A decision about labels, as a sentence: "“EDP Comercial” is written “EDP”".
    static func rule(_ rule: LabelRule) -> String {
        let value = label(DocumentLabel(kind: rule.kind, value: rule.value))
        let target = rule.target.map { label(DocumentLabel(kind: rule.kind, value: $0)) } ?? ""
        return switch rule.action {
        case .merge: "“\(value)” is written “\(target)”"
        case .ignore: "“\(value)” is not wanted"
        case .keepApart: "“\(value)” and “\(target)” are kept apart"
        }
    }

    static func ruleSymbol(_ action: LabelRuleAction) -> String {
        switch action {
        case .merge: "arrow.triangle.merge"
        case .ignore: "tag.slash"
        case .keepApart: "arrow.left.and.right"
        }
    }

    /// What a new label of a kind looks like, shown in the empty field.
    static func labelPrompt(_ kind: LabelKind) -> String {
        switch kind {
        case .date, .deadline: "YYYY-MM-DD"
        case .period: "YYYY, YYYY-MM or start/end"
        case .amount: "54.21 EUR"
        case .language: "pt, en, ru"
        case .type: "invoice, receipt, contract"
        default: "Label"
        }
    }

    /// A label as the card shows it: a type by its name, a language by its name in the user's language, a date as a
    /// date.
    static func label(_ label: DocumentLabel) -> String {
        switch label.kind {
        case .language: return Locale.current.localizedString(forLanguageCode: label.value) ?? label.value
        case .type: return DocumentType(rawValue: label.value)?.label ?? label.value
        case .date, .deadline:
            guard let date = try? Date(label.value, strategy: .iso8601.year().month().day()) else { return label.value }
            return date.formatted(date: .abbreviated, time: .omitted)
        default: return label.value
        }
    }

    /// A day heading: Today, Yesterday, or the date.
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
                        : date.formatted(.dateTime.day().month(.wide).year())
    }

    /// When the pipeline finished with a document, matching `DocumentOrder.recentlyProcessed`.
    static func processedAt(_ document: DocumentRecord) -> Date { document.filedAt ?? document.addedAt }
}

/// Symbols and colours for history events.
enum EventStyle {
    static func symbol(_ kind: EventKind) -> String {
        switch kind {
        case .arrived: "tray.and.arrow.down"
        case .extracted: "doc.text.magnifyingglass"
        case .analysed: "tag"
        case .filed: "checkmark.circle"
        case .needsReview: "questionmark.circle"
        case .duplicate: "doc.on.doc"
        case .error, .failed: "exclamationmark.triangle"
        case .retry: "arrow.clockwise"
        case .corrected, .userMoved, .userRenamed, .markedCorrect: "hand.point.up.left"
        case .undone: "arrow.uturn.backward"
        case .labelsMerged: Wording.ruleSymbol(.merge)
        case .labelIgnored: Wording.ruleSymbol(.ignore)
        case .labelsKeptApart: Wording.ruleSymbol(.keepApart)
        case .labelRuleForgotten: "arrow.uturn.backward"
        default: "circle"
        }
    }

    static func color(_ kind: EventKind) -> Color {
        switch kind {
        case .filed: Palette.progress
        case .needsReview, .retry: Palette.attention
        case .error, .failed: Palette.problem
        default: .secondary
        }
    }
}
