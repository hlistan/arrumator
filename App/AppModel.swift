import AppKit
import ArrumatorCore
import ArrumatorRuntime
import Foundation
import Observation

/// Main-actor state shared by the menu bar and the windows. Owns the runtime and mirrors its streams.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    static let version = AppVersion.of(.main)

    var phase: Phase = .starting
    private(set) var runtime: ArrumatorRuntime?
    var settings: AppSettings?
    /// What the ingest worker is doing: the file it has in hand and its stage, how many wait, and what holds it up.
    /// Taking a file and moving it from stage to stage records nothing in History, so the Incoming page reloads on this
    /// too (`ingestActivity`).
    var ingest = IngestStatus.idle
    /// What the search task queue is doing: the request it reads and by which model, what waits, and whether it waits for
    /// Ollama. Taking a task to read records nothing in History, so pages that show tasks reload on this too
    /// (`taskActivity`).
    var taskQueue = SearchTaskQueueStatus.idle
    /// What the conversation queue is doing: the question it answers and by which model, what waits, and whether it
    /// waits for Ollama; without the answer being written (`ConversationQueueStatus.settled`), which `answerSoFar` has, so
    /// what shows this changes as a question is taken or done, not with every word.
    var conversation = ConversationQueueStatus.idle
    /// What has come so far of the answer being written, which only the question it answers shows.
    var answerSoFar: AnswerProgress?
    var ollama = OllamaState.unknown
    var recent: [EventRecord] = []
    var reviewCount = 0
    /// Pairs of alike labels waiting for the user to merge them or keep them apart.
    var labelSuggestionCount = 0
    /// Bumped on every database change, and when another archive is opened; views reload with `.task(id:)`.
    var activity: Int64 = 0
    /// What the Tasks page and a task's card reload on with `.task(id:)`: History growing, and the search task queue's
    /// status changing, as it does when a task's request starts being read.
    var taskActivity: String { "\(activity)|\(taskQueue)" }
    /// What a task's conversation reloads on with `.task(id:)`: History growing, and the conversation queue taking a
    /// question or ending its answer; not each word of the answer being written.
    var conversationActivity: String { "\(activity)|\(conversation)" }
    /// What the Incoming page reloads on with `.task(id:)`: History growing, and the ingest worker's status changing, as it
    /// does when the worker takes a file, moves it to its next stage or finishes it.
    var ingestActivity: String { "\(activity)|\(ingest)" }
    var destination: Destination = .incoming
    /// The document opened in place as a card. One at a time, as in Things.
    var openDocument: Int64?
    /// The label opened in place as a card on the Labels page.
    var openLabel: DocumentLabel?
    /// The search task opened in place as a card on the Tasks page.
    var openTask: Int64?
    /// The search task whose set documents are being added to, as the user narrows them down by labels in the sidebar:
    /// every document row then shows whether it is in the set, and adds it or takes it out.
    private(set) var collecting: SearchTask?
    /// The labels chosen in the sidebar, in the order they were chosen: the documents shown have every one, and the
    /// sidebar offers only the labels those documents have.
    var labelSelection: [DocumentLabel] = []
    weak var presenter: (any WindowPresenting)?
    /// True when the menu bar has no room left for the icon, so the Dock icon is the only way in.
    var menuBarIconHidden = false
    private var streams: [Task<Void, Never>] = []
    private var watcherStart: Task<Void, Never>?
    /// True once the folder watchers are running. Starting them opens the archive and Incoming folders, which macOS
    /// may hold until the user answers a permission prompt.
    private(set) var watching = false
    /// True while the app closes one archive and opens another.
    private(set) var switchingArchive = false
    private let notifications = NotificationService()

    func start() async {
        guard runtime == nil else { return }
        do {
            let environment = RuntimeEnvironment.current
            let runtime = try await ArrumatorRuntime.bootstrap(appVersion: Self.version, environment: environment, echoLogsToStderr: false,
                                                               trash: environment.trash(orElse: SystemTrash()))
            self.runtime = runtime
            settings = await runtime.settings.current
            observe(runtime)
            phase = .ready
            await refresh()
            if settings?.onboardingCompleted == true { startWatching(runtime) }
        } catch {
            phase = .failed(error.localizedDescription)
            Log.error(.app, "Startup failed", ["error": error.localizedDescription])
        }
    }

    /// Called when onboarding finishes.
    func finishOnboarding() async {
        guard let runtime else { return }
        await update { $0.onboardingCompleted = true }
        startWatching(runtime)
    }

    /// Opens the archive and starts the work off the main actor (`ArrumatorRuntime.openAndStart()`): macOS blocks the
    /// first access to the Documents folder until the user answers its permission prompt, and the windows and the menu
    /// bar item must appear regardless. The runtime owns that step, so quitting or switching archives meanwhile stops it,
    /// and what it says comes only while the runtime it began on is still the app's.
    private func startWatching(_ runtime: ArrumatorRuntime) {
        guard watcherStart == nil else { return }
        watcherStart = Task.detached { [weak self] in
            let unread: String?
            do {
                try await runtime.openAndStart()
                unread = nil
            } catch is CancellationError {
                // Stopped first, by quitting or by a switch of archives: nothing started.
                return
            } catch {
                unread = error.localizedDescription
            }
            await MainActor.run {
                guard let self, self.runtime === runtime else { return }
                if let unread { self.lastError = Wording.failure(Wording.readArchiveAction, unread) }
                self.watching = true
            }
        }
    }

    /// Files into the archive at `path` from now on. Its history comes with it: the
    /// runtime open on this archive stops and one open on the other takes its place.
    func switchArchive(to path: String) async {
        guard let runtime, !switchingArchive,
              URL(fileURLWithPath: path.expandingTilde).standardizedFileURL.path != runtime.archive.path else { return }
        switchingArchive = true
        defer { switchingArchive = false }
        // An archive still being opened stops being opened, and its runtime starts nothing after (`stop()`).
        do {
            let switched = try await runtime.switchArchive(to: path)
            let next = switched.runtime
            watcherStart = nil
            watching = false
            self.runtime = next
            settings = await next.settings.current
            ingest = .idle
            taskQueue = .idle
            conversation = .idle
            answerSoFar = nil
            openDocument = nil
            observe(next)
            activity &+= 1
            // The archive left, when its record files could not be written, is named, as they wait for it to be opened.
            lastError = switched.unwritten.map { Wording.failure(Wording.switchArchivesAction, $0.note) }
            await refresh()
            if settings?.onboardingCompleted == true { startWatching(next) }
        } catch {
            lastError = Wording.failure(Wording.switchArchivesAction, error.localizedDescription)
            Log.error(.ui, "Could not switch archives", ["error": error.localizedDescription])
            // A switch that failed once this archive had stopped starts it again, reading it first if it was being read
            // then: the app follows that start as it followed the first.
            if !watching, settings?.onboardingCompleted == true {
                watcherStart = nil
                startWatching(runtime)
            }
        }
    }

    private func observe(_ runtime: ArrumatorRuntime) {
        streams.forEach { $0.cancel() }
        streams = [
            Task { [weak self] in
                for await status in await runtime.coordinator.statusUpdates() { self?.ingest = status }
            },
            Task { [weak self] in
                for await status in await runtime.taskQueue.statusUpdates() { self?.taskQueue = status }
            },
            Task { [weak self] in
                for await status in await runtime.conversationQueue.statusUpdates() {
                    guard let self else { return }
                    // Set only when changed: setting a value the same as it was still tells every view that shows it.
                    if conversation != status.settled { conversation = status.settled }
                    if answerSoFar != status.answering?.progress { answerSoFar = status.answering?.progress }
                }
            },
            Task { [weak self] in
                for await state in await runtime.lifecycle.states() { self?.ollama = state }
            },
            Task { [weak self] in
                for await changed in await runtime.settings.changes() { self?.settings = changed }
            },
            Task { [weak self] in
                for await _ in runtime.database.activity() {
                    guard let self else { return }
                    self.activity &+= 1
                    await self.refresh()
                }
            },
        ]
    }

    func refresh() async {
        guard let runtime else { return }
        do {
            let events = try await runtime.services.history.events(
                limit: runtime.config.interface.notificationEvents, kinds: [.filed, .needsReview, .duplicate, .failed, .userMoved])
            await notifications.announce(events, previous: recent, settings: settings)
            recent = events
            reviewCount = try await runtime.services.documents.reviewCount()
            labelSuggestionCount = try await runtime.services.labels.suggestions().count
            if let id = collecting?.id {
                collecting = try await runtime.searchTasks.store.task(id: id)
            }
        } catch {
            Log.error(.ui, "Refresh failed", ["error": error.localizedDescription])
        }
    }

    /// Changes settings that have no action of their own, as `arrumatorcli settings` does: saved and recorded once in
    /// History, in words made of what changed (`SettingsActions.change(_:)`). Settings the store refuses are shown, and
    /// the settings in force stay as they were.
    func update(_ mutate: @escaping @Sendable (inout AppSettings) -> Void) async {
        await changeSettings(Wording.saveSettingsAction) { _ = try await $0.settingsActions.change(mutate) }
    }

    /// Pauses or resumes filing, as `arrumatorcli settings --paused` does (`ArrumatorRuntime.setPaused`).
    func setPaused(_ paused: Bool) async {
        await changeSettings(paused ? Wording.pause : Wording.resume) { try await $0.setPaused(paused) }
    }

    // MARK: Actions with user-visible errors

    var lastError: String?

    /// Does what the user asked, through Runtime and Core: what it gave, or nil when it failed, and then why it failed is
    /// shown (`lastError`).
    @discardableResult
    func perform<T: Sendable>(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime) async throws -> T) async -> T? {
        guard let runtime else { return nil }
        var result: T?
        do {
            result = try await action(runtime)
            lastError = nil
        } catch {
            let error = await runtime.database.explained(error)
            lastError = Wording.failure(what, error.localizedDescription)
            Log.error(.ui, "An action failed", ["action": what, "error": error.localizedDescription])
        }
        await refresh()
        return result
    }

    /// Changes the settings through one of their actions (`SettingsActions`, `ModelProfileActions`, pausing), as
    /// `perform` does, and shows the settings in force at once, rather than once their stream says they changed, so a
    /// control the store refused goes back to what is saved.
    @discardableResult
    func changeSettings<T: Sendable>(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime) async throws -> T) async -> T? {
        let result = await perform(what, action)
        if let runtime { settings = await runtime.settings.current }
        return result
    }

    /// Reads for display. A failure is reported instead of leaving a view empty or spinning forever.
    func load<T: Sendable>(_ what: String, _ read: (ArrumatorRuntime) async throws -> T) async -> T? {
        guard let runtime else { return nil }
        do {
            return try await read(runtime)
        } catch is CancellationError {
            // The view asked again before this finished; the newer read is the one that matters.
            return nil
        } catch {
            lastError = Wording.failure(what, error.localizedDescription)
            Log.error(.ui, "A read for display failed", ["action": what, "error": error.localizedDescription])
            return nil
        }
    }

    /// Switches the main window to a page, closing any open card. Any other page than the chosen labels' lets go of
    /// them, and any page but those the labels narrow down ends adding documents to a task.
    func go(_ destination: Destination) {
        self.destination = destination
        openDocument = nil
        openLabel = nil
        openTask = nil
        if destination != .labelled { labelSelection = [] }
        if destination != .labelled && destination != .processed { collecting = nil }
    }

    /// Starts adding documents to a task's set: the window shows every processed document, to be narrowed down by
    /// labels in the sidebar, each row with a way to add it or take it out.
    func collect(for task: SearchTask) {
        go(.processed)
        collecting = task
    }

    /// Ends adding documents, and shows the task again.
    func finishCollecting() {
        let id = collecting?.id
        go(.tasks)
        openTask = id
    }

    /// Shows a search task opened in place on the Tasks page.
    func open(task id: Int64) {
        go(.tasks)
        openTask = id
        show(.main)
    }

    /// Shows a label opened in place on the Labels page.
    func open(label: DocumentLabel) {
        go(.labels)
        openLabel = label
        show(.main)
    }

    /// Chooses a label in the sidebar, narrowing the documents shown to those that also have it, or lets go of one
    /// already chosen. With none left, the window shows every processed document again.
    func choose(_ label: DocumentLabel) {
        let selection = labelSelection.contains(label) ? labelSelection.filter { $0 != label } : labelSelection + [label]
        if selection.isEmpty {
            clearLabels()
        } else {
            go(.labelled)
            labelSelection = selection
        }
    }

    /// Lets go of every label chosen in the sidebar: the window shows every processed document again.
    func clearLabels() { go(.processed) }

    /// Shows the documents that have a label, as choosing it alone in the sidebar does.
    func browse(_ label: DocumentLabel) {
        go(.labelled)
        labelSelection = [label]
        show(.main)
    }

    /// Shows a document opened in place on a page, bringing the main window forward.
    func open(document id: Int64?, on destination: Destination) {
        go(destination)
        openDocument = id
        show(.main)
    }

    func show(_ window: WindowID) { presenter?.show(window) }
    func close(_ window: WindowID) { presenter?.close(window) }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    /// Puts `text` on the clipboard, in place of what was there.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// What the search tasks are at work on, seen from any page: a request being read, else a question being answered;
    /// nil while neither is.
    var tasksAtWork: String? {
        if let reading = taskQueue.reading { return Wording.readingRequest(with: reading.model) }
        guard let answering = conversation.answering else { return nil }
        // Tried again while Ollama is away, a question waits for it until the model begins, as the question itself says.
        if conversation.waitingForOllama, !answering.progress.begun { return Wording.waitingForOllama }
        return Wording.answeringQuestion(with: answering.model)
    }

    var statusSymbol: String {
        if case .failed = phase { return "exclamationmark.triangle" }
        if settings?.paused == true { return "pause.circle" }
        switch ollama {
        case .unhealthy, .notInstalled, .unreachable: return "exclamationmark.triangle"
        default: break
        }
        if ingest.current != nil { return "tray.and.arrow.down.fill" }
        return reviewCount > 0 ? "tray.full" : "tray"
    }

    /// Why the app is not filing right now, or nil when everything is working.
    var attention: String? {
        if case let .failed(why) = phase { return why }
        if settings?.onboardingCompleted == true, !watching { return Wording.waitingForFolders }
        if settings?.paused == true { return Wording.paused }
        if let reason = ingest.powerPauseReason { return Wording.waiting(reason) }
        if ingest.waitingForOllama || !ollama.isReady { return ollama.summary }
        return nil
    }

    /// What the app is doing, in the menu bar popover: a document being filed first, then a search request being read or a
    /// question about a task's documents being answered.
    var statusLine: String {
        if case let .failed(why) = phase { return why }
        if settings?.onboardingCompleted == true, !watching { return Wording.startingForFolders }
        if settings?.paused == true { return Wording.paused }
        if let reason = ingest.powerPauseReason { return Wording.waiting(reason) }
        if ingest.waitingForOllama || taskQueue.waitingForOllama || conversation.waitingForOllama { return Wording.waitingForOllama }
        if let current = ingest.current {
            return Wording.working(on: (current.path as NSString).lastPathComponent, stage: Wording.doing(current.stage))
        }
        if let work = tasksAtWork { return work }
        return ingest.queued > 0 ? Wording.queued(ingest.queued) : Wording.idle
    }
}

/// What the main window shows. The sidebar lists `lists`, then the labels that choose `labelled`; history and
/// statistics are reached from the sidebar's menu.
enum Destination: Hashable {
    case incoming, review, processed, labels, tasks
    case labelled
    case history, statistics

    static let lists: [Destination] = [.incoming, .review, .processed, .labels, .tasks]
}
