import ArrumatorCore
import Foundation

// MARK: Document card

extension Wording {
    static let doubleClickToOpen = "Double-click to open"
    static let name = "Name"
    static let labelsHeading = "Labels"
    static let labelKindPicker = "Kind"
    static let add = "Add"
    static let readHeading = "Read"
    static let open = "Open"
    static let showInFinder = "Show in Finder"
    static let howWasThisRead = "How Was This Read?"
    static let undoFiling = "Undo Filing"
    static let undoFilingHelp = "Move it back to Incoming"
    static let confirmFiledHelp = "Confirm its name and labels"
    static let leaveForLater = "Leave for Later"
    static let confirmWaitingHelp = "Keep it in the archive as it is"
    static let removeLabelHelp = "Remove this label"
    static let showInLabels = "Show in Labels"
    static let removeFromEveryDocument = "Remove from Every Document…"
    static let removedForGoodFromCard = "Arrumator will not give this label again. You can forget this decision on the Labels page."
}

// MARK: Incoming

extension Wording {
    static let nothingWaiting = "Nothing waiting. Files dropped into Incoming are picked up on their own."
    static let inProgress = "In Progress"
    static let queuedHeading = "Queued"
    static let showMoreInProcessed = "Show More in Processed"

    /// While documents are read again after the index was rebuilt.
    static func reindexing(_ count: Int) -> String {
        "Reading \(Format.count(count, "document")) again for search, after the index was "
            + "rebuilt from the archive. New files still come first."
    }

    /// When a job that failed is tried again, after its error.
    static func retrying(at date: Date) -> String { " · retrying at \(date.formatted(date: .omitted, time: .shortened))" }

    /// How long a queued file has waited.
    static func arrived(_ date: Date) -> String { "arrived \(date.formatted(.relative(presentation: .named)))" }
}

// MARK: Needs You, Processed, History, Labelled

extension Wording {
    static let reviewNotes = "Arrumator could not read these as it should. Confirm one as it is, "
        + "correct its name and details, or have it read again."
    static let nothingNeedsYou = "Nothing needs you."
    static let nothingProcessed = "Nothing has been processed yet."
    static let nothingHappened = "Nothing has happened yet."
    /// Tags an event the user caused.
    static let byYou = "you"
    static let noDocumentHasAll = "No document has every one of these labels."
}

// MARK: Labels page

extension Wording {
    static let labelsNotes = "Merge labels that mean the same, or remove one you never want. Arrumator does the same for "
        + "every document it reads from then on, and tells the model how you want labels written."
    static let lookAlike = "Look Alike"
    static let noLabelsYet = "No document has labels yet."
    static let whatYouDecided = "What You Decided"
    static let keepApart = "Keep Apart"
    static let keepApartHelp = "They mean different things: never merge them, and never ask again"
    static let mergeInto = "Merge into"
    static let chooseLabelInUse = "Choose a label in use"
    static let merge = "Merge"
    static let removeEverywhereEllipsis = "Remove Everywhere…"
    static let removeEverywhereHelp = "Take it off every document, and never give it again"
    static let removedForGoodFromLabels = "Arrumator will not give this label again. You can forget this decision under What You Decided."
    static let forget = "Forget"
    static let forgetHelp = "Read documents without this rule from now on; documents keep their labels"

    /// Two labels that look alike.
    static func alike(_ value: String, _ other: String) -> String { "“\(value)” and “\(other)”" }

    static func writtenAlike(_ kind: LabelKind) -> String { "Two \(labelKinds(kind).lowercased()) written alike. Are they one?" }

    /// Keeps one of two alike labels.
    static func use(_ value: String) -> String { "Use “\(value)”" }

    static func mergeHelp(_ value: String, into other: String) -> String {
        "Every document with “\(value)” gets “\(other)” instead"
    }
}

// MARK: Sidebar and menu bar

extension Wording {
    static let resumeFiling = "Resume filing"
    static let pauseFiling = "Pause filing"
    static let switchArchive = "Switch Archive…"
    static let chooseArchive = "Choose the archive to file into"
    static let setUpApp = "Set Up Arrumator…"
    static let openApp = "Open Arrumator"
    static let searchLabels = "Search Labels"
    static let groupLabelsByKind = "Group Labels by Kind"
    /// Heads the sidebar's labels when they are in one list.
    static let mostUsedLabels = "Most Used"

    static func noLabelsMatch(_ query: String) -> String { "No labels match “\(query)”." }

    /// A sidebar label's help: its kind, which its colour stands for, and what clicking it does.
    static func sidebarLabelHelp(_ kind: LabelKind, chosen: Bool) -> String {
        "\(labelKinds(kind)): \(chosen ? showWithoutLabel : showOnlyWithLabel)"
    }

    /// How many documents wait for the user, in the menu bar.
    static func needYou(_ count: Int) -> String { "\(count) need\(count == 1 ? "s" : "") you" }
}

// MARK: Onboarding

extension Wording {
    static let back = "Back"
    static let continueStep = "Continue"
    static let start = "Start"
    static let welcomeIntro = """
        Drop any document into your Incoming folder. Arrumator reads it on this Mac, labels it with who sent it, \
        what it is and whom it concerns, its dates, amounts and references, where it applies and its language, \
        names it, and files it into your archive. You find it again by searching for any of its labels.
        """
    static let welcomeLocal = "Everything runs locally with Ollama. No document ever leaves this computer."
    static let welcomeNoFolders = "No folders to keep tidy: every document sits at the top of the archive, found by its labels."
    static let welcomeLabels = "Labels say who sent it, what it is, its dates, amounts, references and more; correct any of them."
    static let chooseFolders = "Choose your folders"
    static let ready = "Ready"
    static let readyIntro = "Arrumator lives in the menu bar. Open it to see what was filed, search by label, and answer documents that need you."
    static let openAppAtLogin = "Open Arrumator at login"
}

// MARK: Settings

extension Wording {
    static let generalTab = "General"
    static let filingTab = "Filing"
    static let modelsTab = "Models"
    static let advancedTab = "Advanced"
    static let processingLogTab = "Processing log"

    static let folders = "Folders"
    static let foldersFooter = "Each archive keeps its own history. Choosing another archive files into it from now on; "
        + "choosing this one again brings everything back."
    static let background = "Background"
    static let showInDock = "Show icon in the Dock"
    static let menuBarFull = "Your menu bar is full, so Arrumator's icon there is hidden. Keep the Dock icon on, or remove other menu bar items."
    static let openAtLogin = "Open at login"
    static let pauseProcessing = "Pause processing"
    static let pauseOnBattery = "Pause on battery when low"
    static let notifications = "Notifications"
    static let notifyWhenFiled = "When a document is filed"
    static let notifyWhenReview = "When a document needs review"
    static let choose = "Choose…"

    static func chooseFolder(_ name: String) -> String { "Choose the \(name) folder" }

    static let files = "Files"
    static let renameFiles = "Rename files"
    static let transliterate = "Transliterate names to Latin letters"
    static let exactDuplicates = "Exact duplicates"
    static let fileCopies = "File copies into the archive"
    static let leaveCopies = "Leave copies in Incoming"

    static let ollama = "Ollama"
    static let status = "Status"
    static let server = "Server"
    static let useServer = "Use"
    static let management = "Management"
    static let launchOllamaApp = "Start the Ollama app when needed"
    static let spawnServe = "Run 'ollama serve' myself (managed)"
    static let neverStart = "Never start it"
    static let startOllama = "Start / check Ollama"
    static let profile = "Profile"
    static let downloading = "Downloading…"
    static let download = "Download"
    static let downloadNote = "Downloading a model needs the internet once; reading and filing documents never does."

    /// Where Ollama may answer, under the server field.
    static let ollamaServerNote = "This Mac or a machine of yours on the local network, such as http://192.168.1.20:11434. "
        + "Documents are read by the model there; nothing is sent beyond the local network."

    static let managementOnThisMacOnly = "The app starts and stops Ollama only on this Mac."

    /// The models section's title: where they run.
    static func modelsRun(at url: URL?) -> String {
        guard let url, !OllamaEndpoint.isThisMac(url) else { return "Models (all run on this Mac)" }
        return "Models (all run on \(url.host(percentEncoded: false) ?? url.absoluteString))"
    }

    /// A model the profile uses, by its role.
    static func model(role: String, name: String) -> String { "\(role): \(name)" }

    static func installed(_ name: String) -> String { "\(name) installed" }

    static let diagnostics = "Diagnostics"
    static let logDetail = "Log detail"
    static let includeText = "Include document text in diagnostics"
    static let exportDiagnostics = "Export diagnostics…"
    static let diagnosticsFileName = "arrumator-diagnostics.zip"
    static let index = "Index"
    static let indexNote = "Everything Arrumator knows is kept in Markdown files in the archive; the archive's index only holds "
        + "them for search. Rebuilding reads the archive again, then reads each document's text again in the background."
    static let rebuildIndex = "Rebuild Index From Archive…"
    static let rebuildQuestion = "Rebuild the index from the archive?"
    static let rebuild = "Rebuild"
    static let rebuildNote = "Nothing in the archive changes. Search by words and by meaning fills in again as documents are read."
    static let openDataFolder = "Open data folder (indexes, settings, pipeline.json overrides)"

    static func keepPrompts(days: Int) -> String { "Keep full model prompts for \(days) days" }

    static func rebuilt(_ summary: String, queued: Int) -> String { "\(summary). \(queued) documents are being read again." }

    static func exported(traces: Int, logFiles: Int) -> String { "Saved \(traces) traces and \(logFiles) log files." }
}

// MARK: Processing log

extension Wording {
    static let logTime = "Time"
    static let logLevel = "Level"
    static let logPart = "Part"
    static let logWhat = "What happened"
    static let logDetailColumn = "Detail"
    static let nothingLogged = "Nothing logged yet"
    static let linesAppear = "Lines appear as files are processed."
    static let step = "Step"
    static let everyStep = "Every step"
    static let logDetailPicker = "Detail"
    static let filter = "Filter"

    /// A log line's fields, by name: "file=a.pdf  ms=12".
    static func logFields(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
    }
}

// MARK: Statistics

extension Wording {
    static let nothingCameThrough = "Nothing has come through yet"
    static let statisticsAppear = "Statistics appear once files have been filed."
    static let period = "Period"
    static let everyOneFiled = "Every one of them was filed."
    static let howFarFilesGot = "How far files got"
    static let reached = "Reached"
    static let stopped = "Stopped"
    static let ofAll = "Of all"
    static let typical = "Typical"
    static let slowest = "Slowest"
    static let whereFilesEndedUp = "Where files ended up"
    /// The slice of files that were filed, where files ended up.
    static let filedSlice = "Filed"
    static let wentOn = "Went on"
    static let typicalFile = "Typical file"
    static let slowestOneInTwenty = "Slowest one in twenty"
    static let failedHere = "Failed here"
    static let stoppedHere = "Stopped here"
    static let openNeedsYou = "Open Needs You"
    static let scanClarity = "How clearly scans read"
    static let noReadingTrouble = "No trouble reading any file."
    static let readingTrouble = "Trouble reading files"
    static let labelledFigure = "Labelled"
    static let notLabelledYet = "Not labelled yet"
    static let labelsTidied = "Tidied to the archive's labels"
    static let yourLabelRules = "Your rules for labels"
    static let correctedByYou = "Corrected by you"
    static let confirmedByYou = "Confirmed by you"

    static func lastDays(_ days: Int) -> String { "Last \(days) days" }

    static func arrivedIn(_ documents: Int, days: Int) -> String { "\(documents) files arrived in the last \(days) days." }

    /// Where most files that were not filed stopped, and why.
    static func mostStopped(at step: String, count: Int, reason: String) -> String {
        "Most that did not get filed stopped at \(step.lowercased()): \(count) \(reason.lowercased())."
    }

    static func slowestStep(_ step: String, duration: String) -> String {
        "\(step) is the slowest step, \(duration) for a typical file."
    }
}

// MARK: Trace

extension Wording {
    static let run = "Run"
    static let done = "Done"
    static let input = "Input"
    static let output = "Output"

    /// One run of the pipeline over a document, as the trace's chooser lists it.
    static func traceRun(_ trace: TraceRecord) -> String {
        "\(trace.startedAt.formatted(date: .abbreviated, time: .standard)) · \(trace.source) · \(trace.outcome ?? "…")"
    }

    static func milliseconds(_ ms: Int) -> String { "\(ms) ms" }
}

// MARK: Tasks

extension Wording {
    static let tasksNotes = "Ask for the documents you need, in your own words. Arrumator reads the request with the local model, "
        + "finds the documents, and arranges them by their labels. Look them over, add or take out any, then export them."
    static let askPrompt = "Which documents do you need? Such as: electricity and water bills from 2025, by sender"
    static let find = "Find"
    static let noTasksYet = "No tasks yet. Ask for documents above."
    static let earlierTasks = "Earlier"
    static let asked = "Asked"
    static let lookedFor = "Looked for"
    static let arrangedBy = "Arranged by"
    static let notArranged = "Not arranged"
    static let arrangeAsAsked = "As Asked"
    static let arrangeAsAskedHelp = "Arrange the documents as the request asked"
    static let addLevel = "Add a level"
    static let findAgain = "Find Again"
    static let findAgainHelp = "Read the request again and find its documents, keeping what you added and took out"
    static let addDocuments = "Add Documents…"
    static let addDocumentsHelp = "Choose labels in the sidebar to find documents, and add them to this task"
    static let exportMenu = "Export"
    static let exportToFolder = "To a Folder…"
    static let exportAsZip = "As a ZIP Archive…"
    static let chooseExportFolder = "Choose where to put the export"
    static let removeTask = "Remove Task…"
    static let removeTaskConfirm = "Remove Task"
    static let removeTaskNote = "What it exported stays where it was put."
    static let exportsHeading = "Exports"
    static let noLongerThere = "no longer there"
    static let takeOutHelp = "Take it out of this task"
    static let addToTaskHelp = "Add it to the task"
    static let inTaskHelp = "In the task; click to take it out"
    static let addAllShown = "Add All With These Labels"
    static let doneAdding = "Done"
    static let nothingFound = "Nothing found. Change the request, or add documents yourself."

    /// Asks before a task is removed.
    static func removeTaskQuestion(_ name: String) -> String { "Remove “\(name)”?" }

    /// Heads the pages that narrow documents down while they are added to a task.
    static func addingTo(_ task: String) -> String { "Adding documents to “\(task)”. Choose labels in the sidebar to narrow them down." }

    /// Where a task is, at the end of its row.
    static func taskOutcome(_ task: SearchTask) -> String {
        switch task.state {
        case .queued: "Waiting to be read"
        case .interpreting: "Reading the request"
        case .failed: "Could not read the request"
        case .ready: Format.count(task.documents.count, "document")
            + (task.exports.isEmpty ? "" : labelSeparator + "exported \(task.exports.count == 1 ? "once" : "\(task.exports.count) times")")
        }
    }

    /// What a plan looks for: “Invoice · electricity · 2025; words: meter”.
    static func plan(_ plan: SearchPlan) -> String {
        let labels = plan.labels.map { item in SearchPlan.timeKinds.contains(item.kind) ? item.value : label(item) }.joined(separator: labelSeparator)
        let words = plan.words.isEmpty ? "" : "words: " + plan.words.joined(separator: ", ")
        return [labels, words].filter { !$0.isEmpty }.joined(separator: "; ")
    }

    /// A group of a task's set, as the label its documents share, or that they have none of the kind.
    static func group(_ group: LabelGroup) -> String {
        guard let kind = group.kind else { return "" }
        guard let value = group.value else { return "No \(labelKind(kind).lowercased())" }
        return SearchPlan.timeKinds.contains(kind) ? value : label(DocumentLabel(kind: kind, value: value))
    }

    /// An export, as a task's card lists it.
    static func export(_ export: SearchTaskExport) -> String {
        let format = export.format == .zip ? "ZIP archive" : "folder"
        return "\(export.at.formatted(date: .abbreviated, time: .shortened)) · \(format) · \(Format.count(export.files.count, "document"))"
            + (export.skipped.isEmpty ? "" : ", \(export.skipped.count) not copied")
    }
}
