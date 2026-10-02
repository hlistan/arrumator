import Foundation
import Synchronization

/// The Ollama server the app talks to. Every service holds this connection, which forwards to the client for the
/// current address, so pointing the app at another server on the local network needs no restart.
public final class OllamaConnection: OllamaAPI, Sendable {
    private let config: OllamaConfig
    private let time: any TimeSource
    private let client: Mutex<OllamaClient>

    public init(config: OllamaConfig, url: URL, time: any TimeSource) throws {
        self.config = config
        self.time = time
        client = Mutex(try OllamaClient(config: config, baseURL: url, time: time))
    }

    public var baseURL: URL { client.withLock { $0.baseURL } }

    /// Talks to the server at `url` from now on. `url` must come from `OllamaEndpoint.validated`.
    public func connect(to url: URL) throws {
        let next = try OllamaClient(config: config, baseURL: url, time: time)
        client.withLock { $0 = next }
    }

    private var current: OllamaClient { client.withLock { $0 } }

    public func version() async throws -> String { try await current.version() }
    public func tags() async throws -> [OllamaModelInfo] { try await current.tags() }
    public func show(model: String) async throws -> OllamaShowResponse { try await current.show(model: model) }
    public func chat(_ request: OllamaChatRequest, partial: (@Sendable (OllamaChatResponse) async -> Void)?) async throws -> OllamaChatResponse {
        try await current.chat(request, partial: partial)
    }
    public func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse { try await current.embed(request) }
    public func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> { current.pull(model: model) }
}
