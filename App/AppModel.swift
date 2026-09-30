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
    var ingest = IngestStatus.idle
    var ollama = OllamaState.unknown
    var recent: [EventRecord] = []
    var reviewCount = 0
    /// Pairs of alike labels waiting for the user to merge them or keep them apart.
    var labelSuggestionCount = 0
    /// Bumped on every database change, and when another archive is opened; views reload with `.task(id:)`.
    var activity: Int64 = 0
    var destination: Destination = .incoming
    /// The document opened in place as a card. One at a time, as in Things.
    var openDocument: Int64?
    /// The label opened in place as a card on the Labels page.
    var openLabel: DocumentLabel?
    /// Text in the sidebar's search field; while it is not empty the main area shows results.
    var searchText = ""
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
            let runtime = try await ArrumatorRuntime.bootstrap(appVersion: Self.version, echoLogsToStderr: false)
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

    /// Starts watching off the main actor. macOS blocks the first access to the Documents folder until the user
    /// answers its permission prompt, and the windows and the menu bar item must appear regardless.
    private func startWatching(_ runtime: ArrumatorRuntime) {
        guard watcherStart == nil else { return }
        watcherStart = Task.detached { [weak self] in
            do {
                try await runtime.openArchive()
            } catch {
                Log.error(.app, "Could not bring the index in line with the archive", ["error": error.localizedDescription])
                await MainActor.run { self?.lastError = "Reading the archive: \(error.localizedDescription)" }
            }
            await runtime.start()
            await MainActor.run { self?.watching = true }
        }
    }

    /// Files into the archive at `path` from now on. Its history comes with it: the
    /// runtime open on this archive stops and one open on the other takes its place.
    func switchArchive(to path: String) async {
        guard let runtime, !switchingArchive,
              URL(fileURLWithPath: path.expandingTilde).standardizedFileURL.path != runtime.archive.path else { return }
        switchingArchive = true
        defer { switchingArchive = false }
        // An archive still being opened is opened fully first, so its runtime never starts after it was stopped.
        await watcherStart?.value
        do {
            let next = try await runtime.switchArchive(to: path)
            watcherStart = nil
            watching = false
            self.runtime = next
            settings = await next.settings.current
            ingest = .idle
            openDocument = nil
            observe(next)
            activity &+= 1
            lastError = nil
            await refresh()
            if settings?.onboardingCompleted == true { startWatching(next) }
        } catch {
            lastError = "Switch archives: \(error.localizedDescription)"
            Log.error(.ui, "Could not switch archives", ["error": error.localizedDescription])
        }
    }

    private func observe(_ runtime: ArrumatorRuntime) {
        streams.forEach { $0.cancel() }
        streams = [
            Task { [weak self] in
                for await status in await runtime.coordinator.statusUpdates() { self?.ingest = status }
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
                limit: 12, kinds: [.filed, .needsReview, .duplicate, .failed, .userMoved])
            await notifications.announce(events, previous: recent, settings: settings)
            recent = events
            reviewCount = try await runtime.services.documents.reviewQueue().count
            labelSuggestionCount = try await runtime.services.labels.suggestions().count
        } catch {
            Log.error(.ui, "Refresh failed", ["error": error.localizedDescription])
        }
    }

    func update(_ mutate: @escaping @Sendable (inout AppSettings) -> Void) async {
        guard let runtime else { return }
        do { settings = try await runtime.settings.update(mutate) } catch {
            Log.error(.ui, "Could not save settings", ["error": error.localizedDescription])
        }
    }

    func togglePause() async {
        let paused = !(settings?.paused ?? false)
        await update { $0.paused = paused }
        await runtime?.coordinator.wake()
        if let runtime {
            _ = try? await runtime.services.history.record(paused ? .paused : .resumed, actor: .user,
                                                           summary: paused ? "Processing paused" : "Processing resumed")
        }
    }

    // MARK: Actions with user-visible errors

    var lastError: String?

    func perform(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime) async throws -> Void) async {
        guard let runtime else { return }
        do {
            try await action(runtime)
            lastError = nil
        } catch {
            lastError = "\(what): \(error.localizedDescription)"
            Log.error(.ui, what, ["error": error.localizedDescription])
        }
        await refresh()
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
            lastError = "\(what): \(error.localizedDescription)"
            Log.error(.ui, what, ["error": error.localizedDescription])
            return nil
        }
    }

    /// Switches the main window to a page, closing any open card and search.
    func go(_ destination: Destination) {
        self.destination = destination
        openDocument = nil
        openLabel = nil
        searchText = ""
    }

    /// Shows a label opened in place on the Labels page.
    func open(label: DocumentLabel) {
        go(.labels)
        openLabel = label
        show(.main)
    }

    /// Searches for the documents that have a label, by its kind.
    func search(_ label: DocumentLabel) {
        go(destination)
        searchText = "\(label.kind.rawValue):\"\(label.value.replacingOccurrences(of: "\"", with: " "))\""
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

    var statusSymbol: String {
        if case .failed = phase { return "exclamationmark.triangle" }
        if settings?.paused == true { return "pause.circle" }
        switch ollama {
        case .unhealthy, .notInstalled: return "exclamationmark.triangle"
        default: break
        }
        if ingest.currentPath != nil { return "tray.and.arrow.down.fill" }
        return reviewCount > 0 ? "tray.full" : "tray"
    }

    /// Why the app is not filing right now, or nil when everything is working.
    var attention: String? {
        if case let .failed(why) = phase { return why }
        if settings?.onboardingCompleted == true, !watching { return "Waiting for access to your folders" }
        if settings?.paused == true { return "Paused" }
        if let reason = ingest.powerPauseReason { return "Waiting: \(reason)" }
        if ingest.waitingForOllama || !ollama.isReady { return ollama.summary }
        return nil
    }

    var statusLine: String {
        if case let .failed(why) = phase { return why }
        if settings?.onboardingCompleted == true, !watching { return "Starting: waiting for folder access" }
        if settings?.paused == true { return "Paused" }
        if let reason = ingest.powerPauseReason { return "Waiting: \(reason)" }
        if ingest.waitingForOllama { return "Waiting for Ollama" }
        if let path = ingest.currentPath {
            return "\(ingest.currentStage?.rawValue.capitalized ?? "Working") \((path as NSString).lastPathComponent)"
        }
        return ingest.queued > 0 ? "\(ingest.queued) queued" : "Idle"
    }
}

/// What the main window shows. The sidebar lists `lists`; history and statistics are reached from the sidebar's menu.
enum Destination: Hashable {
    case incoming, review, processed, labels
    case history, statistics

    static let lists: [Destination] = [.incoming, .review, .processed, .labels]
}
