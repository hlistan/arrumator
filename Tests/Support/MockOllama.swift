import ArrumatorCore
import Foundation

/// Offline stand-in for Ollama: scripted chat answers, deterministic bag-of-words embeddings, call recording.
public actor MockOllama: OllamaAPI {
    public typealias ChatHandler = @Sendable (OllamaChatRequest) throws -> String

    public private(set) var chatRequests: [OllamaChatRequest] = []
    public private(set) var embedRequests: [OllamaEmbedRequest] = []
    private let handler: ChatHandler
    private let installed: [String]
    private let dimension: Int
    private let capabilities: [String]

    /// `capabilities` are what `show` reports for every model, as Ollama lists them ("completion", "vision", …).
    public init(installed: [String] = [], dimension: Int = 256, capabilities: [String] = ["completion"],
                handler: @escaping ChatHandler) {
        self.installed = installed
        self.dimension = dimension
        self.capabilities = capabilities
        self.handler = handler
    }

    public var chatCount: Int { chatRequests.count }

    public func version() async throws -> String { "mock" }

    public func tags() async throws -> [OllamaModelInfo] {
        installed.map { OllamaModelInfo(name: $0, model: $0, size: 1, digest: nil, modifiedAt: nil, details: nil) }
    }

    public func show(model: String) async throws -> OllamaShowResponse {
        OllamaShowResponse(capabilities: capabilities, modelInfo: nil, details: nil)
    }

    public func chat(_ request: OllamaChatRequest) async throws -> OllamaChatResponse {
        chatRequests.append(request)
        let content = try handler(request)
        return OllamaChatResponse(model: request.model, message: OllamaMessage(role: "assistant", content: content), done: true,
                                  doneReason: "stop", totalDuration: 1_000_000, loadDuration: 0, promptEvalCount: 10,
                                  promptEvalDuration: 500_000, evalCount: 5, evalDuration: 500_000)
    }

    public func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse {
        embedRequests.append(request)
        return OllamaEmbedResponse(model: request.model, embeddings: request.input.map { Self.hashEmbedding($0, dimension: dimension) },
                                   totalDuration: nil, loadDuration: nil, promptEvalCount: nil)
    }

    public nonisolated func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> {
        AsyncThrowingStream { c in
            c.yield(OllamaPullProgress(status: "success", digest: nil, total: 1, completed: 1, error: nil))
            c.finish()
        }
    }

    /// Stable FNV-1a hashed bag of words, L2-normalised: similar texts get similar vectors.
    public static func hashEmbedding(_ text: String, dimension: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for w in words where w.count > 2 {
            var h: UInt64 = 0xcbf29ce484222325
            for b in w.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            v[Int(h % UInt64(dimension))] += 1
        }
        return VectorCodec.normalized(v)
    }
}

extension OllamaChatRequest {
    /// Concatenated text of all messages, handy for asserting prompt content.
    public var allText: String { messages.map(\.content).joined(separator: "\n") }
}
