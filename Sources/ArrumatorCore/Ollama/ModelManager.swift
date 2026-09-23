import Foundation

public struct ModelStatus: Sendable, Hashable, Codable {
    public var name: String
    public var role: String
    public var installed: Bool
    public var sizeBytes: Int64?
}

public enum ModelManagerError: Error, LocalizedError {
    case insufficientDisk(neededGB: Double, freeGB: Double)
    public var errorDescription: String? {
        switch self {
        case let .insufficientDisk(need, free):
            String(format: "Not enough disk space: %.1f GB free, at least %.1f GB must remain after download", free, need)
        }
    }
}

/// Tracks which configured models are installed, their capabilities, and downloads missing ones on request.
public actor ModelManager {
    private let api: any OllamaAPI
    private let config: OllamaConfig
    private var capabilities: [String: OllamaShowResponse] = [:]

    public init(api: any OllamaAPI, config: OllamaConfig) {
        self.api = api
        self.config = config
    }

    public static func normalized(_ name: String) -> String { name.contains(":") ? name : name + ":latest" }

    public func status(for models: ResolvedModels) async throws -> [ModelStatus] {
        let installed = try await api.tags()
        let bySize = Dictionary(installed.map { (Self.normalized($0.name), $0.size) }, uniquingKeysWith: { a, _ in a })
        let roles: [(String, String)] = [("chat", models.chat), ("vision", models.vision), ("embedding", models.embed),
                                         ("fast", models.fast)]
        return roles.map { role, name in
            let key = Self.normalized(name)
            return ModelStatus(name: name, role: role, installed: bySize.keys.contains(key), sizeBytes: bySize[key] ?? nil)
        }
    }

    public func missing(for models: ResolvedModels) async throws -> [String] {
        Array(Set(try await status(for: models).filter { !$0.installed }.map(\.name))).sorted()
    }

    public func installed() async throws -> [OllamaModelInfo] { try await api.tags() }

    public func capabilities(of model: String) async throws -> OllamaShowResponse {
        if let cached = capabilities[model] { return cached }
        let info = try await api.show(model: model)
        capabilities[model] = info
        return info
    }

    /// Downloads a model. Only ever called from an explicit user action (it needs the internet).
    public func pull(_ model: String) throws -> AsyncThrowingStream<OllamaPullProgress, any Error> {
        let values = try FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let freeGB = Double(values.volumeAvailableCapacityForImportantUsage ?? 0) / 1_073_741_824
        guard freeGB > config.requiredFreeDiskGBAfterPull else {
            throw ModelManagerError.insufficientDisk(neededGB: config.requiredFreeDiskGBAfterPull, freeGB: freeGB)
        }
        Log.info(.ollama, "Pulling model (user request)", ["model": model])
        capabilities[model] = nil
        return api.pull(model: model)
    }
}

/// Serialises generation calls (one large model at a time) and retries transient failures.
/// Embedding calls use a separate lane so search stays responsive during long classifications.
public actor InferenceGate {
    private let api: any OllamaAPI
    private let retryDelays: [Double]
    private let generation = AsyncSemaphore(permits: 1)
    private let embedding = AsyncSemaphore(permits: 1)

    public init(api: any OllamaAPI, retryDelays: [Double]) {
        self.api = api
        self.retryDelays = retryDelays
    }

    public nonisolated var client: any OllamaAPI { api }

    public func chat(_ request: OllamaChatRequest) async throws -> OllamaChatResponse {
        let api = api
        let delays = retryDelays
        return try await generation.withPermit {
            try await Retry.run(delays: delays, shouldRetry: { ($0 as? OllamaError)?.isTransient ?? false },
                                onRetry: { n, e in
                                    Log.warning(.ollama, "Retrying chat", ["attempt": String(n), "error": e.localizedDescription])
                                }) {
                try await api.chat(request)
            }
        }
    }

    public func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse {
        let api = api
        let delays = retryDelays
        return try await embedding.withPermit {
            try await Retry.run(delays: delays, shouldRetry: { ($0 as? OllamaError)?.isTransient ?? false }) {
                try await api.embed(request)
            }
        }
    }
}

/// `Embedder` backed by an Ollama embedding model (bge-m3 by default).
public struct OllamaEmbedder: Embedder {
    public let modelId: String
    private let gate: InferenceGate
    private let keepAlive: String
    private let numCtx: Int

    public init(gate: InferenceGate, model: String, keepAlive: String, numCtx: Int) {
        modelId = model
        self.gate = gate
        self.keepAlive = keepAlive
        self.numCtx = numCtx
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let response = try await gate.embed(OllamaEmbedRequest(model: modelId, input: texts, keepAlive: keepAlive, truncate: true,
                                                               options: ["num_ctx": .number(Double(numCtx))]))
        guard response.embeddings.count == texts.count else {
            throw OllamaError.decoding("expected \(texts.count) embeddings, got \(response.embeddings.count)")
        }
        return response.embeddings.map(VectorCodec.normalized)
    }
}

/// `OllamaAPI` whose generation and embedding calls go through an `InferenceGate`, so every component (including
/// image description during extraction) shares the same one-model-at-a-time discipline and retry policy.
public struct GatedOllama: OllamaAPI {
    public let gate: InferenceGate

    public init(gate: InferenceGate) { self.gate = gate }

    public func version() async throws -> String { try await gate.client.version() }
    public func tags() async throws -> [OllamaModelInfo] { try await gate.client.tags() }
    public func running() async throws -> [OllamaRunningModel] { try await gate.client.running() }
    public func show(model: String) async throws -> OllamaShowResponse { try await gate.client.show(model: model) }
    public func chat(_ request: OllamaChatRequest) async throws -> OllamaChatResponse { try await gate.chat(request) }
    public func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse { try await gate.embed(request) }
    public func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> { gate.client.pull(model: model) }
    public func unload(model: String) async throws { try await gate.client.unload(model: model) }
}
