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
    /// How far each level of the folder tree is indented where it is listed as an outline.
    static let outlineIndent: CGFloat = 14
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
    /// What a rethink decided for a document, by folder path: "Home › Bills → Home › Energy".
    static func outcome(of item: RethinkItemRecord, in taxonomy: TaxonomySnapshot?) -> String {
        let from = place(of: item.fromPath, in: taxonomy)
        let target = item.targetPath.map { place(of: $0, in: taxonomy) }
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

    /// Separates folder names where the app shows a path.
    static let pathSeparator = " › "

    /// A folder by its path from the top of the archive: "Portugal › Acme Lda › Banking".
    static func path(of folder: TaxonomyFolder, in taxonomy: TaxonomySnapshot) -> String {
        taxonomy.path(of: folder, separator: pathSeparator)
    }

    /// A folder known only by its code, by path. Codes are the app's own, so a folder that has gone is named as gone,
    /// never by its code.
    static func path(ofCode code: String, in taxonomy: TaxonomySnapshot?) -> String {
        taxonomy?.path(ofCode: code, separator: pathSeparator) ?? removedFolder
    }

    static let removedFolder = "a removed folder"

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
        "A new document showing any of these is taken to be from \(sender), so its rules can file it."
    }

    static let senderWithoutRules = "No rules yet. They form once several of its filings agree on a folder."

    /// One of a sender's rules on its card: what else it asks, where it files, and how much agrees.
    /// "document type invoice → Home › Utilities · 4 agree"
    static func senderRule(_ rule: FilingRule, in taxonomy: TaxonomySnapshot?) -> String {
        let others = rule.predicates.filter { if case .correspondent = $0 { false } else { true } }
            .map { $0.summary(sender: { _ in nil }) }
        let folder = taxonomy.flatMap { tree in tree.folder(id: rule.action.folderID).map { path(of: $0, in: tree) } } ?? removedFolder
        return (others.isEmpty ? "everything" : others.joined(separator: " and ")) + " → \(folder) · \(rule.support) agree"
            + (rule.enabled ? "" : " · off")
    }

    /// A document's place by folder path, and the year folder inside it: "Identity Documents › Passports › 2025".
    static func place(_ place: DocumentPlace, in taxonomy: TaxonomySnapshot) -> String {
        switch place {
        case let .folder(folder, year): path(of: folder, in: taxonomy) + (year.map { pathSeparator + $0 } ?? "")
        case .incoming: "Incoming"
        case let .elsewhere(directory): directory
        case .missing: StatsService.stopReason(for: .missing).text
        }
    }

    /// Where a file sits, by folder path without year folders: "Home › Payslips". A folder a plan has yet to create
    /// is named as its directory will be.
    static func place(of filePath: String, in taxonomy: TaxonomySnapshot?) -> String {
        let directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        if let taxonomy, let folder = taxonomy.folder(holding: directory) { return path(of: folder, in: taxonomy) }
        let root = (taxonomy?.rootPath ?? "") + "/"
        let relative = directory.path.hasPrefix(root) ? String(directory.path.dropFirst(root.count)) : directory.path
        return relative.split(separator: "/").map(String.init).filter { !YearFolder.matches($0) }.joined(separator: pathSeparator)
    }

    /// The folder a decision points at, existing or proposed.
    /// Nil when there is nothing to accept, including a suggested folder that has since been removed.
    static func target(of decision: FilingDecision?, in taxonomy: TaxonomySnapshot?) -> String? {
        guard let decision else { return nil }
        guard let taxonomy else { return decision.proposedNewFolder.map { "new folder " + $0.name } }
        return taxonomy.destination(of: decision, separator: pathSeparator).map { ($0.isNew ? "new folder " : "") + $0.path }
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
        if reason == nil, case .folder = place { return Self.place(place, in: taxonomy) }
        let preposition = document.status == .undone && place == .incoming ? "back in" : "in"
        return "\(reason ?? StatsService.stopReason(for: document.status).text) · \(preposition) \(Self.place(place, in: taxonomy))"
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
