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
    static let logicEditorHeight: CGFloat = 300
    static let decisionSymbolWidth: CGFloat = 16
    /// Lines up an opened plan row's reasoning with the file name above it, past the checkbox or symbol.
    static let reasoningIndent: CGFloat = 35

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
        case .learned: "Learned"
        case .logic: "Logic"
        case .folder: "Folder"
        case .history: "History"
        case .statistics: "Statistics"
        }
    }

    var symbol: String {
        switch self {
        case .incoming: "tray.and.arrow.down.fill"
        case .review: "questionmark.circle.fill"
        case .processed: "checkmark.circle.fill"
        case .learned: "graduationcap.fill"
        case .logic: "point.3.connected.trianglepath.dotted"
        case .folder: "folder.fill"
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
        case .learned: .purple
        case .logic: .pink
        case .folder, .history, .statistics: .secondary
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

extension RethinkItemStatus {
    var symbol: String {
        switch self {
        case .pending, .notDecided: "circle.dotted"
        case .move: "arrow.right.circle.fill"
        case .unchanged: "equal.circle"
        case .unsure: "questionmark.circle"
        case .failed: "exclamationmark.circle"
        case .applied: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .move, .applied: Palette.progress
        case .unsure: Palette.attention
        case .failed: Palette.problem
        case .pending, .unchanged, .skipped, .notDecided: Palette.expected
        }
    }
}

/// How documents, decisions and events are put into words on screen.
enum Wording {
    /// What a rethink decided for a document, by area and folder name: "Home › Bills → Home › Energy".
    static func outcome(of item: RethinkItemRecord, in archive: URL?) -> String {
        let from = place(of: item.fromPath, in: archive)
        let target = item.targetPath.map { place(of: $0, in: archive) }
        return switch item.status {
        case .pending: "Being decided"
        case .move: "\(from) → \(target ?? "")"
        case .unchanged: "Stays in \(from)"
        case .unsure: item.canMove ? "Unsure; suggests \(target ?? "")" : "Unsure; stays in \(from)"
        case .failed: "Could not be decided: \(item.error ?? "")"
        case .applied: "Moved to \(target ?? "")"
        case .skipped: item.error ?? "Left in \(from)"
        case .notDecided: "Not decided; stays in \(from)"
        }
    }

    /// A document's place by folder code and name, and the year folder inside it: "41 Identity Documents › 2025".
    static func place(_ place: DocumentPlace) -> String {
        switch place {
        case let .folder(folder, year): "\(folder.code) \(folder.name)" + (year.map { " › \($0)" } ?? "")
        case .incoming: "Incoming"
        case let .elsewhere(directory): directory
        case .missing: StatsService.stopReason(for: .missing).text
        }
    }

    /// Where a path sits, by area and folder name without codes or year folders: "Home & Utilities › Payslips".
    static func place(of path: String, in archive: URL?) -> String {
        let root = (archive?.path ?? "") + "/"
        let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        return relative.split(separator: "/").dropLast().map(String.init)
            .filter { !JDCode.isYearFolder($0) }
            .map { JDCode.parse(directoryName: $0)?.name ?? $0 }
            .joined(separator: " › ")
    }

    /// The folder a decision points at, existing or proposed.
    /// Nil when there is nothing to accept, including a suggested folder that has since been removed.
    static func target(of decision: FilingDecision?, in taxonomy: TaxonomySnapshot?) -> String? {
        guard let decision else { return nil }
        if let code = decision.folderCode {
            return taxonomy?.folder(code: code).map { "\($0.code) \($0.name)" }
        }
        if let spec = decision.proposedNewFolder {
            return "new folder \(spec.newAreaName.map { "\($0) › " } ?? "")\(spec.name)"
        }
        return nil
    }

    /// The short outcome shown at the end of a document's row.
    static func outcome(of document: DocumentRecord, in taxonomy: TaxonomySnapshot?, incoming: URL?) -> String {
        let reason: String? = switch document.status {
        case .filed: nil
        case .needsReview: target(of: document.decision, in: taxonomy).map { "Suggested: \($0)" }
            ?? StatsService.stopReason(for: .needsReview).text
        default: StatsService.stopReason(for: document.status).text
        }
        guard let taxonomy, let incoming, case let place = taxonomy.place(of: document, incoming: incoming), place != .missing else {
            return reason ?? StatsService.stopReason(for: document.status).text
        }
        // A filed document is described by where it is; anything else by what happened, then where it is now.
        if reason == nil, case .folder = place { return Self.place(place) }
        let preposition = document.status == .undone && place == .incoming ? "back in" : "in"
        return "\(reason ?? StatsService.stopReason(for: document.status).text) · \(preposition) \(Self.place(place))"
    }

    /// Who decided, as a small tag: nil when nobody has decided yet.
    static func deciderTag(_ decision: FilingDecision?) -> String? {
        guard let decision else { return nil }
        switch decision.decidedBy {
        case .rule: return "rule"
        case .knnOnly: return "past filings"
        case .llm: return "model \(Format.percent(decision.confidence.final))"
        case .user: return "you"
        case .review, .dummy: return nil
        }
    }

    /// Who decided and how sure it was, as a sentence.
    static func decider(_ decision: FilingDecision) -> String {
        let source = StatsService.decisionSource(for: decision.decidedBy).name
        switch decision.decidedBy {
        case .user, .review: return source
        default: return "\(source) · \(Format.percent(decision.confidence.final)) sure"
        }
    }

    /// One thing the app learned, from a history event recorded against a document.
    static func lesson(_ event: EventRecord) -> String {
        switch event.kind {
        case .ruleInduced: "New rule “\(event.summary)”"
        case .ruleChanged: "Rule \(event.summary)"
        case .ruleDisabled: "Switched off rule “\(event.summary)”"
        default: event.summary
        }
    }

    /// History kinds that record learning, and forgetting.
    /// What was learned. Forgetting is recorded in History only: a lesson forgotten shows struck through instead.
    static let lessonKinds: Set<EventKind> = [.learned, .ruleInduced, .ruleChanged, .ruleDisabled]

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
        case .classified: "sparkles"
        case .filed: "checkmark.circle"
        case .needsReview: "questionmark.circle"
        case .duplicate: "doc.on.doc"
        case .error, .failed: "exclamationmark.triangle"
        case .retry: "arrow.clockwise"
        case .corrected, .userMoved, .userRenamed, .markedCorrect: "hand.point.up.left"
        case .undone: "arrow.uturn.backward"
        case .folderCreated: "folder.badge.plus"
        case .folderRenamed, .folderRemoved, .descriptionChanged: "folder"
        case .learned, .ruleInduced, .ruleChanged, .ruleDisabled: "graduationcap"
        case .logicChanged: "point.3.connected.trianglepath.dotted"
        case .rethink, .rethought: "arrow.triangle.2.circlepath"
        case .forgot: "eraser"
        default: "circle"
        }
    }

    static func color(_ kind: EventKind) -> Color {
        switch kind {
        case .filed: Palette.progress
        case .needsReview, .retry: Palette.attention
        case .error, .failed: Palette.problem
        case .learned, .ruleInduced, .ruleChanged, .ruleDisabled: .purple
        case .logicChanged: .pink
        case .rethink, .rethought: .indigo
        default: .secondary
        }
    }
}
