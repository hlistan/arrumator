import Foundation

/// What a model of the profile is used for (`ModelProfile.roles`, `ModelProfile.model(for:)`).
public enum ModelRole: String, Sendable, Hashable, Codable, CaseIterable {
    case chat, vision, embedding
}

public struct ModelStatus: Sendable, Hashable, Codable {
    public var name: String
    public var role: ModelRole
    public var installed: Bool
    public var sizeBytes: Int64?
    /// Where Ollama runs the model when not on its own server (`ModelLocation.remoteHost`): nothing is read with it.
    public var remoteHost: String?
}

/// A model Ollama has installed, and what a profile can give it to do (`ModelManager.installed()`): what the profile
/// editor and `arrumatorcli models list` offer for each role.
public struct InstalledModel: Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var sizeBytes: Int64?
    /// What Ollama says the model can do, as it lists them: "completion", "vision", "embedding", "thinking", "tools", …
    public var capabilities: [String]
    /// The roles of a profile it can take: a model that answers in words reads (`chat`), and describes images (`vision`)
    /// when it also sees them; one that embeds finds by meaning (`embedding`).
    public var roles: [ModelRole]
    /// How it can be told to think (`OllamaShowResponse.thinkingValues`): its switches, `true` and `false`, or the levels
    /// it names; none for a model that cannot think.
    public var thinking: [OllamaThink]
    /// Where Ollama runs it when not on its own server (`ModelLocation.remoteHost`): a profile can then give it nothing.
    public var remoteHost: String?

    public var id: String { name }

    public init(name: String, sizeBytes: Int64?, shown: OllamaShowResponse, remoteHost: String?) {
        self.name = name
        self.sizeBytes = sizeBytes
        let capabilities = shown.capabilities ?? []
        self.capabilities = capabilities
        let answers = capabilities.contains(OllamaShowResponse.completionCapability)
        let roles = [(ModelRole.chat, answers), (.vision, answers && capabilities.contains(OllamaShowResponse.visionCapability)),
                     (.embedding, capabilities.contains(OllamaShowResponse.embeddingCapability))].filter(\.1).map(\.0)
        self.roles = remoteHost == nil ? roles : []
        thinking = shown.thinkingValues
        self.remoteHost = remoteHost
    }
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

/// Tracks which configured models are installed, their capabilities and which run elsewhere, and downloads missing
/// ones on request.
public actor ModelManager {
    private let api: any OllamaAPI
    private let config: OllamaConfig
    private var capabilities: [String: OllamaShowResponse] = [:]

    public init(api: any OllamaAPI, config: OllamaConfig) {
        self.api = api
        self.config = config
    }

    public static func normalized(_ name: String) -> String { name.contains(":") ? name : name + ":latest" }

    /// Whether each model of `profile` is installed, in its role, how large it is, and where it runs when not on the
    /// server itself.
    public func status(for profile: ModelProfile) async throws -> [ModelStatus] {
        let installed = try await api.tags()
        let listed = Dictionary(installed.map { (Self.normalized($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        return ModelProfile.roles.map { role in
            let name = profile.model(for: role)
            let entry = listed[Self.normalized(name)]
            return ModelStatus(name: name, role: role, installed: entry != nil, sizeBytes: entry?.size,
                               remoteHost: ModelLocation.remoteHost(of: name, said: entry?.remoteHost))
        }
    }

    /// Every installed model in Ollama's order, with its size, what it can do and where it runs when not on the server
    /// itself (`InstalledModel`), what Ollama says of each read once and kept (`capabilities(of:)`).
    public func installed() async throws -> [InstalledModel] {
        var models: [InstalledModel] = []
        for model in try await api.tags() {
            let shown = try await capabilities(of: model.name)
            models.append(InstalledModel(name: model.name, sizeBytes: model.size, shown: shown,
                                         remoteHost: ModelLocation.remoteHost(of: model.name, said: model.remoteHost ?? shown.remoteHost)))
        }
        return models
    }

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
        let freeGB = Double(values.volumeAvailableCapacityForImportantUsage ?? 0) / Units.bytesPerGigabyte
        guard freeGB > config.requiredFreeDiskGBAfterPull else {
            throw ModelManagerError.insufficientDisk(neededGB: config.requiredFreeDiskGBAfterPull, freeGB: freeGB)
        }
        Log.info(.ollama, "Pulling model (user request)", ["model": model])
        capabilities[model] = nil
        return api.pull(model: model)
    }
}

/// Serialises generation calls (one large model at a time) and retries transient failures, except an answer that took
/// longer than its request's own timeout (`OllamaError.isTransient(asking:)`). Embedding calls use a separate lane so
/// search stays responsive during long classifications.
public actor InferenceGate {
    private let api: any OllamaAPI
    private let retryDelays: [Double]
    private let time: any TimeSource
    private let generation = AsyncSemaphore(permits: 1)
    private let embedding = AsyncSemaphore(permits: 1)

    public init(api: any OllamaAPI, retryDelays: [Double], time: any TimeSource) {
        self.api = api
        self.retryDelays = retryDelays
        self.time = time
    }

    public nonisolated var client: any OllamaAPI { api }

    /// The model's answer to `request`, streamed to `partial` as `OllamaAPI.chat(_:partial:)` streams it. One asked
    /// again after a transient failure is streamed from its start again. Without `retrying`, a transient failure is
    /// thrown at once, for a caller that waits for Ollama in a way of its own and says so.
    public func chat(_ request: OllamaChatRequest, retrying: Bool = true,
                     partial: (@Sendable (OllamaChatResponse) async -> Void)? = nil) async throws -> OllamaChatResponse {
        let api = api
        let delays = retrying ? retryDelays : []
        let time = time
        return try await generation.withPermit {
            try await Retry.run(delays: delays, time: time, shouldRetry: { ($0 as? OllamaError)?.isTransient(asking: request) ?? false },
                                onRetry: { n, e in
                                    Log.warning(.ollama, "Retrying chat", ["attempt": String(n), "error": e.localizedDescription])
                                }) {
                try await api.chat(request, partial: partial)
            }
        }
    }

    public func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse {
        let api = api
        let delays = retryDelays
        let time = time
        return try await embedding.withPermit {
            try await Retry.run(delays: delays, time: time, shouldRetry: { ($0 as? OllamaError)?.isTransient ?? false },
                                onRetry: { n, e in
                                    Log.warning(.ollama, "Retrying embedding", ["attempt": String(n), "error": e.localizedDescription])
                                }) {
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
    public func show(model: String) async throws -> OllamaShowResponse { try await gate.client.show(model: model) }
    public func chat(_ request: OllamaChatRequest, partial: (@Sendable (OllamaChatResponse) async -> Void)?) async throws -> OllamaChatResponse {
        try await gate.chat(request, partial: partial)
    }
    public func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse { try await gate.embed(request) }
    public func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> { gate.client.pull(model: model) }
}
