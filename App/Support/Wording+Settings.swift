import ArrumatorCore
import Foundation

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
    /// Under the switches, while one is on and macOS does not let the app notify (`NotificationPermission`).
    static let notificationsRefused = "macOS does not let Arrumator show notifications, so none are shown. Allow them for "
        + "Arrumator in System Settings › Notifications."
    static let notificationsUnavailable = "macOS would not let Arrumator ask to show notifications, so none are shown. Once "
        + "Arrumator is listed in System Settings › Notifications, allow them there."
    static let openNotificationSettings = "Open Notification Settings"
    static let choose = "Choose…"

    static func chooseFolder(_ name: String) -> String { "Choose the \(name) folder" }

    static let files = "Files"
    static let renameFiles = "Rename files"
    static let transliterate = "Transliterate names to Latin letters"
    static let filesFooter = "Renamed, a document is named by the model from what it reads: its date, its sender and what it is. "
        + "Transliterated, a name in another script, such as Cyrillic, is written in Latin letters."
    static let readingAgain = "Reading Again"
    static let copiesFooter = "Put a document into Incoming again, as it is, and the one in the archive is read again from "
        + "its file with the profile in use. Once it is read, its name, labels, text and meaning take the place of those it had, "
        + "keeping its tags and given that of the folder you put it in. The copy goes to the Trash."
    static let readAllAgain = "Read All Documents Again…"
    static let readAllAgainQuestion = "Read every document in the archive again?"

    /// What reading every document again does, under the question that asks for it.
    static func readAllAgainNote(profile: String?) -> String {
        "Each document is read from its file with the profile " + (profile.map { "“\($0)”" } ?? "in use")
            + ", renamed, and given only the labels this reading finds, also in place of those you corrected; its tags stay. "
            + "Documents you left for later stay as they are. New files still come first."
    }

    /// What reading every document again queued.
    static func readAllAgainQueued(_ count: Int) -> String {
        count == 0 ? "No document to queue: every document of the archive waits to be read already, or it has none."
            : "\(Format.count(count, "document")) queued to be read again. Incoming shows how many are left."
    }

    static let ollama = "Ollama"
    static let status = "Status"
    static let server = "Server"
    static let useServer = "Use"
    static let management = "Management"
    static let launchOllamaApp = "Start the Ollama app when needed"
    static let spawnServe = "Run 'ollama serve' myself (managed)"
    static let neverStart = "Never start it"
    static let startOllama = "Start / check Ollama"
    /// What the button does when the app never starts the server: on another machine, or Management says never.
    static let checkOllama = "Check Ollama"
    static let checkingOllama = "Checking Ollama"
    /// What the button's last check found, and when, to the second, so each press says it was made.
    static func ollamaChecked(_ state: OllamaState, at date: Date) -> String {
        "Checked at \(date.formatted(date: .omitted, time: .standard)): \(state.summary)"
    }
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
        case .review: "Waits for you"
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

    /// Under the profiles: those that come with Arrumator, by the names they come with
    /// (`ModelProfileActions.predefinedNames`), and what becomes of a change to them and of a new one.
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
