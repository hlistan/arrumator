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
        case .tasks: "Tasks"
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
    /// Nothing is filed, as the archive's index could not be rebuilt from its record files.
    static let archiveNotRead = "Not filing: reading the archive failed"
    /// Nothing is filed, as the archive's folder is not there, as on a disk that is not connected.
    static let archiveAway = "Not filing: the archive's folder is not there"
    static let waitingForOllama = "Waiting for Ollama"

    /// Why filing waits, such as low battery.
    static func waiting(_ reason: String) -> String { "Waiting: \(reason)" }

    /// The stage a file is at, and the file.
    static func working(on file: String, stage: String) -> String { "\(stage): \(file)" }

    /// What is being done to a file at a stage, while it is: "Reading its text", not the funnel's "Read".
    static func doing(_ state: JobState) -> String {
        switch state {
        case .pending: "Waiting"
        case .hashing: "Checking for copies"
        case .extracting: "Reading its text"
        case .analysing: "Being read by the model"
        case .filing: "Filing"
        case .done, .duplicate, .needsReview, .failed, .held, .cancelled: "Finishing"
        }
    }

    static func queued(_ count: Int) -> String { "\(count) queued" }

    /// A search task's request being read, by the model reading it: in the menu bar popover, and the help of the
    /// spinner beside Tasks in the sidebar.
    static func readingRequest(with model: String) -> String { "Reading a request with \(model)" }
    static func answeringQuestion(with model: String) -> String { "Answering a question with \(model)" }

    /// Notification titles.
    static let notifyFiled = "Filed"
    static let notifyReview = "Needs your review"

    // MARK: Actions, as an error names what failed

    /// An action that failed, and why: "Rename: The file is locked."
    static func failure(_ action: String, _ reason: String) -> String { "\(action): \(reason)" }

    /// Why an action failed, in the user's words: a change refused as the archive has not been read yet, as during
    /// onboarding, says so; anything else as it says itself.
    static func reason(_ error: any Error) -> String {
        if case let RecordsError.notRebuilt(files) = error, files.isEmpty { return notReadYet }
        return error.localizedDescription
    }

    static let notReadYet = "This can be changed once Arrumator has read your archive folder."

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
    static let checkModelsAction = "Check models"
    static let saveSettingsAction = "Save settings"
    static let useProfileAction = "Use profile"
    static let addProfileAction = "Add profile"
    static let changeProfileAction = "Change profile"
    static let resetProfileAction = "Reset profile"
    static let removeProfileAction = "Remove profile"
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
    static let askAction = "Ask for documents"
    static let loadTasksAction = "Load tasks"
    static let loadTaskAction = "Load task"
    static let changeTaskAction = "Change task"
    static let findAgainAction = "Find again"
    static let addToTaskAction = "Add to task"
    static let takeOutOfTaskAction = "Take out of task"
    static let exportAction = "Export"
    static let removeTaskAction = "Remove task"
    static let askQuestionAction = "Ask about the documents"
    static let askAgainAction = "Ask again"
    static let stopAnswerAction = "Stop answering"
    static let clearConversationAction = "Clear the conversation"
    static let loadConversationAction = "Load the conversation"

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

    /// The × that lets go of a label chosen in the sidebar, as VoiceOver reads it.
    static func letGoOf(_ label: String) -> String { "Stop narrowing by “\(label)”" }
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

    /// What a document's row ends with: nothing for one filed at the top of the archive, where the place would say the
    /// same on every row and its date already leads the line beneath; else where it is, or what happened to it.
    static func rowDetail(of document: DocumentRecord, archive: URL?, incoming: URL?) -> String? {
        if document.status == .filed, place(of: document, archive: archive, incoming: incoming) == archiveFolder { return nil }
        return outcome(of: document, archive: archive, incoming: incoming)
    }

    /// Who read the document, as a sentence.
    static func reader(_ analysis: DocumentAnalysis) -> String {
        guard let model = analysis.model else { return "Not read by the model" }
        return analysis.hadNoText ? "No text could be taken from it, so \(model) saw only its name" : "Read by \(model)"
    }

    /// What would help a document that waits for the user, when Read Again alone cannot.
    static func advice(_ analysis: DocumentAnalysis) -> String? {
        if analysis.problems.contains(DocumentAnalysis.Problem.encrypted) {
            return "Read Again cannot open it: open it with its password, save a copy without one, and put that copy in Incoming."
        }
        if analysis.problems.contains(DocumentAnalysis.Problem.corrupted) {
            return "Read Again cannot mend a damaged file: put a good copy of it in Incoming."
        }
        return nil
    }

    /// Said once Read Again has put a document back in the queue.
    static let readAgainQueued = "Waiting to be read again, after the files already in Incoming."

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

    /// The day the pipeline finished with a document, as a heading: when it was filed, else when it arrived, matching
    /// `DocumentOrder.recentlyProcessed`.
    static func processedDay(_ document: DocumentRecord) -> String { day(document.filedAt ?? document.addedAt) }

    /// The month of a document's own date, as a heading: "March 2023"; or that it has no date. Documents in
    /// `DocumentOrder.documentDate` come under these a month at a time, the newest first, those without a date last.
    static func documentMonth(_ document: DocumentRecord) -> String {
        guard let date = document.documentDate else { return without(.date) }
        return labelDay(date)?.formatted(.dateTime.month(.wide).year()) ?? date
    }

    // MARK: Labels

    /// Kinds a document's row names first, in this order, before the rest of its labels: its date, sender and type, and
    /// the tags the user gave it.
    static let rowKinds: [LabelKind] = [.date, .sender, .type, .tag]

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
        case .tag: "Tag"
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
        case .tag: "Tags"
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
        case .tag: "Your own label"
        default: "Label"
        }
    }

    /// A label as the card shows it: a type by its name, a language by its name in the user's language, a date as a
    /// date.
    static func label(_ label: DocumentLabel) -> String {
        switch label.kind {
        case .language: return Locale.current.localizedString(forLanguageCode: label.value) ?? label.value
        case .type: return DocumentType(rawValue: label.value)?.label ?? label.value
        case .date, .deadline: return labelDay(label.value)?.formatted(date: .abbreviated, time: .omitted) ?? label.value
        default: return label.value
        }
    }

    /// That documents have no label of a kind, as a heading: "No date".
    static func without(_ kind: LabelKind) -> String { "No \(labelKind(kind).lowercased())" }

    /// A date label, `YYYY-MM-DD`, as the start of that day where the user is, so it is shown as the day it names in
    /// every time zone; nil when it is no day.
    private static func labelDay(_ value: String) -> Date? {
        try? Date(value, strategy: Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }
}
