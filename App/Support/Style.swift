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
        case .senders: "Senders"
        case .history: "History"
        case .statistics: "Statistics"
        }
    }

    var symbol: String {
        switch self {
        case .incoming: "tray.and.arrow.down.fill"
        case .review: "questionmark.circle.fill"
        case .processed: "checkmark.circle.fill"
        case .senders: "person.2.fill"
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
        case .senders: .purple
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

    /// What recognising a sender is for, under what recognises it.
    static func recognition(of sender: String) -> String {
        "A new document showing any of these is taken to be from \(sender), and named as its earlier documents were."
    }

    static let senderUnrecognised = "Nothing yet. Identifiers that appear only on its documents are learned as they are filed."

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

    /// A document's labels on one line: "Maria Exemplo · Portugal · Portuguese".
    static func labels(_ labels: [DocumentLabel]?) -> String? {
        guard let labels, !labels.isEmpty else { return nil }
        return labels.map(label).joined(separator: " · ")
    }

    /// One thing the app learned, from a history event recorded against a document.
    static func lesson(_ event: EventRecord) -> String { event.summary }

    /// What was learned. Forgetting is recorded in History only: a lesson forgotten shows struck through instead.
    static let lessonKinds: Set<EventKind> = [.learned]

    /// How a kind of label is introduced on a document's card: "About Maria Exemplo".
    static func labelKind(_ kind: LabelKind) -> String {
        switch kind {
        case .subject: "About"
        case .object: "Concerns"
        case .jurisdiction: "Jurisdiction"
        case .language: "Language"
        }
    }

    /// A label as the card shows it: a language by its name in the user's language.
    static func label(_ label: DocumentLabel) -> String {
        guard label.kind == .language else { return label.value }
        return Locale.current.localizedString(forLanguageCode: label.value) ?? label.value
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
        case .learned: "graduationcap"
        case .forgot: "eraser"
        default: "circle"
        }
    }

    static func color(_ kind: EventKind) -> Color {
        switch kind {
        case .filed: Palette.progress
        case .needsReview, .retry: Palette.attention
        case .error, .failed: Palette.problem
        case .learned: .purple
        default: .secondary
        }
    }
}
