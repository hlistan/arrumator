import ArrumatorCore
import Foundation

/// How documents, what the model read them as, and events are put into words on screen. Every sentence, title and
/// button the app shows lives here or in the extensions of this enum, one `// MARK:` per page or area.
enum Wording {
    // MARK: The app and its windows

    static let appName = "Arrumator"
    static let welcome = "Welcome to Arrumator"
    static let settingsWindow = "Arrumator Settings"

    /// A window's title.
    static func title(of window: WindowID) -> String {
        switch window {
        case .main: appName
        case .onboarding: welcome
        case .settings: settingsWindow
        }
    }

    /// A page's title, as the sidebar lists it and the page heads itself.
    static func title(of destination: Destination) -> String {
        switch destination {
        case .incoming: "Incoming"
        case .review: "Needs You"
        case .processed: "Processed"
        case .labels: "Labels"
        case .labelled: "Labelled"
        case .history: "History"
        case .statistics: "Statistics"
        }
    }

    // MARK: Menus

    static let aboutApp = "About Arrumator"
    static let settings = "Settings…"
    static let hideApp = "Hide Arrumator"
    static let quitApp = "Quit Arrumator"
    static let windowMenu = "Window"
    static let setup = "Setup…"
    static let minimise = "Minimise"
    static let close = "Close"
    static let editMenu = "Edit"
    static let undo = "Undo"
    static let redo = "Redo"
    static let cut = "Cut"
    static let copy = "Copy"
    static let paste = "Paste"
    static let selectAll = "Select All"

    /// The count of documents that need the user, after the menu bar icon.
    static func statusItemCount(_ count: Int) -> String { " \(count)" }

    // MARK: What the app is doing

    static let pause = "Pause"
    static let resume = "Resume"
    static let paused = "Paused"
    static let idle = "Idle"
    static let waitingForFolders = "Waiting for access to your folders"
    static let startingForFolders = "Starting: waiting for folder access"
    static let waitingForOllama = "Waiting for Ollama"

    /// Why filing waits, such as low battery.
    static func waiting(_ reason: String) -> String { "Waiting: \(reason)" }

    /// The stage a file is at, and the file.
    static func working(on file: String, stage: String?) -> String { "\(stage ?? "Working") \(file)" }

    static func queued(_ count: Int) -> String { "\(count) queued" }

    /// Notification titles.
    static let notifyFiled = "Filed"
    static let notifyReview = "Needs your review"

    // MARK: Actions, as an error names what failed

    /// An action that failed, and why: "Rename: The file is locked."
    static func failure(_ action: String, _ reason: String) -> String { "\(action): \(reason)" }

    static let readArchiveAction = "Reading the archive"
    static let switchArchivesAction = "Switch archives"
    static let undoAction = "Undo"
    static let confirmAction = "Confirm"
    static let holdAction = "Hold"
    static let readAgainAction = "Read again"
    static let changeLabelsAction = "Change labels"
    static let renameAction = "Rename"
    static let removeLabelAction = "Remove label"
    static let keepApartAction = "Keep apart"
    static let mergeLabelsAction = "Merge labels"
    static let forgetRuleAction = "Forget rule"
    static let prepareSearchAction = "Prepare search"
    static let searchAction = "Search"
    static let checkModelsAction = "Check models"
    static let rebuildIndexAction = "Rebuild the index"
    static let exportDiagnosticsAction = "Export diagnostics"
    static let loadDocumentAction = "Load document"
    static let loadHistoryAction = "Load history"
    static let loadQueueAction = "Load queue"
    static let loadProcessedAction = "Load processed documents"
    static let loadLabelledAction = "Load labelled documents"
    static let loadLabelsAction = "Load labels"
    static let loadReviewQueueAction = "Load review queue"
    static let loadStatisticsAction = "Load statistics"
    static let loadTracesAction = "Load traces"
    static let loadTraceAction = "Load trace"

    // MARK: Shared across pages

    static let showMore = "Show More"
    static let showDocuments = "Show Documents"
    static let openIncomingFolder = "Open Incoming Folder"
    static let openArchiveFolder = "Open Archive Folder"
    static let openLogsFolder = "Open logs folder"
    static let removeEverywhere = "Remove Everywhere"
    static let looksRight = "Looks Right"
    static let readAgain = "Read Again"
    static let showWithoutLabel = "Show documents without this label too"
    static let showOnlyWithLabel = "Show only documents with this label"
    /// Stands for a value there is none of.
    static let noValue = "—"

    /// Asks before a label is taken off every document.
    static func removeEverywhereQuestion(_ label: String) -> String { "Remove “\(label)” from every document?" }

    // MARK: Documents

    /// The folders' names, as a document's place and the settings name them.
    static let incomingFolder = "Incoming"
    static let archiveFolder = "Archive"

    /// What an extraction warning means, as Statistics lists them.
    static func warning(_ code: WarningCode) -> String {
        switch code {
        case .encrypted: "Locked with a password"
        case .corrupted: "Damaged file"
        case .unsupportedFormat: "Format it cannot read"
        case .tooLarge: "Too large to read fully"
        case .toolFailed: "A converter failed"
        case .ocrLowConfidence: "Scan was hard to read"
        case .ocrFailed: "A page could not be scanned"
        case .textTruncated: "Too much text to keep all of it"
        case .vlmFailed: "Could not describe the image"
        case .vlmSkipped: "An image was not described"
        case .encodingGuessed: "Text encoding had to be guessed"
        case .emptyText: "No text in it"
        case .timeout: "Took too long to read"
        }
    }

    /// Where a file sits: the archive, one of its directories, Incoming, or elsewhere.
    static func place(of document: DocumentRecord, archive: URL?, incoming: URL?) -> String {
        let directory = document.url.deletingLastPathComponent().standardizedFileURL.path
        if let archive {
            let root = archive.standardizedFileURL.path
            if directory == root { return archiveFolder }
            if directory.hasPrefix(root + "/") {
                return ([archiveFolder] + directory.dropFirst(root.count + 1).split(separator: "/").map(String.init)).joined(separator: pathSeparator)
            }
        }
        if let incoming, directory == incoming.standardizedFileURL.path { return incomingFolder }
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
        let preposition = document.status == .undone && place == incomingFolder ? "back in" : "in"
        return "\(reason) · \(preposition) \(place)"
    }

    /// Who read the document, as a sentence.
    static func reader(_ analysis: DocumentAnalysis) -> String {
        analysis.model.map { "Read by \($0)" } ?? "Not read by the model"
    }

    /// How a document arrived, under its name on its card.
    static func arrived(as name: String, at date: Date) -> String {
        "Arrived as \(name) · \(date.formatted(date: .abbreviated, time: .shortened))"
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

    // MARK: Labels

    /// Kinds a document's row names first, in this order, before the rest of its labels.
    static let rowKinds: [LabelKind] = [.date, .sender, .type]

    /// How many labels a document's row shows beyond those of `rowKinds`.
    static let rowExtraLabels = 3

    /// A document's labels on one line, its date, sender and type first: "5 Jul 2026 · EDP · Invoice · Portugal".
    static func labels(_ labels: [DocumentLabel]?) -> String? {
        guard let labels, !labels.isEmpty else { return nil }
        let first = rowKinds.flatMap { kind in labels.filter { $0.kind == kind } }
        let rest = labels.filter { !rowKinds.contains($0.kind) }.prefix(rowExtraLabels)
        return (first + rest).map(label).joined(separator: labelSeparator)
    }

    /// Separates labels shown on one line.
    static let labelSeparator = " · "

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
}
