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
    static let removeFromDocument = "Remove from This Document"

    /// The × that takes a label off a document, as VoiceOver reads it.
    static func removeLabelNamed(_ label: String) -> String { "Remove “\(label)”" }
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

    /// A queued file stopped part way, as when the app quit: it carries on where it stopped when its turn comes.
    static func carriesOn(arrived date: Date) -> String { "Carries on where it stopped" + labelSeparator + arrived(date) }
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
    /// Lets go of every label chosen, beside them at the top of the page.
    static let clearLabels = "Clear"
    static let clearLabelsHelp = "Let go of every label and show all documents"
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
    static let filterLabels = "Filter Labels"
    static let clearFilter = "Clear Filter"
    static let groupLabelsByKind = "Group Labels by Kind"
    /// The help of the profile in use, in the bar at the sidebar's foot.
    static let profileInUseHelp = "The model profile documents are read with, and requests without a profile of their own, "
        + "as Settings › Models chooses it"
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
    static let chooseFolders = "Your folders, and how Arrumator runs"
    static let ready = "Ready"
    static let readyIntro = "Arrumator lives in the menu bar. Open it to see what was filed, find documents by their labels, "
        + "and answer documents that need you."
    static let readyIntroWithoutMenuBar = "The menu bar has no room for Arrumator's icon, so open it from the Dock or by opening it "
        + "again. Its window shows what was filed, finds documents by their labels, and asks about documents that need you."
    static let connectOllama = "Connect Ollama"
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
    static let filesFooter = "Renamed, a document is named by the model from what it reads: its date, its sender and what it is. "
        + "Transliterated, a name in another script, such as Cyrillic, is written in Latin letters."
    static let readingAgain = "Reading Again"
    static let copiesFooter = "Put a document into Incoming again, as it is, and the one in the archive is read again with the "
        + "profile in use, keeping its tags and given that of the folder you put it in. The copy goes to the Trash."

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

    static let copyLogLine = "Copy Line"

    static let noTrace = "No steps are kept of how it was read: they are not brought back when the index is rebuilt "
        + "from the archive. Read Again reads it anew, and keeps the steps of that reading."

    /// The trace sheet's heading.
    static func howItWasRead(_ name: String?) -> String { name.map { "How “\($0)” was read" } ?? "How it was read" }

    /// A step of a trace, in words.
    static func traceStage(_ stage: TraceStage) -> String {
        switch stage {
        case .hash: "Fingerprinted"
        case .dedupe: "Checked for copies"
        case .extract: "Took its text"
        case .ocr: "Read the scan"
        case .vlm: "Described its images"
        case .entities: "Found dates and numbers"
        case .analyse: "Read by the model"
        case .consolidate: "Tidied its labels"
        case .embed: "Made findable by meaning"
        case .name: "Named"
        case .place: "Filed"
        case .index: "Indexed"
        case .tag: "Tagged"
        case .interpret: "Read the request"
        case .match: "Found the documents"
        case .context: "Chose what to show"
        case .answer: "Answered"
        }
    }

    /// A line of the processing log, whole, as Copy Line copies it.
    static func logLine(_ entry: LogEntry) -> String {
        "\(entry.ts.formatted(.iso8601)) \(entry.level.rawValue) \(entry.cat.rawValue) \(entry.msg) \(logFields(entry.fields))"
    }

    static let managementOnThisMacOnly = "The app starts and stops Ollama only on this Mac."

    /// Under the server field when the environment names the server: why the field and Use change nothing.
    static func serverFromEnvironment(_ variable: String) -> String {
        "This address is set by \(variable) where the app was started, and is used in place of the one saved here. "
            + "Start the app without it to choose the server here."
    }

    /// The models section's title: where they run.
    static func modelsRun(at url: URL?) -> String {
        guard let url, !OllamaEndpoint.isThisMac(url) else { return "Models (all run on this Mac)" }
        return "Models (all run on \(url.host(percentEncoded: false) ?? url.absoluteString))"
    }

    static func installed(_ name: String) -> String { "\(name) installed" }

    static let diagnostics = "Diagnostics"
    static let logDetail = "Log detail"
    static let includeText = "Include documents' text, names and labels in diagnostics"
    /// What the export holds with and without the user's consent (`DiagnosticsExporter`).
    static let includeTextNote = "Without it, the export holds nothing derived from a document. With it, traces and logs go "
        + "whole: the documents' text, names, paths, identifiers and labels, the prompts and the model's answers."
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

// MARK: Model profiles, in Settings › Models

extension Wording {
    /// What a profile's model in a role does, as Settings names it: the words of `arrumatorcli profiles`.
    static func role(_ role: ModelRole) -> String {
        switch role {
        case .chat: "Reads documents and requests"
        case .vision: "Describes images"
        case .embedding: "Finds by meaning"
        }
    }

    static let profiles = "Profiles"

    /// Under the profiles: those that come with Arrumator, by their names as they are listed now, and what becomes of a
    /// change to them and of a new one.
    static func profilesNote(predefined names: [String]) -> String {
        let predefined = switch names.count {
        case 0: ""
        case 1: "\(Format.and(names)) comes with Arrumator: change it, and Reset sets it back. "
        default: "\(Format.and(names)) come with Arrumator: change any of them, and Reset sets it back. "
        }
        return predefined + "A new profile starts as a copy of the one in use. Documents already read keep their labels: "
            + "put one into Incoming again, as it is, to have it read with the profile in use."
    }
    static let openProfileHelp = "Change its name and models"
    static let newProfile = "New Profile…"
    static let newProfileName = "Name of the new profile"
    static let cancel = "Cancel"
    static let modelPrompt = "Model, as Ollama names it"
    static let chooseInstalledModel = "Choose an installed model that can do this"
    static let modelInstalled = "Installed"
    /// A model Ollama sends elsewhere, which nothing is read with (`ModelStatus.remoteHost`).
    static func modelRunsElsewhere(at host: String) -> String { "Runs at \(host): never used" }
    static let modelRunsElsewhereHelp = "Ollama sends this model's requests beyond this Mac and the local network, so documents are "
        + "never read with it. Choose a model Ollama runs itself."
    static let embeddingNote = "Documents embedded by another model are found by meaning only once they are read again."
    static let resetProfile = "Reset"
    static let resetProfileHelp = "Give it back the name and models Arrumator comes with"
    static let removeProfile = "Remove Profile…"
    static let removeProfileHelp = "Remove this profile of yours"
    static let removeProfileInUseHelp = "Settings reads with this profile; choose another above before removing it"
    static let removeProfileConfirm = "Remove Profile"
    static let removeProfileNote = "Documents already read with it stay as they are."

    /// What a profile's row says quietly beside its name: that Settings reads with it, and that it is no longer the one
    /// Arrumator comes with.
    static func profileState(_ listing: ModelProfileListing) -> String? {
        let said = (listing.inUse ? ["in use"] : []) + (listing.predefined && listing.changed ? ["changed"] : [])
        return said.isEmpty ? nil : said.joined(separator: ", ")
    }

    /// Under the name of a new profile: what it starts as.
    static func copiesProfile(_ name: String?) -> String {
        "A copy of " + (name.map { "“\($0)”, " } ?? "") + "the profile in use. Give it other models once it is added."
    }

    /// Asks before a profile of the user's is removed.
    static func removeProfileQuestion(_ name: String) -> String { "Remove the profile “\(name)”?" }
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
    static let statisticsAppear = "Statistics appear once files have been filed."

    /// Nothing taken in the period, but files wait in Incoming.
    static func noneTakenYet(waiting: Int) -> String {
        "\(Format.count(waiting, "file")) \(waiting == 1 ? "waits" : "wait") in Incoming; statistics appear once the app has taken them."
    }
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

    /// How many files the app took in the period, and how many more wait in Incoming to be taken.
    static func arrivedIn(_ documents: Int, waiting: Int, days: Int) -> String {
        let taken = "The app took \(Format.count(documents, "file")) in the last \(days) days"
        guard waiting > 0 else { return taken + "." }
        return taken + "; \(waiting) more \(waiting == 1 ? "waits" : "wait") in Incoming."
    }

    static func stillBeingWorkedOn(_ count: Int) -> String {
        "\(count) \(count == 1 ? "is" : "are") still being worked on."
    }

    /// Where most files that came to an end without being filed stopped, and why.
    static func mostStopped(at step: String, count: Int, reason: String) -> String {
        "Of those not filed, most stopped at “\(step)”: \(reason.lowercased()) (\(count))."
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
    /// A task's request field and the conversation's question field, as VoiceOver names them.
    static let requestField = "Request"
    static let questionField = "Question"
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
    static let removeTaskNote = "Its conversation goes with it, every question and answer. What it exported stays where it was put."
    static let exportsHeading = "Exports"
    static let noLongerThere = "no longer there"
    static let takeOutHelp = "Take it out of this task"
    static let takeOut = "Take Out of Task"

    /// The × that takes a document out of a task, as VoiceOver reads it.
    static func takeOutNamed(_ document: String) -> String { "Take “\(document)” out of this task" }

    /// The × that stops arranging a task's set by a kind, as VoiceOver reads it.
    static func stopArrangingBy(_ kind: String) -> String { "Stop arranging by \(kind)" }
    static let addToTaskHelp = "Add it to the task"
    static let inTaskHelp = "In the task; click to take it out"
    static let addAllShown = "Add All With These Labels"
    static let doneAdding = "Done"
    static let nothingFound = "Nothing found. Change the request, or add documents yourself."
    static let readWith = "Read with"
    static let effort = "Effort"
    static let effortHelp = "How much the model thinks before it answers: not at all at Low, the most at High, which takes longest. "
        + "A model that cannot think reads the same at each, but for how often a wrong answer goes back to it "
        + "and how much of the archive's labels it is shown"
    static let readingProfileHelp = "The profile whose model reads the request: Settings' profile, whichever that is when the request is read, "
        + "or one of its own"

    /// An effort, as its picker names it.
    static func effort(_ effort: TaskEffort) -> String {
        switch effort {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// The choice that leaves a task to the profile Settings uses, whichever that is when the request is read, named.
    static func settingsProfile(_ name: String?) -> String { "Settings' Profile" + (name.map { " (\($0))" } ?? "") }

    /// A profile a task can be given, by its name and the model that reads with it.
    static func profileChoice(_ profile: ModelProfile) -> String { "\(profile.name) (\(profile.chatModel))" }

    /// A profile a task was given that the settings no longer list, by its id.
    static func profileGone(_ id: String) -> String { "“\(id)” (no longer in Settings)" }

    /// Which model read a task last.
    static func lastReadBy(_ model: String) -> String { "last read by \(model)" }

    /// Asks before a task is removed.
    static func removeTaskQuestion(_ name: String) -> String { "Remove “\(name)”?" }

    /// Heads the pages that narrow documents down while they are added to a task.
    static func addingTo(_ task: String) -> String { "Adding documents to “\(task)”. Choose labels in the sidebar to narrow them down." }

    /// Where a task is, at the end of its row: while it is in the queue, what the queue does with it
    /// (`SearchTaskQueueStatus.progress(of:)`); then what it found, or that it found nothing.
    static func taskOutcome(_ task: SearchTask, progress: SearchTaskProgress?) -> String {
        if let progress { return taskProgress(progress) }
        guard task.state != .failed else { return "Could not read the request" }
        return Format.count(task.documents.count, "document")
            + (task.exports.isEmpty ? "" : labelSeparator + "exported \(task.exports.count == 1 ? "once" : "\(task.exports.count) times")")
    }

    /// What the queue does with a task, at the end of its row: “Being read by qwen3.5:9b”.
    static func taskProgress(_ progress: SearchTaskProgress) -> String {
        switch progress {
        case let .reading(reading): reading.map { "Being read by \($0.model)" } ?? "Being read"
        case .waitingForOllama: waitingForOllama
        case .waitingForTurn: "Waiting for its turn"
        case .waiting: "Waiting to be read"
        }
    }

    /// What the queue does with a task, at the top of its card: by which model its request is being read, and for how
    /// long once `elapsed` is given, or what it waits for. “Reading the request with qwen3.5:9b… 2 min, 14 sec so far”.
    static func taskProgressLine(_ progress: SearchTaskProgress, elapsed: TimeInterval? = nil) -> String {
        switch progress {
        case let .reading(reading):
            (reading.map { "Reading the request with \($0.model)…" } ?? "Reading the request…") + (elapsed.map { " \(readingTime($0)) so far" } ?? "")
        case .waitingForOllama: "Waiting for Ollama: it cannot be reached, and is tried again shortly"
        case .waitingForTurn: "Waiting to be read: another request is being read first"
        case .waiting: "Waiting to be read…"
        }
    }

    /// How long a request has been read, to the second, in at most two units: “2 min, 14 sec”, “1 hr, 3 min”.
    private static func readingTime(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
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
        guard let value = group.value else { return without(kind) }
        return SearchPlan.timeKinds.contains(kind) ? value : label(DocumentLabel(kind: kind, value: value))
    }

    // MARK: Conversation

    static let documentsSection = "Documents"
    static let conversationSection = "Conversation"
    static let askAboutPrompt = "Ask about these documents: summarize, translate, compare, draft an e-mail, or find more like them"
    static let ask = "Ask"
    static let noQuestionsYet = "Ask anything about the documents of this task, in your own words. Each answer is drawn from the "
        + "documents in it when the question is answered: add or take out documents to change what the next answer sees."
    static let askAgain = "Ask Again"
    static let askAgainHelp = "Answer it again, from the documents in the task as they are now"
    static let stopAnswer = "Stop"
    static let stopAnswerHelp = "Stop answering; what came of the answer is kept"
    static let copyAnswer = "Copy"
    static let copyAnswerHelp = "Copy the answer, to use it elsewhere"
    static let drawnFrom = "Drawn from"
    static let answeredAfterLater = "Answered again after the questions below were answered: they followed its earlier answer."

    /// A document an answer draws on, under the pointer: its whole name, as the line may be too short for it.
    static func openNamedDocument(_ name: String) -> String { "Open \(name)" }
    static let addAll = "Add All"
    static let addFoundHelp = "Add it to the task, so the next answers see it"
    static let inTaskAlready = "In the task"
    static let thinking = "Thinking…"
    static let clearConversation = "Clear Conversation…"
    static let clearConversationConfirm = "Clear Conversation"
    static let clearConversationNote = "Every question and answer goes. The documents stay in the task."
    static let answeringRow = "Answering a question"

    /// Asks before a task's conversation is cleared.
    static func clearConversationQuestion(_ task: String) -> String { "Clear the conversation about “\(task)”?" }

    /// What an answer that asked for more documents looked for, and what it found outside the task.
    static func found(_ finding: TurnFinding) -> String {
        if let problem = finding.problem { return "Looked for “\(finding.request)”, but could not: \(problem)" }
        guard !finding.documents.isEmpty else { return "Looked for “\(finding.request)”: nothing outside this task" }
        return "Looked for “\(finding.request)”: \(Format.count(finding.documents.count, "document")) outside this task"
    }

    /// Why an answer is incomplete, or why there is none.
    static func turnProblem(_ turn: TaskTurn) -> String? {
        turn.problem.map { (turn.state == .failed ? "Not answered: " : "Incomplete: ") + $0 }
    }

    /// What the queue does with a question, where its answer will be: by which model it is being answered, and for how
    /// long once `elapsed` is given, or what it waits for.
    /// Until the model begins, the question waits for it, which may be loading or reading documents first.
    static func turnProgressLine(_ progress: TurnProgress, begun: Bool = true, elapsed: TimeInterval? = nil) -> String {
        switch progress {
        case let .answering(answering):
            (answering.map { begun ? "Answering with \($0.model)…" : "Waiting for \($0.model) to begin: it may be loading, or busy reading documents…" }
                ?? "Being answered…") + (elapsed.map { " \(readingTime($0)) so far" } ?? "")
        case let .waitingForOllama(until):
            until.map { "Waiting for Ollama: it cannot be reached, and is tried again at \($0.formatted(date: .omitted, time: .shortened))" }
                ?? "Waiting for Ollama: trying to reach it again…"
        case .waitingForTurn: "Waiting to be answered: something else is being read or answered first"
        case .waiting: "Waiting to be answered…"
        }
    }

    /// An export, as a task's card lists it.
    static func export(_ export: SearchTaskExport) -> String {
        let format = export.format == .zip ? "ZIP archive" : "folder"
        return "\(export.at.formatted(date: .abbreviated, time: .shortened)) · \(format) · \(Format.count(export.files.count, "document"))"
            + (export.skipped.isEmpty ? "" : ", \(export.skipped.count) not copied")
    }
}
