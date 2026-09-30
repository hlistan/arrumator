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
    public let reconciler: ArchiveReconciler
    public let incomingWatcher: IncomingWatcher
    public let archiveWatcher: ArchiveWatcher
    public let stats: StatsService
    public let doctor: Doctor
    private let tasks = BackgroundTasks()

    public static func bootstrap(appVersion: String, environment: RuntimeEnvironment,
                                 echoLogsToStderr: Bool) async throws -> ArrumatorRuntime {
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
                                    ollamaURL: try OllamaEndpoint.validated(environment.ollamaURL ?? current.ollamaURL))
    }

    /// Points the app at the Ollama server at `address` — this Mac or a machine on the local network — from now on,
    /// and remembers it. An address elsewhere is refused and nothing changes. Whether the server answers is the
    /// caller's to check (`lifecycle.ensureRunning()`).
    public func useOllama(at address: String) async throws {
        let url = try OllamaEndpoint.validated(address)
        try ollama.connect(to: url)
        let updated = try await settings.update { $0.ollamaURL = url.absoluteString }
        await lifecycle.configure(management: Self.management(for: updated, at: url), binaryOverride: updated.ollamaBinaryPath,
                                  address: url)
        try await services.history.record(.settingsChanged, actor: .user, summary: "Ollama at \(url.absoluteString)",
                                          payload: ["ollamaURL": url.absoluteString])
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
                                        ollamaURL: ollama.baseURL)
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
                 paths: AppPaths, config: PipelineConfig, settings: SettingsStore, archive: URL, ollamaURL: URL) throws {
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
            traces: traces, vectors: vectors, time: time)
        coordinator = IngestCoordinator(services: services)
        review = ReviewActions(services: services, coordinator: coordinator)
        labels = LabelActions(database: database, time: time)
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

    /// Starts Ollama supervision, the ingest worker, both watchers and maintenance. Returns immediately.
    public func start() async {
        let current = await settings.current
        Log.info(.app, "Arrumator starting", ["version": appVersion, "archive": current.archivePath, "incoming": current.incomingPath])
        await audit(.appStarted, actor: .system, summary: "Arrumator \(appVersion) started", payload: nil)
        await apply(current)
        await tasks.run("ollama") { [lifecycle] in
            await lifecycle.ensureRunning()
            await lifecycle.startMonitoring()
        }
        await coordinator.start()
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
        await tasks.run("settings") { [settings, weak self] in
            var previous = current
            for await changed in await settings.changes() {
                // Pausing has its own event (`setPaused`); every other change is recorded as a settings change.
                var pauseAlone = previous
                pauseAlone.paused = changed.paused
                let onlyPaused = pauseAlone == changed
                previous = changed
                if !onlyPaused {
                    await self?.audit(.settingsChanged, actor: .user, summary: "Settings changed", payload: changed)
                }
                await self?.apply(changed)
            }
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

    public func stop() async {
        await tasks.cancelAll()
        do { try await records.flush() } catch {
            Log.error(.db, "Could not write record files before stopping", ["error": error.localizedDescription])
        }
        await coordinator.stop()
        await incomingWatcher.stop()
        await archiveWatcher.stop()
        await lifecycle.shutdown()
        Log.info(.app, "Arrumator stopped")
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

    /// Loads the vector index and the query embedder for the configured embedding model (no watchers started).
    public func prepareSearch(_ current: AppSettings) async throws {
        let resolved = try config.models(for: current.models)
        await search.setEmbedder(OllamaEmbedder(gate: gate, model: resolved.embed, keepAlive: resolved.keepAliveEmbed,
                                                numCtx: config.analysis.embeddingNumCtx))
        if await vectors.model != resolved.embed {
            await vectors.load(model: resolved.embed, rows: try await services.index.embeddings(model: resolved.embed))
        }
    }

    private func maintain() async {
        let current = await settings.current
        Log.shared.prune(config.logging, now: time.now())
        do {
            let trimmed = try await traces.trimRawPayloads(olderThanDays: current.traceRawRetentionDays)
            if trimmed > 0 { Log.info(.app, "Trimmed raw model payloads", ["steps": String(trimmed)]) }
            let jobs = services.jobs
            for var job in try await jobs.stale(olderThan: config.ingest.watchdogMinutes * Units.secondsPerMinute) {
                Log.warning(.ingest, "Watchdog: job stuck, rescheduling", ["job": String(job.id ?? 0), "state": job.state.rawValue])
                job.nextRunAt = time.now()
                try await jobs.update(job)
            }
        } catch {
            Log.error(.app, "Maintenance failed", ["error": error.localizedDescription])
        }
        do { try await records.flush() } catch {
            Log.error(.db, "Could not write record files", ["error": error.localizedDescription])
        }
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
