import ArrumatorCore
import Foundation

/// The ingest pipeline over a `TestEnvironment`, with the plain-text extractor and an analyzer double: what the
/// suites that file documents share.
public struct Harness: Sendable {
    public let env: TestEnvironment
    public let services: PipelineServices
    public let coordinator: IngestCoordinator

    public static func make(analyzer: any DocumentAnalyzing = StubAnalyzer()) async throws -> Harness {
        let env = try await TestEnvironment.make()
        return Harness(env: env, services: services(env, analyzer: analyzer, config: env.config))
    }

    public init(env: TestEnvironment, services: PipelineServices) {
        self.env = env
        self.services = services
        coordinator = IngestCoordinator(services: services)
    }

    /// The pipeline's services over `env`, with `config` in force.
    public static func services(_ env: TestEnvironment, analyzer: any DocumentAnalyzing, config: PipelineConfig) -> PipelineServices {
        let placer = Placer(builder: FilenameBuilder(config: config.naming), operations: FileOperations(naming: config.naming))
        return PipelineServices(
            database: env.database, config: config, settings: env.settings, extractor: PlainTestExtractor(), analyzer: analyzer,
            filer: DocumentFiler(database: env.database, placer: placer, index: IndexStore(database: env.database, time: env.time),
                                 registry: SelfChangeRegistry(ttl: config.watcher.selfChangeTTLSeconds, time: env.time), time: env.time),
            traces: TraceRecorder(database: env.database, appVersion: "test", time: env.time), vectors: VectorIndex(), trash: env.trash,
            time: env.time)
    }

    /// The same pipeline with `change` made to its configuration, such as retries without delay.
    public func with(_ change: (inout PipelineConfig) -> Void) -> Harness {
        var config = services.config
        change(&config)
        return Harness(env: env, services: Self.services(env, analyzer: services.analyzer, config: config))
    }

    public var review: ReviewActions { ReviewActions(services: services, coordinator: coordinator) }

    /// Search tasks over this pipeline, their prompts read by `interpreter`: the queue and what the user does with them.
    public func searchTasks(_ interpreter: any SearchPromptInterpreting) -> (queue: SearchTaskQueue, actions: SearchTaskActions) {
        let queue = SearchTaskQueue(services: services, interpreter: interpreter)
        return (queue, SearchTaskActions(services: services, queue: queue))
    }
    public var labels: LabelActions { LabelActions(database: env.database, time: env.time) }
    public var search: SearchService { SearchService(database: env.database, vectors: VectorIndex(), embedder: nil, config: env.config.search) }

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

/// Reads each file as `StubAnalyzer` does, named after its file, with the labels listed for its name and none for the
/// rest.
public struct PerFileAnalyzer: DocumentAnalyzing {
    public let labels: [String: [DocumentLabel]]

    public init(labels: [String: [DocumentLabel]]) { self.labels = labels }

    public func analyse(_ content: ExtractedContent, guidance: LabelGuidance, settings: AppSettings, config: PipelineConfig,
                        trace: TraceContext) async throws -> AnalysisOutcome {
        var outcome = try await StubAnalyzer(fileName: content.source.stem).analyse(content, guidance: guidance, settings: settings,
                                                                                     config: config, trace: trace)
        outcome.labels = labels[content.source.originalFilename] ?? []
        return outcome
    }

    public func embedding(for content: ExtractedContent, senders: [String], settings: AppSettings, config: PipelineConfig,
                          trace: TraceContext) async throws -> (vector: [Float], model: String)? { nil }
}
