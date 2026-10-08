import AppKit
import ArrumatorCore
import ArrumatorRuntime
import Foundation
import Observation

/// Everything the app shows and has open of the archive it is on: what the runtime's streams last said of it, the page
/// and the card open, the labels chosen and the task documents are added to. A switch of archives replaces it whole
/// (`AppModel.switchArchive`), so nothing of one archive is shown, opened or acted on in the next: a task or document of
/// the same number there, or a filing already announced.
@Observable
final class ArchiveSession {
    /// What the ingest worker is doing: the file it has in hand and its stage, how many wait, and what holds it up.
    /// Taking a file and moving it from stage to stage records nothing in History, so the Incoming page reloads on this
    /// too (`AppModel.ingestActivity`).
    var ingest = IngestStatus.idle
    /// What the search task queue is doing: the request it reads and by which model, what waits, and whether it waits for
    /// Ollama. Taking a task to read records nothing in History, so pages that show tasks reload on this too
    /// (`AppModel.taskActivity`).
    var taskQueue = SearchTaskQueueStatus.idle
    /// What the conversation queue is doing: the question it answers and by which model, what waits, and whether it
    /// waits for Ollama; without the answer being written (`ConversationQueueStatus.settled`), which `answerSoFar` has, so
    /// what shows this changes as a question is taken or done, not with every word.
    var conversation = ConversationQueueStatus.idle
    /// What has come so far of the answer being written, which only the question it answers shows.
    var answerSoFar: AnswerProgress?
    var ollama = OllamaState.unknown
    /// The user's asking to check Ollama, or start it, as the lifecycle says (`askings()`).
    var ollamaAsking = OllamaAsking()
    /// Whether the runtime's work runs, the folder watchers among it, as the runtime says (`workUpdates()`): not while
    /// it opens the archive and Incoming folders, which macOS may hold until the user answers a permission prompt, nor
    /// when the archive's index could not be rebuilt from it, nor while its folder is away.
    var work = RuntimeWork.idle
    /// The latest filings and the like, to announce those that come after them.
    var recent: [EventRecord] = []
    /// How many documents wait for the user, those the user set aside left out (`DocumentStore.waitingCount`).
    var reviewCount = 0
    /// The record files History last said cannot be read, by their paths (`ArchiveRecords.unreadableRecorded`).
    var unreadableRecords: [String] = []
    var destination: Destination = .incoming
    /// The document opened in place as a card. One at a time, as in Things.
    var openDocument: Int64?
    /// The label opened in place as a card on the Labels page.
    var openLabel: DocumentLabel?
    /// The search task opened in place as a card on the Tasks page.
    var openTask: Int64?
    /// What each task's card shows, its documents or its conversation, as the user last chose: kept here, not by the
    /// card, which is built anew when its task moves between In Progress and Earlier, as Find Again moves it.
    var taskCardSections: [Int64: TaskCard.Section] = [:]
    /// The document a card was last asked to read again, by its number and name, until another page is shown: a page
    /// it leaves, as Needs You, which lists it no longer once it waits in Incoming, says where it went.
    var readAgain: (id: Int64, name: String)?
    /// The search task whose set documents are being added to, as the user narrows them down by labels in the sidebar:
    /// every document row then shows whether it is in the set, and adds it or takes it out.
    fileprivate(set) var collecting: SearchTask?
    /// The labels chosen in the sidebar, in the order they were chosen: the documents shown have every one, and the
    /// sidebar offers only the labels those documents have.
    var labelSelection: [DocumentLabel] = []
}

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
    /// What is shown of the archive the app is on.
    private(set) var session = ArchiveSession()
    /// Bumped on every database change, and when another archive is opened; views reload with `.task(id:)`.
    var activity: Int64 = 0
    /// What the Tasks page and a task's card reload on with `.task(id:)`: History growing, and the search task queue's
    /// status changing, as it does when a task's request starts being read.
    var taskActivity: String { "\(activity)|\(session.taskQueue)" }
    /// What a task's conversation reloads on with `.task(id:)`: History growing, and the conversation queue taking a
    /// question or ending its answer; not each word of the answer being written.
    var conversationActivity: String { "\(activity)|\(session.conversation)" }
    /// What the Incoming page reloads on with `.task(id:)`: History growing, and the ingest worker's status changing, as it
    /// does when the worker takes a file, moves it to its next stage or finishes it.
    var ingestActivity: String { "\(activity)|\(session.ingest)" }
    /// Set by the Filter Labels command until the sidebar has put the cursor in its filter.
    var labelFilterWanted = false
    weak var presenter: (any WindowPresenting)?
    /// True when the menu bar has no room left for the icon, so the Dock icon is the only way in.
    var menuBarIconHidden = false
    private var streams: [Task<Void, Never>] = []
    private var watcherStart: Task<Void, Never>?
    /// True while the app closes one archive and opens another.
    private(set) var switchingArchive = false
    /// Posts notifications, and says whether macOS lets it.
    let notifications = NotificationService()

    /// The archive the app is on: the runtime's, which it acts on whatever the settings name later.
    var archive: URL? { runtime?.archive }

    func start() async {
        guard runtime == nil else { return }
        phase = .starting
        do {
            let environment = RuntimeEnvironment.current
            let runtime = try await ArrumatorRuntime.bootstrap(appVersion: Self.version, environment: environment, echoLogsToStderr: false,
                                                               resolver: SystemHostResolver(),
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

    /// Starts again after a start that failed, as the window that says why offers; once started, the app is set up if it
    /// was not yet, as at launch.
    func retryStart() async {
        await start()
        if phase == .ready, settings?.onboardingCompleted != true { show(.onboarding) }
    }

    /// Called when onboarding finishes: the archive is set up, its folder made when it is not there
    /// (`ArrumatorRuntime.finishOnboarding()`), and opened.
    func finishOnboarding() async {
        guard let runtime else { return }
        await changeSettings(Wording.saveSettingsAction) { try await $0.finishOnboarding() }
        startWatching(runtime)
    }

    /// Opens the archive again, as at launch, after it could not be opened: its folder away, as on a disk not
    /// connected, or its index not rebuilt from it. The runtime starts its work once it can (`openAndStart()`).
    func tryOpeningAgain() {
        guard let runtime, settings?.onboardingCompleted == true, session.work == .away || session.work == .refused else { return }
        watcherStart = nil
        startWatching(runtime)
    }

    /// Opens the archive and starts the work off the main actor (`ArrumatorRuntime.openAndStart()`): macOS blocks the
    /// first access to the Documents folder until the user answers its permission prompt, and the windows and the menu
    /// bar item must appear regardless. The runtime owns that step, so quitting or switching archives meanwhile stops it,
    /// and what it says comes only while the runtime it began on is still the app's. Whether the work then runs, the
    /// runtime says (`ArchiveSession.work`): the archive may have been read with the index refused, so nothing runs.
    private func startWatching(_ runtime: ArrumatorRuntime) {
        guard watcherStart == nil else { return }
        watcherStart = Task.detached { [weak self] in
            do {
                try await runtime.openAndStart()
            } catch is CancellationError {
                // Stopped first, by quitting or by a switch of archives: nothing started.
            } catch {
                let unread = error.localizedDescription
                await MainActor.run {
                    guard let self, self.runtime === runtime else { return }
                    self.lastError = Wording.failure(Wording.readArchiveAction, unread)
                }
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
            // The runtime and everything shown of its archive change together, before anything is awaited, so a refresh
            // that comes meanwhile never pairs the next runtime with what was shown of the archive left.
            self.runtime = next
            session = ArchiveSession()
            observe(next)
            settings = await next.settings.current
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
            if session.work != .running, settings?.onboardingCompleted == true {
                watcherStart = nil
                startWatching(runtime)
            }
        }
    }

    /// Follows the runtime's streams into the session open now; a value a stream of the runtime left still delivers
    /// lands in the session it was subscribed for, never in the next.
    private func observe(_ runtime: ArrumatorRuntime) {
        streams.forEach { $0.cancel() }
        let session = session
        streams = [
            Task {
                for await status in await runtime.coordinator.statusUpdates() { session.ingest = status }
            },
            Task {
                for await status in await runtime.taskQueue.statusUpdates() { session.taskQueue = status }
            },
            Task {
                for await status in await runtime.conversationQueue.statusUpdates() {
                    // Set only when changed: setting a value the same as it was still tells every view that shows it.
                    if session.conversation != status.settled { session.conversation = status.settled }
                    if session.answerSoFar != status.answering?.progress { session.answerSoFar = status.answering?.progress }
                }
            },
            Task {
                for await state in await runtime.lifecycle.states() { session.ollama = state }
            },
            Task {
                for await asking in await runtime.lifecycle.askings() { session.ollamaAsking = asking }
            },
            Task { [weak self] in
                var refused = false
                for await work in await runtime.workUpdates() {
                    session.work = work
                    if work == .refused || work == .away { refused = true }
                    // Once the work runs where it was refused, why it was refused no longer holds.
                    if work == .running, refused {
                        refused = false
                        self?.lastError = nil
                    }
                }
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
        let session = session
        do {
            let events = try await runtime.services.history.events(
                limit: runtime.config.interface.notificationEvents, kinds: [.filed, .needsReview, .duplicate, .failed, .userMoved])
            // On its own, so that waiting for macOS, which may never answer an asking, never holds up the lists.
            let notifications = notifications, settings = settings, previous = session.recent
            Task {
                await notifications.announce(events, previous: previous, settings: settings,
                                             askTimeout: runtime.config.interface.notificationAskTimeout)
            }
            session.recent = events
            session.reviewCount = try await runtime.services.documents.waitingCount()
            session.unreadableRecords = try await runtime.records.unreadableRecorded().map(\.path)
            if let id = session.collecting?.id {
                session.collecting = try await runtime.searchTasks.store.task(id: id)
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
            lastError = Wording.failure(what, Wording.reason(error))
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

    /// Reads for display: what was read, or nil when there is nothing new to show, and then the view keeps what it
    /// shows. That is so when the read was cancelled, as `.task(id:)` cancels it when the view asks again or goes, and
    /// when it failed, which is reported instead. A caller assigns only what it is given, never a fallback in place of
    /// nil, which would empty a list or close a card each time a reload is cancelled.
    func load<T: Sendable>(_ what: String, _ read: (ArrumatorRuntime) async throws -> T) async -> T? {
        guard let runtime else { return nil }
        do {
            let read = try await read(runtime)
            // Cancelled while it read, as when the view asked again: the newer read is the one that matters.
            guard !Task.isCancelled else { return nil }
            return read
        } catch is CancellationError {
            // The view asked again before this finished, or went; the newer read is the one that matters.
            return nil
        } catch {
            // Cancelled while the read failed for that reason, as a query interrupted: nothing to report.
            guard !Task.isCancelled else { return nil }
            lastError = Wording.failure(what, error.localizedDescription)
            Log.error(.ui, "A read for display failed", ["action": what, "error": error.localizedDescription])
            return nil
        }
    }

    /// Switches the main window to a page, closing any open card. Any other page than the chosen labels' lets go of
    /// them, and any page but those the labels narrow down ends adding documents to a task.
    func go(_ destination: Destination) {
        session.destination = destination
        session.openDocument = nil
        session.openLabel = nil
        session.openTask = nil
        session.readAgain = nil
        if destination != .labelled { session.labelSelection = [] }
        if destination != .labelled && destination != .processed { session.collecting = nil }
    }

    /// Starts adding documents to a task's set: the window shows every processed document, to be narrowed down by
    /// labels in the sidebar, each row with a way to add it or take it out.
    func collect(for task: SearchTask) {
        go(.processed)
        session.collecting = task
    }

    /// Ends adding documents, and shows the task again.
    func finishCollecting() {
        let id = session.collecting?.id
        go(.tasks)
        session.openTask = id
    }

    /// Shows a search task opened in place on the Tasks page.
    func open(task id: Int64) {
        go(.tasks)
        session.openTask = id
        show(.main)
    }

    /// Shows a label opened in place on the Labels page.
    func open(label: DocumentLabel) {
        go(.labels)
        session.openLabel = label
        show(.main)
    }

    /// Chooses a label in the sidebar, narrowing the documents shown to those that also have it, or lets go of one
    /// already chosen. With none left, the window shows every processed document again.
    func choose(_ label: DocumentLabel) {
        let chosen = session.labelSelection
        let selection = chosen.contains(label) ? chosen.filter { $0 != label } : chosen + [label]
        if selection.isEmpty {
            clearLabels()
        } else {
            go(.labelled)
            session.labelSelection = selection
        }
    }

    /// Lets go of every label chosen in the sidebar: the window shows every processed document again.
    func clearLabels() { go(.processed) }

    /// Shows the documents that have a label, as choosing it alone in the sidebar does.
    func browse(_ label: DocumentLabel) {
        go(.labelled)
        session.labelSelection = [label]
        show(.main)
    }

    /// Shows a document opened in place on a page, bringing the main window forward.
    func open(document id: Int64?, on destination: Destination) {
        go(destination)
        session.openDocument = id
        show(.main)
    }

    /// Brings the main window forward with the cursor in the sidebar's label filter (Edit › Filter Labels).
    func filterLabels() {
        labelFilterWanted = true
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

    // MARK: What the app is doing

    /// What the runtime is doing, as Core orders it (`RuntimeActivity`).
    var runtimeActivity: RuntimeActivity {
        RuntimeActivity(onboarded: settings?.onboardingCompleted == true, paused: settings?.paused == true, work: session.work,
                        ingest: session.ingest, taskQueue: session.taskQueue, conversation: session.conversation,
                        ollama: session.ollama, needsYou: session.reviewCount, unreadableRecords: session.unreadableRecords)
    }

    /// What the search tasks are at work on, seen from any page; nil while neither a request is read nor a question
    /// answered or tried, as while a question only waits to try Ollama again, which the popover says.
    var tasksAtWork: String? {
        guard let work = runtimeActivity.tasksWork else { return nil }
        if case .waitingForOllama(until: _?) = work { return nil }
        return Wording.tasksWork(work)
    }

    var statusSymbol: String {
        if case .failed = phase { return RuntimeActivity.Mark.problem.symbol }
        return runtimeActivity.mark.symbol
    }

    /// Why the app is not filing right now, or nil when everything is working.
    var attention: String? {
        if case let .failed(why) = phase { return why }
        return runtimeActivity.attention.map(Wording.attention)
    }

    /// What the app is doing, in the menu bar popover: a document being filed first, then a search request being read or a
    /// question about a task's documents being answered.
    var statusLine: String {
        if case let .failed(why) = phase { return why }
        return Wording.now(runtimeActivity.now)
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
