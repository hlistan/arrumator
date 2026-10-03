import ArrumatorClassify
import ArrumatorCore
import ArrumatorExtract
import Foundation
import Synchronization

/// Composition root shared by the app and the CLI: builds every service from configuration and runs the
/// background machinery (watchers, ingest worker, Ollama supervision, maintenance). A runtime is open on one archive,
/// with that archive's index; switching archives replaces it (`switchArchive`).
public final class ArrumatorRuntime: Sendable {
    public let environment: RuntimeEnvironment
    /// The log level `ARRUMATOR_LOG_LEVEL` sets over the settings', read once when the runtime starts.
    public let logLevelOverride: LogLevel?
    /// The clock every service stamps and waits by.
    public let time: any TimeSource
    public let paths: AppPaths
    public let config: PipelineConfig
    public let appVersion: String
    /// The archive this runtime files into, whose index it holds.
    public let archive: URL
    /// Where the archive's index is kept (`AppPaths.indexURL`).
    public let index: URL
    public let database: AppDatabase
    /// The archive's record files, which the database indexes (docs/storage.md).
    public let records: ArchiveRecords
    public let settings: SettingsStore
    /// The user's changes to the settings, each saved and recorded once in History.
    public let settingsActions: SettingsActions
    /// What the user does with model profiles: lists, adds, changes, resets and removes them, and chooses the one in use.
    public let profiles: ModelProfileActions
    public let registry: SelfChangeRegistry
    /// The Ollama server in use; `useOllama(at:)` points it elsewhere. A switch of archives hands it to the next runtime,
    /// so a server chosen while the switch stops this one is the next one's too.
    public let ollama: OllamaConnection
    public let gate: InferenceGate
    public let lifecycle: OllamaLifecycle
    public let models: ModelManager
    public let prompts: PromptBuilder
    public let analyzer: DocumentAnalyzer
    public let vectors: VectorIndex
    public let search: SearchService
    public let traces: TraceRecorder
    public let services: PipelineServices
    public let coordinator: IngestCoordinator
    public let review: ReviewActions
    /// What the user decides about labels for the whole archive.
    public let labels: LabelActions
    /// Reads what the user asks for, in their own words, as a search.
    public let interpreter: SearchPromptInterpreter
    /// Runs search tasks one at a time, as they are asked for.
    public let taskQueue: SearchTaskQueue
    /// What the user does with search tasks: asks, changes, edits their sets, exports them, removes them.
    public let searchTasks: SearchTaskActions
    /// Answers what is asked about a task's documents, from what it is shown of them.
    public let answerer: TaskAnswerer
    /// Answers questions about tasks' documents one at a time, as they are asked.
    public let conversationQueue: TaskConversationQueue
    /// What the user does with the conversations about tasks' documents: asks, asks again, stops, clears them.
    public let conversations: TaskConversationActions
    public let reconciler: ArchiveReconciler
    public let incomingWatcher: IncomingWatcher
    public let archiveWatcher: ArchiveWatcher
    public let stats: StatsService
    public let doctor: Doctor
    let tasks = BackgroundTasks()

    /// - Parameter trash: where an exact copy of a document in the archive goes once its original is read again in its
    ///   place: the Mac's Trash for the app and the command line, a folder of its own for a run that must leave nothing
    ///   behind, as `eval`.
    public static func bootstrap(appVersion: String, environment: RuntimeEnvironment, echoLogsToStderr: Bool,
                                 trash: any Trashing) async throws -> ArrumatorRuntime {
        let time = SystemTime()
        let paths = AppPaths.resolve(environment)
        try paths.ensureDirectories()
        let logLevelOverride = try environment.logLevel()
        let config = try PipelineConfig.load(paths: paths, environment: environment)
        let settings = try SettingsStore(paths: paths)
        let current = await settings.current
        Log.shared.configure(directory: paths.logsDirectory, minLevel: logLevelOverride ?? current.logLevel,
                             config: config.logging, echoToStderr: echoLogsToStderr)
        Log.shared.prune(config.logging, now: time.now())
        // One of the two places that read the archive from the settings, with a switch (`switchArchive`): the runtime
        // acts on this one from now on, whatever the settings name later.
        let archive = current.archiveURL
        try paths.moveSingleIndex(to: paths.indexURL(for: archive))
        let address = try configuredOllama(environment: environment, settings: current, paths: paths)
        let ollama = try OllamaConnection(config: config.ollama, url: address, time: time)
        return try ArrumatorRuntime(appVersion: appVersion, environment: environment, logLevelOverride: logLevelOverride,
                                    time: time, paths: paths, config: config, settings: settings, archive: archive, ollama: ollama, trash: trash)
    }

    /// The Ollama server to talk to: the one the environment names in place of the saved setting, else the setting. One
    /// this version refuses, such as an address an earlier version saved with a password in it, stops the start saying
    /// where it came from and how to give another (AGENTS.md §4.2); `arrumatorcli settings --ollama-url` gives the
    /// runtime the new one in its place, so it can always mend it.
    private static func configuredOllama(environment: RuntimeEnvironment, settings: AppSettings, paths: AppPaths) throws -> URL {
        if let given = environment.ollamaURL { return try OllamaEndpoint.validated(given, from: .environment) }
        return try OllamaEndpoint.validated(settings.ollamaURL, from: .settings(paths.settingsURL))
    }

    /// Points the app at the Ollama server at `address` — this Mac or a machine on the local network — from now on,
    /// and remembers it, recorded in History once. An address elsewhere is refused and nothing changes. Whether the
    /// server answers is the caller's to check (`lifecycle.ensureRunning()`).
    public func useOllama(at address: String) async throws {
        let url = try OllamaEndpoint.validated(address)
        try ollama.connect(to: url)
        let updated = try await settingsActions.change(summary: "Ollama at \(url.absoluteString)") { $0.ollamaURL = url.absoluteString }
        await lifecycle.configure(management: Self.management(for: updated, at: url), binaryOverride: updated.ollamaBinaryPath,
                                  address: url)
        Log.info(.ollama, "Using Ollama", ["url": url.absoluteString])
    }

    /// A server on another machine is the user's to run: the app starts and stops only one on this Mac.
    public static func management(for settings: AppSettings, at url: URL) -> OllamaManagement {
        OllamaEndpoint.isThisMac(url) ? settings.ollamaManagement : .external
    }

    /// Stops this runtime and returns one open on the archive at `path`, with that archive's own index; the settings
    /// name it from then on. Files waiting in Incoming are filed into the new archive.
    /// Call `openArchive()` and then `start()`, or `openAndStart()`, on the runtime returned, as after `bootstrap`.
    ///
    /// Both runtimes keep the settings in one store and talk to Ollama through one connection, so a change made while
    /// this one stops, such as a pause or another server, is the next one's too, and never names this archive again.
    /// Each acts on its own archive, which it was made with, and never on the one the settings name: this one, stopped
    /// again after the switch, as when the app quits then, writes only into its own archive. A switch is made whole or
    /// not at all: the next archive's index opens and the settings are shown to be savable before anything stops; then
    /// this runtime stops and its history records the switch, and only then do the settings name the next archive and
    /// the files waiting in Incoming leave this runtime's queue. A step that fails starts this runtime again as it was,
    /// its queue untouched, and a failure to save the settings after the switch was recorded is recorded too. The record
    /// files of this archive are written before the settings change; when they cannot be, as on a disk that is gone, the
    /// switch is made all the same, so the user can always switch away, and what they lack, kept in its index, is
    /// written when it is next opened (`ArchiveSwitch.unwritten`).
    public func switchArchive(to path: String) async throws -> ArchiveSwitch {
        let chosen = URL(fileURLWithPath: path.expandingTilde, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: chosen.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw ArchiveSwitchError.notAFolder(chosen.path)
        }
        let incoming = await settings.current.incomingURL
        func isInsideIncoming(_ folder: String) -> Bool {
            (folder + "/").hasPrefix((incoming.canonicalFolderPath ?? incoming.path) + "/") || (folder + "/").hasPrefix(incoming.path + "/")
        }
        guard !isInsideIncoming(chosen.path) else { throw ArchiveSwitchError.insideIncoming(archive: chosen.path, incoming: incoming.path) }
        // Spelled as the file system spells it (links resolved, letters in their case on disk), so every path under
        // the archive is written one way, and another spelling of this archive's folder is this archive.
        let target = chosen.canonicalPlace
        guard paths.indexURL(for: target) != index else { throw ArchiveSwitchError.alreadyOpen(target.path) }
        guard !isInsideIncoming(target.path) else { throw ArchiveSwitchError.insideIncoming(archive: target.path, incoming: incoming.path) }

        let next = try ArrumatorRuntime(appVersion: appVersion, environment: environment, logLevelOverride: logLevelOverride,
                                        time: time, paths: paths, config: config, settings: settings, archive: target,
                                        ollama: ollama, trash: services.trash)
        if !next.records.archiveIsThere {
            // A folder the user switches to that is not there is made, for a new archive: never in place of an archive
            // its index has held, which is away and is not switched to.
            guard try await !next.database.heldAnArchive() else { throw RecordsError.archiveNotThere(target.path) }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        // The settings in force, saved as they are: the file the switch saves can be written, or nothing stops.
        try await settings.save(await settings.current)
        let halted = await halt(forGood: false)
        do {
            // The files waiting in Incoming leave the queue only once the switch is made, below, so one that fails keeps it.
            let waiting = try await services.jobs.active(kinds: [.ingest]).count
            // An index not rebuilt from its archive holds the event until it is (`HistoryStore.insert`), so leaving that
            // archive stays possible, and is recorded in it.
            try await services.history.record(
                .settingsChanged, actor: .user,
                summary: "Switched to the archive at \(target.path)" + (waiting > 0 ? "; \(Format.count(waiting, "file")) waiting in Incoming go there" : ""),
                payload: ["archive": target.path])
        } catch {
            Log.error(.app, "Could not switch archives; staying on this one", ["to": target.path, "error": error.localizedDescription])
            await resume(halted)
            throw error
        }
        var unwritten: UnwrittenRecords?
        do { try await records.flush() } catch {
            unwritten = UnwrittenRecords(archive: archive.path, reason: error.localizedDescription)
            Log.error(.app, "Switching archives; the record files of the archive left wait to be written",
                      ["archive": archive.path, "error": error.localizedDescription])
        }
        do {
            try await settings.update { $0.archivePath = target.path }
        } catch {
            Log.error(.app, "Could not switch archives; staying on this one", ["to": target.path, "error": error.localizedDescription])
            await audit(.settingsChanged, actor: .system, summary: "Stayed on the archive at \(archive.path): \(error.localizedDescription)",
                        payload: ["archive": archive.path])
            do { try await records.flush() } catch {
                Log.error(.db, "Could not write record files", ["error": error.localizedDescription])
            }
            await resume(halted)
            throw error
        }
        await tasks.closeForGood()
        // The switch is made: the files waiting in Incoming leave this archive's queue, for the next archive's. Should
        // they stay, this archive files them, or finds them gone, when it is next opened, as after any stop.
        do { _ = try await services.jobs.cancelActive(kinds: [.ingest]) } catch {
            Log.error(.app, "Switched archives; the files waiting in Incoming stay queued in the archive left",
                      ["archive": archive.path, "error": error.localizedDescription])
        }
        Log.info(.app, "Switched archives", ["from": archive.path, "to": target.path, "index": next.index.path])
        return ArchiveSwitch(runtime: next, unwritten: unwritten)
    }

    /// Pauses or resumes filing, from the app or the command line alike: the setting, the worker woken to notice, and
    /// the decision in History.
    public func setPaused(_ paused: Bool) async throws {
        try await settings.update { $0.paused = paused }
        await coordinator.wake()
        try await services.history.record(paused ? .paused : .resumed, actor: .user,
                                          summary: paused ? "Processing paused" : "Processing resumed")
    }

    /// Writes a zip with logs, recent traces, the doctor's report and the settings; document text only when
    /// `includeDocumentText`, as the user chose.
    public func exportDiagnostics(to zip: URL, includeDocumentText: Bool) async throws -> DiagnosticsContents {
        try await DiagnosticsExporter(database: database, paths: paths, config: config.stats)
            .export(to: zip, doctor: await runDoctor(), settings: await settings.current, includeDocumentText: includeDocumentText)
    }

    /// Brings the index in line with the archive before anything else uses it: an index created or set aside and not
    /// rebuilt since, as it records itself, is rebuilt from the record files, otherwise record files changed on disk are
    /// read again; then every stale record file is written, and search is readied as the app's is (`prepareSearch`).
    /// Reads the archive, so macOS may first ask for access to it.
    public func openArchive() async throws {
        if let summary = try await records.rebuildIfPending() {
            Log.info(.app, "Index rebuilt from the archive", ["documents": String(summary.documents), "queued": String(summary.queued)])
        } else {
            try await records.reconcile()
        }
        try await records.flush()
        await prepareSearch(await settings.current, loadingVectors: false)
    }

    private init(appVersion: String, environment: RuntimeEnvironment, logLevelOverride: LogLevel?, time: any TimeSource,
                 paths: AppPaths, config: PipelineConfig, settings: SettingsStore, archive: URL, ollama: OllamaConnection,
                 trash: any Trashing) throws {
        self.appVersion = appVersion
        self.environment = environment
        self.logLevelOverride = logLevelOverride
        self.time = time
        self.paths = paths
        self.config = config
        self.settings = settings
        self.archive = archive
        index = paths.indexURL(for: archive)
        (database, _) = try AppDatabase.open(at: index, config: config.database, setAsideSuffix: config.records.setAsideSuffix,
                                             time: time) {
            ArchiveRecords.mayHoldRecords(archive: archive, config: config)
        }
        registry = SelfChangeRegistry(ttl: config.watcher.selfChangeTTLSeconds, time: time)
        records = ArchiveRecords(database: database, archive: archive, settings: settings, config: config, registry: registry, time: time)
        self.ollama = ollama
        gate = InferenceGate(api: ollama, retryDelays: config.ollama.retryDelays, time: time)
        models = ModelManager(api: ollama, config: config.ollama)
        lifecycle = OllamaLifecycle(api: ollama, config: config.ollama, management: .external, binaryOverride: nil,
                                    address: ollama.baseURL, time: time)
        prompts = PromptBuilder(library: try PromptLibrary.bundled(), config: config.analysis, labels: config.labels,
                                naming: config.naming)
        analyzer = DocumentAnalyzer(gate: gate, models: models, prompts: prompts)
        let skip = SkipRules(watcher: config.watcher)
        vectors = VectorIndex()
        search = SearchService(database: database, vectors: vectors, embedder: nil, config: config.search, time: time)
        traces = TraceRecorder(database: database, appVersion: appVersion, time: time)
        let placer = Placer(builder: FilenameBuilder(config: config.naming, reserved: skip),
                            operations: FileOperations(trash: trash, sameVolume: FileOperations.onOneVolume))
        let extractor = try ExtractorRegistry(ollama: GatedOllama(gate: gate), recognizer: VisionTextRecognizer(),
                                              shell: ShellRunner(time: time), time: time)
        services = PipelineServices(
            database: database, archive: archive, config: config, settings: settings, extractor: extractor, analyzer: analyzer,
            filer: DocumentFiler(database: database, placer: placer, index: IndexStore(database: database, time: time),
                                 registry: registry, time: time),
            traces: traces, vectors: vectors, trash: trash, time: time)
        coordinator = IngestCoordinator(services: services)
        settingsActions = SettingsActions(store: settings, history: services.history)
        profiles = ModelProfileActions(settings: settingsActions, bundled: try AppSettings.bundledDefaults().modelProfiles, database: database)
        review = ReviewActions(services: services, coordinator: coordinator)
        labels = LabelActions(database: database, time: time)
        interpreter = SearchPromptInterpreter(gate: gate, models: models, library: prompts.library)
        taskQueue = SearchTaskQueue(services: services, interpreter: interpreter)
        searchTasks = SearchTaskActions(services: services, queue: taskQueue)
        answerer = TaskAnswerer(gate: gate, models: models, library: prompts.library)
        conversationQueue = TaskConversationQueue(services: services, answerer: answerer, interpreter: interpreter, search: search)
        conversations = TaskConversationActions(services: services, queue: conversationQueue)
        reconciler = ArchiveReconciler(services: services, coordinator: coordinator)
        incomingWatcher = IncomingWatcher(config: config.watcher, skip: skip, time: time)
        archiveWatcher = ArchiveWatcher(config: config.watcher, records: config.records, skip: skip, registry: registry,
                                        database: database)
        stats = StatsService(database: database, config: config.stats, time: time)
        doctor = Doctor(database: database, archive: archive, paths: paths, appVersion: appVersion, time: time)
    }

    /// Records an event of the app's own in History. Nothing waits on these, so one that cannot be recorded is logged
    /// with the reason instead of stopping what it describes.
    private func audit(_ kind: EventKind, actor: EventActor, summary: String, payload: (any Encodable & Sendable)?) async {
        do { try await services.history.record(kind, actor: actor, summary: summary, payload: payload) } catch {
            Log.error(.db, "Could not record an event in the history", ["event": kind.rawValue, "error": error.localizedDescription])
        }
    }

    // MARK: Lifecycle

    /// Brings the index in line with the archive (`openArchive()`), then starts the background work (`start()`), as one
    /// step of the runtime's own that `stop()` ends: stopped while the archive is read, which macOS may hold behind its
    /// prompt for access to the folder, the runtime starts nothing, then or later. The work starts also when the archive
    /// could not be read, as Incoming is filed all the same, and why it could not be read is then thrown. Throws
    /// `CancellationError` when the runtime was stopped first. What the app does once the user has set it up.
    public func openAndStart() async throws {
        try await openAndStart(opening: { [self] in try await openArchive() })
    }

    /// `openAndStart()`, reading the archive with `opening`: what a test holds to stop the runtime while it reads.
    func openAndStart(opening: @escaping @Sendable () async throws -> Void) async throws {
        guard let step = await tasks.starting(reading: true, { [self] in
            var unread: (any Error)?
            do { try await opening() } catch { unread = error }
            // Stopped meanwhile: a read that does not notice being stopped, such as one macOS holds, still ends here.
            try Task.checkCancellation()
            await tasks.opened()
            if let unread {
                Log.error(.app, "Could not bring the index in line with the archive", ["error": unread.localizedDescription])
            }
            // Why the archive could not be read says more than that its index was not rebuilt from it.
            do { try await beginOnRebuiltIndex() } catch { throw unread ?? error }
            if let unread { throw unread }
        }) else { throw CancellationError() }
        try await step.value
    }

    /// Starts Ollama supervision, the ingest worker, the search task queue, the conversation queue, both watchers,
    /// maintenance and working out which labels look alike; returns once they have started, saying whether they have. A
    /// runtime starts once: a second start does nothing more, and one after `stop()` nothing at all. An index not rebuilt
    /// from its archive, as when its rebuild was refused for a record file that cannot be read (`openArchive`), starts
    /// nothing, until it is rebuilt (`rebuildIndex()`): what the workers did would be filed over the user's records.
    @discardableResult
    public func start() async -> Bool {
        guard let step = await tasks.starting(reading: false, { [self] in try await beginOnRebuiltIndex() }) else { return false }
        // Why the archive could not be read, when `openAndStart()` began the step, is its caller's to show.
        _ = await step.result
        return await tasks.isStarted
    }

    /// Starts the work (`begin()`) on an index rebuilt from its archive, whose folder is there. Otherwise it starts
    /// nothing, and lets the step that started go, so that the start after its rebuild begins one of its own; it is
    /// decided within that step, so a stop meanwhile is waited for like any start.
    private func beginOnRebuiltIndex() async throws {
        guard records.archiveIsThere else {
            Log.error(.app, "Not started: the archive's folder is not there", ["archive": archive.path])
            await tasks.refused(as: .away)
            throw RecordsError.archiveNotThere(archive.path)
        }
        let pending: AppDatabase.PendingRebuild?
        do { pending = try await database.pendingRebuild() } catch {
            Log.error(.app, "Not started: whether the index was rebuilt from the archive cannot be read", ["error": error.localizedDescription])
            await tasks.refused(as: .refused)
            throw error
        }
        if let pending {
            Log.error(.app, "Not started: the index has not been rebuilt from the archive", ["state": pending.rawValue])
            await tasks.refused(as: .refused)
            throw await database.notRebuilt()
        }
        await begin()
        await tasks.began()
    }

    /// Whether the work runs now, then each time that changes: started, refused as the index is not rebuilt from its
    /// archive, or stopped. What the app shows, rather than what it asked for.
    public func workUpdates() async -> AsyncStream<RuntimeWork> {
        await tasks.workUpdates()
    }

    private func begin() async {
        // Subscribed before the settings in force are read, so a change made while the runtime starts, or as soon as
        // `start()` returns, is applied too, at worst twice. Whoever changes a setting records it (`SettingsActions`,
        // `setPaused`), so applying records nothing.
        let changes = await settings.changes()
        // Subscribed before the watchers start, so nothing they find at once is missed.
        let arrivals = await incomingWatcher.arrivals()
        let archiveChanges = await archiveWatcher.changes()
        let current = await settings.current
        Log.info(.app, "Arrumator starting", ["version": appVersion, "archive": archive.path, "incoming": current.incomingPath])
        await audit(.appStarted, actor: .system, summary: "Arrumator \(appVersion) started", payload: nil)
        await apply(current)
        await tasks.run("ollama") { [lifecycle] in
            await lifecycle.ensureRunning()
            // Stopped while the server was looked for: nothing is left to supervise it for.
            guard !Task.isCancelled else { return }
            await lifecycle.startMonitoring()
        }
        await coordinator.start()
        await taskQueue.start()
        await conversationQueue.start()
        await tasks.run("incoming-pump") { [coordinator] in
            for await arrival in arrivals { await coordinator.receive(arrival) }
        }
        await tasks.run("archive-pump") { [reconciler, records] in
            for await changes in archiveChanges {
                if changes.contains(.recordsChanged) {
                    do { try await records.reconcile() } catch {
                        Log.error(.db, "Could not read changed record files", ["error": error.localizedDescription])
                    }
                }
                await reconciler.apply(changes)
            }
        }
        await tasks.run("records") { [database, records] in
            // Every change marks the record files it touched; write them as soon as the change commits.
            for await pending in database.pendingRecords() where pending > 0 {
                do { try await records.flush() } catch {
                    Log.error(.db, "Could not write record files", ["error": error.localizedDescription])
                }
            }
        }
        await tasks.run("settings") { [weak self] in
            for await changed in changes { await self?.apply(changed) }
        }
        await tasks.run("ollama-audit") { [lifecycle, weak self] in
            var previous: OllamaState?
            for await state in await lifecycle.states() where state != .unknown && state != .starting {
                if let previous, previous.isReady == state.isReady { continue }
                previous = state
                await self?.audit(.ollamaState, actor: .system, summary: state.summary, payload: nil)
            }
        }
        await tasks.run("maintenance") { [time, config, weak self] in
            while !Task.isCancelled {
                await self?.maintain()
                do { try await time.sleep(seconds: config.maintenance.interval) } catch { return }
            }
        }
        await tasks.run("look-alikes") { [services] in await services.labels.workOutLookAlikes() }
    }

    /// Stops everything `start()` started, for good, and waits until it has. Everything is told to stop before anything
    /// is waited for, as one worker may wait for another, as for the generation lane; what was starting ends first, so
    /// nothing it goes on to start is left running. The queues stop so that the document in hand, the request being read
    /// and the question being answered carry on at the next start; the background tasks and then the watchers end; the
    /// record files are written after, so what the queues kept while stopping is in them too, and Ollama, when the app
    /// started it, is stopped last.
    public func stop() async {
        await halt(forGood: true)
    }

    /// What was under way when the runtime halted, so a switch that fails starts it again as it was.
    struct Halted {
        let started: Bool
        /// The step was reading the archive, and had not finished.
        let unread: Bool
    }

    /// Stops as `stop()` says; for good, or until a switch that fails starts the runtime again (`resume(_:)`).
    @discardableResult
    private func halt(forGood: Bool) async -> Halted {
        let (starting, halted) = await tasks.close(forGood: forGood)
        _ = await starting?.result
        await Self.stopTogether(coordinator, taskQueue, conversationQueue)
        await tasks.ended()
        await incomingWatcher.stop()
        await archiveWatcher.stop()
        do { try await records.flush() } catch {
            Log.error(.db, "Could not write record files before stopping", ["error": error.localizedDescription])
        }
        await lifecycle.shutdown()
        Log.info(.app, "Arrumator stopped")
        return halted
    }

    /// Starts again, after a switch that failed, what was under way when it halted the runtime: the work, and the reading
    /// of the archive first when it had not ended. A runtime that had not started is left free to start, as the app
    /// starts it once onboarding is done; nothing starts, then or later, when it has meanwhile stopped for good, as when
    /// the app quits.
    private func resume(_ halted: Halted) async {
        guard await tasks.reopen(), halted.started else { return }
        guard halted.unread else {
            await start()
            return
        }
        do { try await openAndStart() } catch {
            // Why the archive could not be read is logged where it was read; the failed switch is what the user is shown.
        }
    }

    /// Stops the three queues together: each is told to stop before any is waited for, so a worker that waits for what
    /// another holds, as for the generation lane, is never waited for while the other still runs.
    static func stopTogether(_ coordinator: IngestCoordinator, _ taskQueue: SearchTaskQueue,
                             _ conversationQueue: TaskConversationQueue) async {
        async let ingest: Void = coordinator.stop()
        async let reading: Void = taskQueue.stop()
        async let answering: Void = conversationQueue.stop()
        _ = await (ingest, reading, answering)
    }

    /// Rebuilds the index from the archive's record files, as the user asks in Settings › Advanced, and starts the work
    /// on it when a start was refused, as when an earlier rebuild was refused for a record file the user has since
    /// corrected. A runtime not started yet, as before onboarding, or stopped, starts nothing.
    @discardableResult
    public func rebuildIndex() async throws -> RebuildSummary {
        let summary = try await records.rebuild()
        if await tasks.startWasRefused { await start() }
        return summary
    }

    /// Stops as `stop()` does, before the app quits, waiting for it at most `ingest.quitTimeout` seconds: a stop that
    /// takes longer, such as a page being read that cannot be interrupted, goes on while the app quits, and the job it
    /// was on carries on where it stopped at the next start. The Ollama server the app started is stopped either way,
    /// so it never outlives the app. Whether everything stopped in time.
    @discardableResult
    public func stopBeforeQuitting() async -> Bool {
        let timeout = config.ingest.quitTimeout
        let stopped = await time.wait(atMost: timeout) { [self] in await stop() }
        if !stopped {
            Log.warning(.app, "Quitting before everything stopped", ["waited": String(timeout)])
            await lifecycle.shutdown()
        }
        return stopped
    }

    /// Applies (changed) settings: Ollama management, watched folders, embedding model for search. The archive watched is
    /// the runtime's own, whatever the settings name; its folder is never made here, as one that is not there is away.
    public func apply(_ current: AppSettings) async {
        await lifecycle.configure(management: Self.management(for: current, at: ollama.baseURL), binaryOverride: current.ollamaBinaryPath,
                                  address: ollama.baseURL)
        Log.shared.setMinLevel(logLevelOverride ?? current.logLevel)
        do {
            await prepareSearch(current, loadingVectors: true)
            try await incomingWatcher.start(root: current.incomingURL, excluding: [archive])
            try await archiveWatcher.start(root: archive, excluding: [current.incomingURL])
        } catch {
            // Stopped while it applied them: what was not applied is applied at the next start.
            guard !Task.isCancelled else { return }
            Log.error(.app, "Could not apply settings", ["error": error.localizedDescription])
        }
        await coordinator.wake()
    }

    private func maintain() async {
        let current = await settings.current
        Log.shared.prune(config.logging, now: time.now())
        do {
            let trimmed = try await traces.trimRawPayloads(olderThanDays: current.traceRawRetentionDays)
            if trimmed > 0 { Log.info(.app, "Trimmed raw model payloads", ["steps": String(trimmed)]) }
        } catch {
            Log.error(.app, "Maintenance failed", ["error": error.localizedDescription])
        }
        do { try await records.flush() } catch {
            Log.error(.db, "Could not write record files", ["error": error.localizedDescription])
        }
        // Jobs another process queued, such as `arrumatorcli review retry`, wake no worker here; this does.
        await coordinator.wake()
    }

    /// Where this archive is kept and where its index is.
    public func summary() -> ArchiveSummary {
        ArchiveSummary(archive: archive.path, index: index.path)
    }

    public func runDoctor() async -> DoctorReport {
        await doctor.run(settings: await settings.current, config: config, lifecycle: lifecycle, models: models, ollamaURL: ollama.baseURL,
                         unreadableRecords: await records.unreadableFiles())
    }
}

extension ArrumatorRuntime {
    /// Ends the app's onboarding, the archive's first setup: makes the archive's folder when it is not there, then records
    /// that onboarding is done. With a switch to a folder that is not there, the only time the app makes an archive's
    /// folder, as both are what the user asks: at any other launch, one that is not there is away
    /// (`RecordsError.archiveNotThere`), whatever its index holds, as a new index looks the same whether the archive is
    /// new or away. A folder that cannot be made, as on a disk not connected under a mount point the user cannot write
    /// in, is left away, which opening it then says.
    public func finishOnboarding() async throws {
        if await !settings.current.onboardingCompleted, !records.archiveIsThere {
            do {
                try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            } catch {
                Log.warning(.app, "The archive's folder could not be made; it is away", ["archive": archive.path, "error": error.localizedDescription])
            }
        }
        try await settingsActions.change { $0.onboardingCompleted = true }
    }
}

extension ArrumatorRuntime {
    /// Sets the query embedder of the profile in use and, when `loadingVectors`, loads its vectors now, as the app does
    /// before it files anything; otherwise a search loads them when it needs them (`SearchService.loadVectors`). What
    /// fails is logged, and search goes on by words; what a stop cuts short is done at the next start, or when needed.
    private func prepareSearch(_ current: AppSettings, loadingVectors: Bool) async {
        do {
            let model = try current.modelProfile().embedModel
            await search.setEmbedder(OllamaEmbedder(gate: gate, model: model, keepAlive: config.ollama.keepAlive.embed,
                                                    numCtx: config.analysis.embeddingNumCtx))
            if loadingVectors { try await search.loadVectors() }
        } catch {
            guard !(error is CancellationError || Task.isCancelled) else { return }
            Log.error(.search, "Search by meaning not readied; searching by words", ["error": error.localizedDescription])
        }
    }
}
