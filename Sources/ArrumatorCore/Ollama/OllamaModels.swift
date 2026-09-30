import Foundation

public enum OllamaError: Error, LocalizedError, Equatable {
    case invalidBaseURL(String)
    case nonLocalHost(String)
    case unreachable(String)
    case http(status: Int, body: String)
    case modelNotFound(String)
    case decoding(String)
    case timeout(String)
    case emptyResponse
    /// Ollama reported a failure while downloading a model, in the progress it streams.
    case pullFailed(model: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(u): "Invalid Ollama URL: \(u)"
        case let .nonLocalHost(h): "Refusing to contact non-local host \(h): recognition must stay on this Mac"
        case let .unreachable(m): "Ollama is not reachable: \(m)"
        case let .http(status, body): "Ollama HTTP \(status): \(body.prefix(300))"
        case let .modelNotFound(m): "Model \(m) is not installed in Ollama"
        case let .decoding(m): "Unexpected Ollama response: \(m)"
        case let .timeout(what): "Ollama timed out: \(what)"
        case .emptyResponse: "Ollama returned an empty response"
        case let .pullFailed(model, message): "Downloading \(model) failed: \(message)"
        }
    }

    /// Transient failures worth retrying with backoff.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .timeout, .emptyResponse: true
        case let .http(status, _): status >= 500
        default: false
        }
    }
}

public struct OllamaModelInfo: Sendable, Codable, Hashable {
    public var name: String
    public var model: String?
    public var size: Int64?
    public var digest: String?
    public var modifiedAt: String?
    public var details: Details?

    public init(name: String, model: String?, size: Int64?, digest: String?, modifiedAt: String?, details: Details?) {
        self.name = name
        self.model = model
        self.size = size
        self.digest = digest
        self.modifiedAt = modifiedAt
        self.details = details
    }

    public struct Details: Sendable, Codable, Hashable {
        public var family: String?
        public var parameterSize: String?
        public var quantizationLevel: String?
    }
}

public struct OllamaShowResponse: Sendable, Codable, Hashable {
    public var capabilities: [String]?
    public var modelInfo: [String: JSONValue]?
    public var details: OllamaModelInfo.Details?

    public init(capabilities: [String]?, modelInfo: [String: JSONValue]?, details: OllamaModelInfo.Details?) {
        self.capabilities = capabilities
        self.modelInfo = modelInfo
        self.details = details
    }

    public var supportsThinking: Bool { capabilities?.contains("thinking") ?? false }
}

/// Who speaks in a chat, as Ollama's chat API names them.
public enum OllamaRole: String, Sendable, Codable, Hashable {
    case system, user, assistant
}

public struct OllamaMessage: Sendable, Codable, Hashable {
    public var role: OllamaRole
    public var content: String
    /// Base64-encoded images for vision models.
    public var images: [String]?
    public var thinking: String?

    public init(role: OllamaRole, content: String, images: [String]?) {
        self.role = role
        self.content = content
        self.images = images
        thinking = nil
    }

    public static func system(_ text: String) -> OllamaMessage { OllamaMessage(role: .system, content: text, images: nil) }
    public static func user(_ text: String, images: [String]? = nil) -> OllamaMessage {
        OllamaMessage(role: .user, content: text, images: images)
    }
    public static func assistant(_ text: String) -> OllamaMessage { OllamaMessage(role: .assistant, content: text, images: nil) }
}

public struct OllamaChatRequest: Sendable, Codable, Hashable {
    public var model: String
    public var messages: [OllamaMessage]
    public var format: JSONValue?
    public var options: [String: JSONValue]
    public var keepAlive: String?
    public var think: Bool?
    public var stream: Bool

    public init(model: String, messages: [OllamaMessage], format: JSONValue?, options: [String: JSONValue],
                keepAlive: String?, think: Bool?) {
        self.model = model
        self.messages = messages
        self.format = format
        self.options = options
        self.keepAlive = keepAlive
        self.think = think
        stream = false
    }
}

extension OllamaChatRequest {
    /// Request body with a stable key order (the schema's property order steers the model's output order).
    public var body: JSONValue {
        var entries: [JSONEntry] = [
            JSONEntry("model", .string(model)),
            JSONEntry("messages", .array(messages.map { m in
                var e: [JSONEntry] = [JSONEntry("role", .string(m.role.rawValue)), JSONEntry("content", .string(m.content))]
                if let images = m.images, !images.isEmpty { e.append(JSONEntry("images", .array(images.map(JSONValue.string)))) }
                return .orderedObject(e)
            })),
            JSONEntry("stream", .bool(stream)),
            JSONEntry("options", .object(options)),
        ]
        if let format { entries.append(JSONEntry("format", format)) }
        if let keepAlive { entries.append(JSONEntry("keep_alive", .string(keepAlive))) }
        if let think { entries.append(JSONEntry("think", .bool(think))) }
        return .orderedObject(entries)
    }
}

public struct OllamaChatResponse: Sendable, Codable, Hashable {
    public var model: String
    public var message: OllamaMessage
    public var done: Bool?
    public var doneReason: String?
    public var totalDuration: Int64?
    public var loadDuration: Int64?
    public var promptEvalCount: Int?
    public var promptEvalDuration: Int64?
    public var evalCount: Int?
    public var evalDuration: Int64?

    public init(model: String, message: OllamaMessage, done: Bool?, doneReason: String?, totalDuration: Int64?,
                loadDuration: Int64?, promptEvalCount: Int?, promptEvalDuration: Int64?, evalCount: Int?, evalDuration: Int64?) {
        self.model = model
        self.message = message
        self.done = done
        self.doneReason = doneReason
        self.totalDuration = totalDuration
        self.loadDuration = loadDuration
        self.promptEvalCount = promptEvalCount
        self.promptEvalDuration = promptEvalDuration
        self.evalCount = evalCount
        self.evalDuration = evalDuration
    }

    /// Performance counters in milliseconds, recorded in traces.
    public var metrics: OllamaMetrics {
        OllamaMetrics(totalMs: totalDuration.map { Double($0) / 1e6 }, loadMs: loadDuration.map { Double($0) / 1e6 },
                      promptTokens: promptEvalCount, promptMs: promptEvalDuration.map { Double($0) / 1e6 },
                      outputTokens: evalCount, outputMs: evalDuration.map { Double($0) / 1e6 })
    }
}

public struct OllamaMetrics: Sendable, Codable, Hashable {
    public var totalMs: Double?
    public var loadMs: Double?
    public var promptTokens: Int?
    public var promptMs: Double?
    public var outputTokens: Int?
    public var outputMs: Double?
}

public struct OllamaEmbedRequest: Sendable, Codable, Hashable {
    public var model: String
    public var input: [String]
    public var keepAlive: String?
    public var truncate: Bool
    public var options: [String: JSONValue]?

    public init(model: String, input: [String], keepAlive: String?, truncate: Bool, options: [String: JSONValue]?) {
        self.model = model
        self.input = input
        self.keepAlive = keepAlive
        self.truncate = truncate
        self.options = options
    }
}

public struct OllamaEmbedResponse: Sendable, Codable, Hashable {
    public var model: String?
    public var embeddings: [[Float]]
    public var totalDuration: Int64?
    public var loadDuration: Int64?
    public var promptEvalCount: Int?

    public init(model: String?, embeddings: [[Float]], totalDuration: Int64?, loadDuration: Int64?, promptEvalCount: Int?) {
        self.model = model
        self.embeddings = embeddings
        self.totalDuration = totalDuration
        self.loadDuration = loadDuration
        self.promptEvalCount = promptEvalCount
    }
}

public struct OllamaPullProgress: Sendable, Codable, Hashable {
    /// Absent on error lines, which carry `error` instead.
    public var status: String?
    public var digest: String?
    public var total: Int64?
    public var completed: Int64?
    public var error: String?

    public init(status: String?, digest: String?, total: Int64?, completed: Int64?, error: String?) {
        self.status = status
        self.digest = digest
        self.total = total
        self.completed = completed
        self.error = error
    }

    public var fraction: Double? {
        guard let total, total > 0, let completed else { return nil }
        return Double(completed) / Double(total)
    }
}

/// Abstraction over the Ollama HTTP API so the pipeline can be tested with a mock.
public protocol OllamaAPI: Sendable {
    func version() async throws -> String
    func tags() async throws -> [OllamaModelInfo]
    func show(model: String) async throws -> OllamaShowResponse
    func chat(_ request: OllamaChatRequest) async throws -> OllamaChatResponse
    func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse
    func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error>
}
