import ArrumatorClassify
import ArrumatorCore
import ArrumatorExtract
import Foundation

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
    /// Whether the index was found, created or rebuilt when the runtime opened it.
    public let opening: AppDatabase.Opening
    /// The archive's record files, which the database indexes (docs/storage.md).
    public let records: ArchiveRecords
    public let settings: SettingsStore
    /// The user's changes to the settings, each saved and recorded once in History.
    public let settingsActions: SettingsActions
    /// What the user does with model profiles: lists, adds, changes, resets and removes them, and chooses the one in use.
    public let profiles: ModelProfileActions
    public let registry: SelfChangeRegistry
    /// The Ollama server in use; `useOllama(at:)` points it elsewhere.
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
    private let tasks = BackgroundTasks()

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
        // The archive's folder names its index, so it exists before the index opens.
        try FileManager.default.createDirectory(at: current.archiveURL, withIntermediateDirectories: true)
        try paths.moveSingleIndex(to: try paths.indexURL(for: current.archiveURL))
        return try ArrumatorRuntime(appVersion: appVersion, environment: environment, logLevelOverride: logLevelOverride,
                                    time: time, paths: paths, config: config, settings: settings, archive: current.archiveURL,
                                    ollamaURL: try OllamaEndpoint.validated(environment.ollamaURL ?? current.ollamaURL), trash: trash)
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
    /// Call `openArchive()` and then `start()` on the runtime returned, as after `bootstrap`.
    public func switchArchive(to path: String) async throws -> ArrumatorRuntime {
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
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        // Spelled as the file system spells it (links resolved, letters in their case on disk), so every path under
        // the archive is written one way, and another spelling of this archive's folder is this archive.
        let target = chosen.canonicalFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL } ?? chosen
        guard try paths.indexURL(for: target) != index else { throw ArchiveSwitchError.alreadyOpen(target.path) }
        guard !isInsideIncoming(target.path) else { throw ArchiveSwitchError.insideIncoming(archive: target.path, incoming: incoming.path) }

        // The new index opens before anything stops, and whatever fails once this runtime has stopped starts it again,
        // so a failed switch leaves the app on the archive it was on, running.
        let nextSettings = try SettingsStore(paths: paths)
        let next = try ArrumatorRuntime(appVersion: appVersion, environment: environment, logLevelOverride: logLevelOverride,
                                        time: time, paths: paths, config: config, settings: nextSettings, archive: target,
                                        ollamaURL: ollama.baseURL, trash: services.trash)
        await stop()
        do {
            let waiting = try await services.jobs.cancelActive(kinds: [.ingest])
            try await services.history.record(
                .settingsChanged, actor: .user,
                summary: "Switched to the archive at \(target.path)" + (waiting > 0 ? "; \(Format.count(waiting, "file")) waiting in Incoming go there" : ""),
                payload: ["archive": target.path])
            try await records.flush()
            try await nextSettings.update { $0.archivePath = target.path }
        } catch {
            Log.error(.app, "Could not switch archives; staying on this one", ["to": target.path, "error": error.localizedDescription])
            await start()
            throw error
        }
        Log.info(.app, "Switched archives", ["from": archive.path, "to": target.path, "index": next.index.path])
        return next
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

    /// Brings the index in line with the archive before anything else uses it: a new or set-aside index is rebuilt
    /// from the record files, otherwise record files changed on disk are read again; then every stale record file is
    /// written. Reads the archive, so macOS may first ask for access to it.
    public func openArchive() async throws {
        if opening.needsRebuild, try await records.archiveHasRecords() {
            let summary = try await records.rebuild()
            Log.info(.app, "Index rebuilt from the archive", ["documents": String(summary.documents), "queued": String(summary.queued)])
        } else {
            try await records.reconcile()
        }
        try await records.flush()
    }

    private init(appVersion: String, environment: RuntimeEnvironment, logLevelOverride: LogLevel?, time: any TimeSource,
                 paths: AppPaths, config: PipelineConfig, settings: SettingsStore, archive: URL, ollamaURL: URL,
                 trash: any Trashing) throws {
        self.appVersion = appVersion
        self.environment = environment
        self.logLevelOverride = logLevelOverride
        self.time = time
        self.paths = paths
        self.config = config
        self.settings = settings
        self.archive = archive
        index = try paths.indexURL(for: archive)
        (database, opening) = try AppDatabase.open(at: index, config: config.database, setAsideSuffix: config.records.setAsideSuffix,
                                                   time: time) {
            ArchiveRecords.mayHoldRecords(archive: archive, config: config)
        }
        registry = SelfChangeRegistry(ttl: config.watcher.selfChangeTTLSeconds, time: time)
        records = ArchiveRecords(database: database, settings: settings, config: config, registry: registry, time: time)
        ollama = try OllamaConnection(config: config.ollama, url: ollamaURL, time: time)
        gate = InferenceGate(api: ollama, retryDelays: config.ollama.retryDelays, time: time)
        models = ModelManager(api: ollama, config: config.ollama)
        lifecycle = OllamaLifecycle(api: ollama, config: config.ollama, management: .external, binaryOverride: nil,
                                    address: ollamaURL, time: time)
        prompts = PromptBuilder(library: try PromptLibrary.bundled(), config: config.analysis, labels: config.labels,
                                naming: config.naming)
        analyzer = DocumentAnalyzer(gate: gate, models: models, prompts: prompts)
        let skip = SkipRules(watcher: config.watcher)
        vectors = VectorIndex()
        search = SearchService(database: database, vectors: vectors, embedder: nil, config: config.search)
        traces = TraceRecorder(database: database, appVersion: appVersion, time: time)
        let placer = Placer(builder: FilenameBuilder(config: config.naming), operations: FileOperations(naming: config.naming))
        let extractor = try ExtractorRegistry(ollama: GatedOllama(gate: gate), recognizer: VisionTextRecognizer(),
                                              shell: ShellRunner(time: time), time: time)
        services = PipelineServices(
            database: database, config: config, settings: settings, extractor: extractor, analyzer: analyzer,
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
        doctor = Doctor(database: database, paths: paths, appVersion: appVersion, time: time)
    }

    /// Records an event of the app's own in History. Nothing waits on these, so one that cannot be recorded is logged
    /// with the reason instead of stopping what it describes.
    private func audit(_ kind: EventKind, actor: EventActor, summary: String, payload: (any Encodable & Sendable)?) async {
        do { try await services.history.record(kind, actor: actor, summary: summary, payload: payload) } catch {
            Log.error(.db, "Could not record an event in the history", ["kind": kind.rawValue, "error": error.localizedDescription])
        }
    }

    // MARK: Lifecycle

    /// Starts Ollama supervision, the ingest worker, the search task queue, the conversation queue, both watchers and
    /// maintenance. Returns immediately.
    public func start() async {
        // Subscribed before the settings in force are read, so a change made while the runtime starts, or as soon as
        // `start()` returns, is applied too, at worst twice. Whoever changes a setting records it (`SettingsActions`,
        // `setPaused`), so applying records nothing.
        let changes = await settings.changes()
        let current = await settings.current
        Log.info(.app, "Arrumator starting", ["version": appVersion, "archive": current.archivePath, "incoming": current.incomingPath])
        await audit(.appStarted, actor: .system, summary: "Arrumator \(appVersion) started", payload: nil)
        await apply(current)
        await tasks.run("ollama") { [lifecycle] in
            await lifecycle.ensureRunning()
            await lifecycle.startMonitoring()
        }
        await coordinator.start()
        await taskQueue.start()
        await conversationQueue.start()
        await tasks.run("incoming-pump") { [incomingWatcher, coordinator] in
            for await url in incomingWatcher.stableFiles { await coordinator.enqueue(url) }
        }
        await tasks.run("archive-pump") { [archiveWatcher, reconciler, records] in
            for await changes in archiveWatcher.changes {
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
    }

    /// Stops everything `start()` started and waits until it has: the queues first, so the document in hand, the request
    /// being read and the question being answered stop where they carry on at the next start, then the watchers; the record files are written
    /// after, so what the queues kept while stopping is in them too, and Ollama, when the app started it, is stopped last.
    public func stop() async {
        await tasks.cancelAll()
        await coordinator.stop()
        await taskQueue.stop()
        await conversationQueue.stop()
        await incomingWatcher.stop()
        await archiveWatcher.stop()
        do { try await records.flush() } catch {
            Log.error(.db, "Could not write record files before stopping", ["error": error.localizedDescription])
        }
        await lifecycle.shutdown()
        Log.info(.app, "Arrumator stopped")
    }

    /// Stops as `stop()` does, before the app quits, waiting for it at most `ingest.quitTimeout` seconds: a stop that
    /// takes longer, such as a page being read that cannot be interrupted, goes on while the app quits, and the job it
    /// was on carries on where it stopped at the next start. Whether everything stopped in time.
    @discardableResult
    public func stopBeforeQuitting() async -> Bool {
        let timeout = config.ingest.quitTimeout
        let stopped = await time.wait(atMost: timeout) { [self] in await stop() }
        if !stopped { Log.warning(.app, "Quitting before everything stopped", ["waited": String(timeout)]) }
        return stopped
    }

    /// Applies (changed) settings: Ollama management, watched folders, embedding model for search.
    public func apply(_ current: AppSettings) async {
        await lifecycle.configure(management: Self.management(for: current, at: ollama.baseURL), binaryOverride: current.ollamaBinaryPath,
                                  address: ollama.baseURL)
        Log.shared.setMinLevel(logLevelOverride ?? current.logLevel)
        do {
            try await prepareSearch(current)
            try FileManager.default.createDirectory(at: current.archiveURL, withIntermediateDirectories: true)
            try await incomingWatcher.start(root: current.incomingURL)
            try await archiveWatcher.start(root: current.archiveURL, excluding: [current.incomingURL])
        } catch {
            Log.error(.app, "Could not apply settings", ["error": error.localizedDescription])
        }
        await coordinator.wake()
    }

    /// Loads the vector index and the query embedder for the embedding model of the profile in use (no watchers started).
    public func prepareSearch(_ current: AppSettings) async throws {
        let model = try current.modelProfile().embedModel
        await search.setEmbedder(OllamaEmbedder(gate: gate, model: model, keepAlive: config.ollama.keepAlive.embed,
                                                numCtx: config.analysis.embeddingNumCtx))
        if await vectors.model != model {
            await vectors.load(model: model, rows: try await services.index.embeddings(model: model))
        }
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
        await doctor.run(settings: await settings.current, config: config, lifecycle: lifecycle, models: models, ollamaURL: ollama.baseURL)
    }
}

/// Owns long-running tasks so they can be cancelled together.
actor BackgroundTasks {
    private var tasks: [String: Task<Void, Never>] = [:]

    func run(_ name: String, _ body: @escaping @Sendable () async -> Void) {
        tasks[name]?.cancel()
        tasks[name] = Task(priority: .utility) { await body() }
    }

    func cancelAll() {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
    }
}
