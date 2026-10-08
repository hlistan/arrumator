import ArrumatorCore
import Foundation

/// The ingest pipeline over a `TestEnvironment`, with the plain-text extractor, or a double of its own, and an analyzer
/// double: what the suites that file documents share.
public struct Harness: Sendable {
    public let env: TestEnvironment
    public let services: PipelineServices
    public let coordinator: IngestCoordinator
    /// The processes sharing the index, which the queues of tasks and questions tell apart.
    public let processes: TestProcesses

    /// `ollama` is the server the pipeline probes when a request to it timed out: one that answers, unless a test says.
    public static func make(analyzer: any DocumentAnalyzing = StubAnalyzer(), extractor: any ContentExtracting = PlainTestExtractor(),
                            ollama: any OllamaAPI = MockOllama { _ in "" }) async throws -> Harness {
        let env = try await TestEnvironment.make()
        return Harness(env: env, services: services(env, analyzer: analyzer, extractor: extractor, ollama: ollama, config: env.config))
    }

    public init(env: TestEnvironment, services: PipelineServices, processes: TestProcesses = TestProcesses()) {
        self.env = env
        self.services = services
        self.processes = processes
        coordinator = IngestCoordinator(services: services)
    }

    /// The pipeline's services over `env`, with `config` in force, moving files as `sameVolume` tells a rename from a
    /// copy to another volume: as the disk says, unless a test makes every move cross a volume; with `trash` as the Trash,
    /// the environment's own unless a test gives one that refuses; with `extractor` reading files, and `ollama` as the
    /// server probed when a request to it timed out; taking jobs with `claims`, this process's unless a test plays
    /// another; and on the Mac's `power`, cool and on mains unless a test says otherwise.
    public static func services(_ env: TestEnvironment, analyzer: any DocumentAnalyzing,
                                extractor: any ContentExtracting = PlainTestExtractor(), ollama: any OllamaAPI = MockOllama { _ in "" },
                                config: PipelineConfig, sameVolume: @escaping FileOperations.VolumeCheck = FileOperations.onOneVolume,
                                trash: (any Trashing)? = nil, claims: JobClaims = Harness.claims,
                                power: @escaping @Sendable () -> PowerState = { Harness.cool }) -> PipelineServices {
        let trash = trash ?? env.trash
        let placer = Placer(builder: FilenameBuilder(config: config.naming, reserved: SkipRules(watcher: config.watcher)),
                            operations: FileOperations(trash: trash, sameVolume: sameVolume))
        return PipelineServices(
            database: env.database, archive: env.archive, config: config, settings: env.settings, extractor: extractor,
            analyzer: analyzer,
            filer: DocumentFiler(database: env.database, placer: placer, index: IndexStore(database: env.database, time: env.time),
                                 registry: SelfChangeRegistry(ttl: config.watcher.selfChangeTTLSeconds, time: env.time), time: env.time),
            traces: TraceRecorder(database: env.database, appVersion: "test", time: env.time), vectors: VectorIndex(), trash: trash,
            time: env.time, ollama: ollama, timeZone: TestTime.zone, claims: claims, power: power)
    }

    /// The jobs this test process's workers hold: one for every pipeline the tests build, as the app has one.
    public static let claims = JobClaims(processes: TestProcesses())

    /// A Mac on mains, at a temperature it works at: what keeps no worker waiting.
    public static let cool = PowerState(onBattery: false, batteryPercent: nil, thermal: .nominal, lowPowerMode: false)
    /// The same pipeline over `database`, as after the index was lost and made again.
    public func over(_ database: AppDatabase) -> Harness {
        let env = env.with(database: database)
        return Harness(env: env, services: Self.services(env, analyzer: services.analyzer, config: services.config))
    }

    /// The same pipeline with `change` made to its configuration, such as retries without delay.
    public func with(_ change: (inout PipelineConfig) -> Void) -> Harness {
        var config = services.config
        change(&config)
        return Harness(env: env, services: Self.services(env, analyzer: services.analyzer, extractor: services.extractor, ollama: services.ollama,
                                                       config: config), processes: processes)
    }

    public var review: ReviewActions { ReviewActions(services: services, coordinator: coordinator) }

    /// Search tasks over this pipeline, their prompts read by `interpreter`: the queue and what the user does with them,
    /// which tells `conversations` when a task is removed, else a queue of questions of its own, and packs an export with
    /// `archiver`, which lists what it was given (`ListingArchiver`) unless a test gives another.
    public func searchTasks(_ interpreter: any SearchPromptInterpreting, conversations: TaskConversationQueue? = nil,
                            archiver: any FolderArchiving = ListingArchiver()) -> (queue: SearchTaskQueue, actions: SearchTaskActions) {
        let queue = SearchTaskQueue(services: services, interpreter: interpreter, processes: processes)
        let answering = conversations ?? self.conversations(StubAnswerer(), interpreter: interpreter).queue
        return (queue, SearchTaskActions(services: services, queue: queue, conversations: answering, archiver: archiver))
    }
    /// Conversations about tasks' documents over this pipeline, answered by `answerer`, and requests for more documents
    /// read by `interpreter`: the queue and what the user does with them.
    public func conversations(_ answerer: any TaskQuestionAnswering,
                              interpreter: any SearchPromptInterpreting) -> (queue: TaskConversationQueue, actions: TaskConversationActions) {
        let queue = TaskConversationQueue(services: services, answerer: answerer, interpreter: interpreter, search: search,
                                          processes: processes)
        return (queue, TaskConversationActions(services: services, queue: queue))
    }

    public var labels: LabelActions { LabelActions(database: env.database, time: env.time) }
    /// Search over the pipeline's index: the one vector index the pipeline fills, as the runtime shares one.
    public var search: SearchService {
        SearchService(database: env.database, vectors: services.vectors, embedder: nil, config: env.config.search, time: env.time)
    }

    /// Drops `name` into Incoming, or a folder in it when `name` is a path, and runs the pipeline over it; the document
    /// it became.
    @discardableResult
    public func ingest(_ name: String, text: String) async throws -> DocumentRecord {
        let url = try env.drop(name, text: text)
        await coordinator.enqueue(url)
        await coordinator.drain()
        guard let document = try await services.documents.list(DocumentFilter(), limit: env.config.interface.pageSize)
            .first(where: { $0.originalFilename == url.lastPathComponent }) else { throw IngestError.sourceMissing(url.path) }
        return document
    }
}

/// Reads each file as `StubAnalyzer` does, with the labels listed for its name and none for the rest, and no title, so
/// that each keeps its file's name.
public struct PerFileAnalyzer: DocumentAnalyzing {
    public let labels: [String: [DocumentLabel]]

    public init(labels: [String: [DocumentLabel]]) { self.labels = labels }

    public func analyse(_ content: ExtractedContent, guidance: LabelGuidance, settings: AppSettings, config: PipelineConfig,
                        trace: TraceContext) async throws -> AnalysisOutcome {
        var outcome = try await StubAnalyzer(title: nil).analyse(content, guidance: guidance, settings: settings,
                                                                                     config: config, trace: trace)
        outcome.labels = labels[content.source.originalFilename] ?? []
        return outcome
    }

    public func embedding(for content: ExtractedContent, senders: [String], interpretation: String?, settings: AppSettings,
                          config: PipelineConfig, trace: TraceContext) async throws -> (vector: [Float], model: String)? { nil }
}
