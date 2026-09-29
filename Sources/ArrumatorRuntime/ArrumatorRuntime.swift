import ArrumatorClassify
import ArrumatorCore
import ArrumatorExtract
import Foundation

/// Composition root shared by the app and the CLI: builds every service from configuration and runs the
/// background machinery (watchers, ingest worker, Ollama supervision, maintenance). A runtime is open on one archive,
/// with that archive's index; switching archives replaces it (`switchArchive`).
public final class ArrumatorRuntime: Sendable {
    public let environment: RuntimeEnvironment
    public let paths: AppPaths
    public let config: PipelineConfig
    public let appVersion: String
    /// The archive this runtime files into, whose index, logic and learned state it holds.
    public let archive: URL
    /// Where the archive's index is kept (`AppPaths.indexURL`).
    public let index: URL
    public let database: AppDatabase
    /// Whether the index was found, created or rebuilt when the runtime opened it.
    public let opening: AppDatabase.Opening
    /// The archive's record files, which the database indexes (docs/storage.md).
    public let records: ArchiveRecords
    public let settings: SettingsStore
    public let registry: SelfChangeRegistry
    public let taxonomy: TaxonomyStore
    /// The Ollama server in use; `useOllama(at:)` points it elsewhere.
    public let ollama: OllamaConnection
    public let gate: InferenceGate
    public let lifecycle: OllamaLifecycle
    public let models: ModelManager
    public let learningStore: GRDBLearningStore
    public let memories: MemoryIndex
    public let prompts: PromptBuilder
    public let classifier: FilingClassifier
    public let labeler: LabelExtractor
    public let learner: Learner
    public let vectors: VectorIndex
    public let search: SearchService
    public let traces: TraceRecorder
    public let services: PipelineServices
    public let coordinator: IngestCoordinator
    public let rethink: RethinkCoordinator
    public let review: ReviewActions
    public let reconciler: ArchiveReconciler
    public let proposals: ProposalActions
    public let incomingWatcher: IncomingWatcher
    public let archiveWatcher: ArchiveWatcher
    public let stats: StatsService
    public let doctor: Doctor
    private let tasks = BackgroundTasks()

    public static func bootstrap(appVersion: String, environment: RuntimeEnvironment = .current,
                                 echoLogsToStderr: Bool) async throws -> ArrumatorRuntime {
        let paths = AppPaths.resolve(environment)
        try paths.ensureDirectories()
        let config = try PipelineConfig.load(paths: paths, environment: environment)
        let settings = try SettingsStore(paths: paths)
        let current = await settings.current
        Log.shared.configure(directory: paths.logsDirectory, minLevel: environment.logLevel ?? current.logLevel,
                             config: config.logging, echoToStderr: echoLogsToStderr)
        Log.shared.prune(config.logging)
        // The archive's folder names its index, so it exists before the index opens.
        try FileManager.default.createDirectory(at: current.archiveURL, withIntermediateDirectories: true)
        try paths.moveSingleIndex(to: try paths.indexURL(for: current.archiveURL))
        return try ArrumatorRuntime(appVersion: appVersion, environment: environment, paths: paths, config: config,
                                    settings: settings, archive: current.archiveURL,
                                    ollamaURL: try OllamaEndpoint.validated(environment.ollamaURL ?? current.ollamaURL))
    }

    /// Points the app at the Ollama server at `address` — this Mac or a machine on the local network — from now on,
    /// and remembers it. An address elsewhere is refused and nothing changes. Whether the server answers is the
    /// caller's to check (`lifecycle.ensureRunning()`).
    public func useOllama(at address: String) async throws {
        let url = try OllamaEndpoint.validated(address)
        try ollama.connect(to: url)
        let updated = try await settings.update { $0.ollamaURL = url.absoluteString }
        await lifecycle.configure(management: Self.management(for: updated, at: url), binaryOverride: updated.ollamaBinaryPath)
        try await services.history.record(.settingsChanged, actor: .user, summary: "Ollama at \(url.absoluteString)",
                                          payload: ["ollamaURL": url.absoluteString])
        Log.info(.ollama, "Using Ollama", ["url": url.absoluteString])
    }

    /// A server on another machine is the user's to run: the app starts and stops only one on this Mac.
    public static func management(for settings: AppSettings, at url: URL) -> OllamaManagement {
        OllamaEndpoint.isThisMac(url) ? settings.ollamaManagement : .external
    }

    /// Stops this runtime and returns one open on the archive at `path`, with that archive's own index, logic and
    /// learned state; the settings name it from then on. Files waiting in Incoming are filed into the new archive.
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
        if try await RethinkStore(database: database).activeRun()?.status == .applying { throw ArchiveSwitchError.rethinkApplying }

        // The new index opens before anything stops, so a failure leaves this runtime as it was.
        let nextSettings = try SettingsStore(paths: paths)
        let next = try ArrumatorRuntime(appVersion: appVersion, environment: environment, paths: paths, config: config,
                                        settings: nextSettings, archive: target, ollamaURL: ollama.baseURL)
        await stop()
        let waiting = try await JobStore(database: database).cancelActive(kinds: [.ingest])
        try await services.history.record(
            .settingsChanged, actor: .user,
            summary: "Switched to the archive at \(target.path)" + (waiting > 0 ? "; \(Format.count(waiting, "file")) waiting in Incoming go there" : ""),
            payload: ["archive": target.path])
        try await records.flush()
        try await nextSettings.update { $0.archivePath = target.path }
        Log.info(.app, "Switched archives", ["from": archive.path, "to": target.path, "index": next.index.path])
        return next
    }

    /// Brings the index in line with the archive before anything else uses it: a new or set-aside index is rebuilt
    /// from the record files, otherwise record files changed on disk are read again; then the archive's logic is
    /// given the built-in text if it has none, and every stale record file written. Reads the archive, so macOS may
    /// first ask for access to it.
    public func openArchive() async throws {
        await taxonomy.exclude([await settings.current.incomingURL])
        if opening.needsRebuild, try await records.archiveHasRecords() {
            let summary = try await records.rebuild()
            Log.info(.app, "Index rebuilt from the archive", ["documents": String(summary.documents), "queued": String(summary.queued)])
        } else {
            try await records.reconcile()
        }
        try await logic.sync(builtin: try prompts.builtinLogic())
        try await records.flush()
    }

    private init(appVersion: String, environment: RuntimeEnvironment, paths: AppPaths, config: PipelineConfig,
                 settings: SettingsStore, archive: URL, ollamaURL: URL) throws {
        self.appVersion = appVersion
        self.environment = environment
        self.paths = paths
        self.config = config
        self.settings = settings
        self.archive = archive
        index = try paths.indexURL(for: archive)
        (database, opening) = try AppDatabase.open(at: index, setAsideSuffix: config.records.setAsideSuffix) {
            ArchiveRecords.mayHoldRecords(archive: archive, config: config)
        }
        registry = SelfChangeRegistry(ttl: config.watcher.selfChangeTTLSeconds)
        taxonomy = TaxonomyStore(database: database, config: config.taxonomy, registry: registry)
        records = ArchiveRecords(database: database, settings: settings, taxonomy: taxonomy, config: config, registry: registry)
        ollama = try OllamaConnection(config: config.ollama, url: ollamaURL)
        gate = InferenceGate(api: ollama, retryDelays: config.ollama.retryDelays)
        models = ModelManager(api: ollama, config: config.ollama)
        lifecycle = OllamaLifecycle(api: ollama, config: config.ollama, management: .external, binaryOverride: nil)
        learningStore = GRDBLearningStore(database: database)
        memories = MemoryIndex(store: learningStore)
        let library = try PromptLibrary.bundled()
        prompts = PromptBuilder(library: library, config: config.classification, naming: config.naming)
        classifier = FilingClassifier(store: learningStore,
                                      logic: LogicStore(database: database, maxChars: config.classification.logicMaxChars),
                                      memories: memories, gate: gate, models: models, prompts: prompts)
        labeler = LabelExtractor(gate: gate, models: models, prompts: prompts)
        let skip = SkipRules(watcher: config.watcher, taxonomy: config.taxonomy)
        let history = HistoryStore(database: database)
        learner = Learner(store: learningStore, memories: memories, settings: settings, config: config, taxonomy: taxonomy,
                          refresher: DescriptionRefresher(store: learningStore, gate: gate, library: library,
                                                          config: config.learning.descriptionRefresh),
                          absorber: FolderAbsorber(store: learningStore, gate: gate, library: library, config: config.learning,
                                                   skip: skip),
                          history: history)
        vectors = VectorIndex()
        search = SearchService(database: database, vectors: vectors, embedder: nil, config: config.search)
        traces = TraceRecorder(database: database, appVersion: appVersion)
        let placer = Placer(builder: FilenameBuilder(config: config.naming), operations: FileOperations(naming: config.naming))
        services = PipelineServices(
            database: database, config: config, settings: settings, taxonomy: taxonomy,
            extractor: ExtractorRegistry(ollama: GatedOllama(gate: gate)), labeler: labeler, classifier: classifier, learner: learner,
            filer: DocumentFiler(database: database, placer: placer, index: IndexStore(database: database), registry: registry),
            traces: traces, vectors: vectors)
        coordinator = IngestCoordinator(services: services)
        rethink = RethinkCoordinator(services: services, ingest: coordinator)
        review = ReviewActions(services: services, coordinator: coordinator)
        reconciler = ArchiveReconciler(services: services, coordinator: coordinator)
        proposals = ProposalActions(database: database, taxonomy: taxonomy, settings: settings)
        incomingWatcher = IncomingWatcher(config: config.watcher, skip: skip)
        archiveWatcher = ArchiveWatcher(config: config.watcher, taxonomy: config.taxonomy, skip: skip, registry: registry,
                                        database: database)
        stats = StatsService(database: database, config: config.stats)
        doctor = Doctor(database: database, paths: paths, appVersion: appVersion)
    }

    // MARK: Lifecycle

    /// Starts Ollama supervision, the ingest worker, both watchers and maintenance. Returns immediately.
    public func start() async {
        let current = await settings.current
        Log.info(.app, "Arrumator starting", ["version": appVersion, "archive": current.archivePath, "incoming": current.incomingPath])
        _ = try? await HistoryStore(database: database).record(.appStarted, summary: "Arrumator \(appVersion) started")
        await apply(current)
        await tasks.run("ollama") { [lifecycle] in
            await lifecycle.ensureRunning()
            await lifecycle.startMonitoring()
        }
        await coordinator.start()
        await rethink.start()
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
        await tasks.run("settings") { [settings, database, weak self] in
            for await changed in await settings.changes() {
                _ = try? await HistoryStore(database: database).record(.settingsChanged, actor: .user, summary: "Settings changed",
                                                                        payload: changed)
                await self?.apply(changed)
            }
        }
        await tasks.run("ollama-audit") { [lifecycle, database] in
            var previous: OllamaState?
            for await state in await lifecycle.states() where state != .unknown && state != .starting {
                if let previous, previous.isReady == state.isReady { continue }
                previous = state
                _ = try? await HistoryStore(database: database).record(.ollamaState, summary: state.summary)
            }
        }
        await tasks.run("maintenance") { [weak self] in
            while !Task.isCancelled {
                await self?.maintain()
                try? await Task.sleep(for: .seconds(Self.maintenanceInterval))
            }
        }
    }

    /// Maintenance cadence (log pruning, trace trimming, stale-job watchdog).
    static let maintenanceInterval: Double = 3_600

    public func stop() async {
        await tasks.cancelAll()
        do { try await records.flush() } catch {
            Log.error(.db, "Could not write record files before stopping", ["error": error.localizedDescription])
        }
        await coordinator.stop()
        await rethink.stop()
        await incomingWatcher.stop()
        await archiveWatcher.stop()
        await lifecycle.shutdown()
        Log.info(.app, "Arrumator stopped")
    }

    /// Applies (changed) settings: Ollama management, watched folders, embedding model for search.
    public func apply(_ current: AppSettings) async {
        await lifecycle.configure(management: Self.management(for: current, at: ollama.baseURL), binaryOverride: current.ollamaBinaryPath)
        Log.shared.setMinLevel(environment.logLevel ?? current.logLevel)
        do {
            try await prepareSearch(current)
            try FileManager.default.createDirectory(at: current.archiveURL, withIntermediateDirectories: true)
            try await incomingWatcher.start(root: current.incomingURL)
            await taxonomy.exclude([current.incomingURL])
            try await archiveWatcher.start(root: current.archiveURL, excluding: [current.incomingURL])
            _ = try await taxonomy.sync(root: current.archiveURL)
        } catch {
            Log.error(.app, "Could not apply settings", ["error": error.localizedDescription])
        }
        await coordinator.wake()
    }

    /// Loads the vector index and the query embedder for the configured embedding model (no watchers started).
    public func prepareSearch(_ current: AppSettings) async throws {
        let resolved = try config.models(for: current.models)
        await search.setEmbedder(OllamaEmbedder(gate: gate, model: resolved.embed, keepAlive: resolved.keepAliveEmbed,
                                                numCtx: config.classification.embeddingNumCtx))
        if await vectors.model != resolved.embed {
            await vectors.load(model: resolved.embed, rows: try await IndexStore(database: database).embeddings(model: resolved.embed))
        }
    }

    private func maintain() async {
        let current = await settings.current
        Log.shared.prune(config.logging)
        do {
            let trimmed = try await traces.trimRawPayloads(olderThanDays: current.traceRawRetentionDays)
            if trimmed > 0 { Log.info(.app, "Trimmed raw model payloads", ["steps": String(trimmed)]) }
            let jobs = JobStore(database: database)
            for var job in try await jobs.stale(olderThan: config.ingest.watchdogMinutes * 60, now: Date()) {
                Log.warning(.ingest, "Watchdog: job stuck, rescheduling", ["job": String(job.id ?? 0), "state": job.state.rawValue])
                job.nextRunAt = Date()
                try await jobs.update(job)
            }
        } catch {
            Log.error(.app, "Maintenance failed", ["error": error.localizedDescription])
        }
        await learner.settleUntouchedFilings()
        do { try await records.flush() } catch {
            Log.error(.db, "Could not write record files", ["error": error.localizedDescription])
        }
        await coordinator.wake()
    }

    // MARK: Logic

    /// The logic of this archive.
    public var logic: LogicStore { services.logic }

    /// Restores the archive's logic to the text that ships with this version of the app.
    @discardableResult
    public func resetLogic() async throws -> LogicRecord {
        try await logic.reset(to: try prompts.builtinLogic())
    }

    /// Where this archive is kept, where its index is, and the state of its logic.
    public func summary() async throws -> ArchiveSummary {
        let logic = try await logic.current()
        return ArchiveSummary(archive: archive.path, index: index.path,
                              logicFile: try await records.logicFileURL()?.path, logicVersion: LogicStore.version(of: logic),
                              logicFollowsBuiltin: logic?.followsBuiltin ?? false)
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
