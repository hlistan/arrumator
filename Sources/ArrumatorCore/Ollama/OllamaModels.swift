import Foundation

public enum OllamaError: Error, LocalizedError, Equatable {
    /// The address cannot be used for this `Problem`; the address itself is never repeated, as it may hold a password.
    case invalidAddress(OllamaEndpoint.Problem)
    /// The address the app was to talk to cannot be used, for `reason`: it says where the address came from and how to
    /// give another, as nothing can start without one.
    case unusableAddress(OllamaEndpoint.Source, reason: String)
    case nonLocalHost(String)
    /// The `.local` name `host` also stands for addresses beyond the local network (`beyond`), which a request to the name
    /// may go to, as one of a machine with a global IPv6 address does: the server is given by its address on the local
    /// network instead, as `instead` writes it when one was found.
    case nameReachesBeyond(host: String, beyond: [String], instead: String?)
    case unreachable(String)
    case http(status: Int, body: String)
    /// Ollama answered `endpoint` by sending the request elsewhere, which the app never follows: it talks to the one
    /// server it was pointed at.
    case redirected(endpoint: String, location: String?)
    /// Ollama's answer to `endpoint` held more than `limit` bytes (`ollama.maxResponseBytes`).
    case responseTooLarge(endpoint: String, limit: Int)
    case modelNotFound(String)
    case decoding(String)
    case timeout(String)
    case emptyResponse
    /// Ollama reported a failure while downloading a model, in the progress it streams.
    case pullFailed(model: String, message: String)
    /// Ollama reported a failure part way through an answer it streams.
    case answerFailed(model: String, message: String)
    /// Ollama runs `model` at `host`, beyond this Mac and the local network, so it is never asked anything.
    case runsElsewhere(model: String, host: String)
    /// Where Ollama runs `model` could not be told, for `because`, so it is sent nothing; it waits, as for Ollama being
    /// away, when that failure would.
    indirect case locationUnknown(model: String, because: OllamaError)

    public var errorDescription: String? {
        switch self {
        case let .invalidAddress(problem):
            "An Ollama address names a scheme, http or https, a host, a port and a path alone, and this one cannot be used: \(problem.rawValue)"
        case let .unusableAddress(.settings(file), reason):
            "The Ollama address saved as ollamaURL in \(file.path) cannot be used. \(reason). Give one on this Mac or the local network "
                + "with `arrumatorcli settings --ollama-url <address>`, such as \(OllamaEndpoint.example), or change ollamaURL in that file"
        case let .unusableAddress(.environment, reason):
            "The Ollama address \(RuntimeEnvironment.ollamaURLVariable) gives cannot be used. \(reason). Unset the variable, or set it "
                + "to an address on this Mac or the local network, such as \(OllamaEndpoint.example)"
        case let .nonLocalHost(h): "Refusing to contact non-local host \(h): recognition must stay on this Mac"
        case let .nameReachesBeyond(host, beyond, instead):
            "\(host) also stands for \(beyond.joined(separator: ", ")), beyond the local network, where a request to the name may go: "
                + "give the server by its address on the local network instead" + (instead.map { ", \($0)" } ?? ", its IPv4 address")
        case let .unreachable(m): "Ollama is not reachable: \(m)"
        case let .http(status, body): "Ollama HTTP \(status): \(body.prefix(300))"
        case let .redirected(endpoint, location):
            "Ollama sent \(endpoint) to \(location ?? "another address"), which is not followed: the app talks to the server it was pointed at alone"
        case let .responseTooLarge(endpoint, limit): "Ollama's answer to \(endpoint) is larger than \(limit) bytes (ollama.maxResponseBytes)"
        case let .modelNotFound(m): "Model \(m) is not installed in Ollama"
        case let .decoding(m): "Unexpected Ollama response: \(m)"
        case let .timeout(what): "Ollama timed out: \(what)"
        case .emptyResponse: "Ollama returned an empty response"
        case let .pullFailed(model, message): "Downloading \(model) failed: \(message)"
        case let .answerFailed(model, message): "\(model) stopped answering: \(message)"
        case let .runsElsewhere(model, host):
            "\(model) runs at \(host), beyond this Mac and the local network, so nothing is read with it: choose a model Ollama runs itself"
        case let .locationUnknown(model, because):
            "Where Ollama runs \(model) cannot be told, so nothing is sent to it: \(because.localizedDescription)"
        }
    }

    /// Transient failures worth retrying with backoff.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .timeout, .emptyResponse: true
        case let .http(status, _): status >= 500
        case let .locationUnknown(_, because): because.isTransient
        default: false
        }
    }

    /// Whether the server could not be reached: work waits for it, however long, spending nothing of its own. A server
    /// that answers with a failure, `http` 5xx or an empty reply, is transient too, worth asking again at once, but one
    /// that keeps failing so for one item fails that item (`IngestCoordinator`); so does an answer that keeps timing out
    /// while the server answers a probe (`timedOut`).
    public var isAway: Bool {
        switch self {
        case .unreachable: true
        case let .locationUnknown(_, because): because.isAway
        default: false
        }
    }

    /// Whether the server did not answer in time, which is the server away only when it answers nothing else either.
    public var timedOut: Bool {
        switch self {
        case .timeout: true
        case let .locationUnknown(_, because): because.timedOut
        default: false
        }
    }

    /// Whether asking `request` again may get the answer this failure kept from coming: a transient failure, except a
    /// timeout of a request with a `timeout` of its own, such as a search task's effort gives. That request took longer
    /// than it may and would take as long again, holding the one model that generates all the while, so it is a failed
    /// answer rather than a server that is away.
    public func isTransient(asking request: OllamaChatRequest) -> Bool {
        if case .timeout = self, request.timeout != nil { return false }
        return isTransient
    }
}

/// A model Ollama lists (`/api/tags`).
public struct OllamaModelInfo: Sendable, Codable, Hashable {
    public var name: String
    public var model: String?
    /// The model the server sends a request for this one to, and where, when it runs it elsewhere: a model of Ollama's
    /// cloud pulled as a stub, or one created from it (`remote_model` and `remote_host` of `ListModelResponse` in
    /// Ollama's api/types.go; its chat handler forwards to the host, server/routes.go, Ollama 0.18.2).
    public var remoteModel: String?
    public var remoteHost: String?
    public var size: Int64?
    public var digest: String?
    public var modifiedAt: String?
    public var details: Details?

    public init(name: String, model: String?, remoteModel: String?, remoteHost: String?, size: Int64?, digest: String?,
                modifiedAt: String?, details: Details?) {
        self.name = name
        self.model = model
        self.remoteModel = remoteModel
        self.remoteHost = remoteHost
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

/// How a chat request tells a model to think, as Ollama's `think` takes it
/// (https://docs.ollama.com/capabilities/thinking): switched off or on, or at a level the model names in `/api/show`
/// (`OllamaShowResponse.Thinking.values`), such as gpt-oss's "low", "medium" and "high". Coded as that one JSON value: a
/// bool for a switch, a string for a level. A level without a name tells a model nothing, so it is refused wherever a
/// value is read: `pipeline.json` that asks for one stops the load, and Ollama's `thinking` metadata that lists one is
/// read as none (`OllamaShowResponse.init(from:)`).
public enum OllamaThink: Sendable, Codable, Hashable {
    case off
    case on
    case level(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let on = try? container.decode(Bool.self) {
            self = on ? .on : .off
        } else if let name = try? container.decode(String.self) {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "think names no level: give true, false or a level's name")
            }
            self = .level(name)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "think is true, false or the name of a level")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .off: try container.encode(false)
        case .on: try container.encode(true)
        case let .level(name): try container.encode(name)
        }
    }

    /// The value as a request's body carries it.
    public var json: JSONValue {
        switch self {
        case .off: .bool(false)
        case .on: .bool(true)
        case let .level(name): .string(name)
        }
    }
}

extension OllamaThink: ExpressibleByBooleanLiteral, ExpressibleByStringLiteral {
    public init(booleanLiteral value: Bool) { self = value ? .on : .off }
    public init(stringLiteral value: String) { self = .level(value) }
}

/// What Ollama's `/api/show` says of a model: what it can do (`capabilities`), what it is (`details`, `modelInfo`), and
/// how it can be told to think (`thinking`).
public struct OllamaShowResponse: Sendable, Codable, Hashable {
    public var capabilities: [String]?
    public var modelInfo: [String: JSONValue]?
    public var details: OllamaModelInfo.Details?
    /// Absent from older servers and from models without the metadata, and nil too when it cannot be read
    /// (`thinkingProblem`).
    public var thinking: Thinking?
    /// Where the server sends a request for the model, when it runs it elsewhere, as `OllamaModelInfo.remoteHost`
    /// (`ShowResponse` in Ollama's api/types.go).
    public var remoteModel: String?
    public var remoteHost: String?
    /// Why the `thinking` object could not be read, when it could not, for whoever asked Ollama to log with the model's
    /// name, which the answer does not carry (`OllamaClient.show(model:)`). Never coded.
    var thinkingProblem: String?

    public init(capabilities: [String]?, modelInfo: [String: JSONValue]?, details: OllamaModelInfo.Details?, thinking: Thinking?,
                remoteModel: String?, remoteHost: String?) {
        self.capabilities = capabilities
        self.modelInfo = modelInfo
        self.details = details
        self.thinking = thinking
        self.remoteModel = remoteModel
        self.remoteHost = remoteHost
    }

    private enum CodingKeys: String, CodingKey {
        case capabilities, modelInfo, details, thinking, remoteModel, remoteHost
    }

    /// Reads the answer as Ollama gives it. The `thinking` object is optional metadata, so one the app cannot act on, such
    /// as a value that is neither a switch nor a level's name, is read as none and the capabilities decide, as on an older
    /// server, rather than leaving the model unlisted and unused; `OllamaThink` itself stays strict where the app's own
    /// configuration is read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
        modelInfo = try container.decodeIfPresent([String: JSONValue].self, forKey: .modelInfo)
        details = try container.decodeIfPresent(OllamaModelInfo.Details.self, forKey: .details)
        remoteModel = try container.decodeIfPresent(String.self, forKey: .remoteModel)
        remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost)
        do {
            thinking = try container.decodeIfPresent(Thinking.self, forKey: .thinking)
        } catch {
            thinking = nil
            thinkingProblem = String(describing: error)
        }
    }

    /// The values `think` may take for a model, and the one it thinks at when not told.
    public struct Thinking: Sendable, Codable, Hashable {
        /// Switches (`true`, `false`) and levels the model names; `[false]` alone says it cannot think.
        public var values: [OllamaThink]?
        /// How the model thinks when a request does not say.
        public var `default`: OllamaThink?

        public init(values: [OllamaThink]?, default: OllamaThink?) {
            self.values = values
            self.default = `default`
        }
    }

    /// The capabilities Ollama lists for a model that generates text, that sees images, that embeds and that can think.
    public static let completionCapability = "completion"
    public static let visionCapability = "vision"
    public static let embeddingCapability = "embedding"
    public static let thinkingCapability = "thinking"

    /// The values `think` takes for this model, as its `/api/show` says: those it lists, none when it lists only `false`,
    /// which says it cannot think. A model that lists none (an older server, a model without the metadata, or an empty
    /// list, which Ollama leaves out) takes the switches, `true` and `false`, when its capabilities say it can think, and
    /// none otherwise.
    public var thinkingValues: [OllamaThink] {
        if let values = thinking?.values, !values.isEmpty { return values == [.off] ? [] : values }
        return capabilities?.contains(Self.thinkingCapability) == true ? [.on, .off] : []
    }

    /// What a request that wants `wanted` tells this model (`think`), as its `/api/show` allows (`thinkingValues`); nil
    /// sends nothing, so the model thinks as it does by default: the wanted value when the model takes it, else on for a
    /// wanted level when it takes `true`, else nothing.
    public func think(sending wanted: OllamaThink) -> OllamaThink? {
        let values = thinkingValues
        if values.contains(wanted) { return wanted }
        if case .level = wanted, values.contains(.on) { return .on }
        return nil
    }
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
    /// What the model is told about thinking; nil leaves `think` out, so it thinks as it does by default.
    public var think: OllamaThink?
    public var stream: Bool
    /// Seconds the answer may take, in place of `ollama.timeouts.chat`; nil for that. Not sent: the client waits.
    public var timeout: Double?

    public init(model: String, messages: [OllamaMessage], format: JSONValue?, options: [String: JSONValue],
                keepAlive: String?, think: OllamaThink?, timeout: Double?) {
        self.model = model
        self.messages = messages
        self.format = format
        self.options = options
        self.keepAlive = keepAlive
        self.think = think
        self.timeout = timeout
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
        if let think { entries.append(JSONEntry("think", think.json)) }
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

    /// The answer so far with `chunk`, the next line Ollama streams of it, added: its words and thinking follow on, and
    /// the line that ends the answer brings why it ended and the counters.
    public func continued(by chunk: OllamaChatResponse) -> OllamaChatResponse {
        var next = self
        next.model = chunk.model
        next.message.content += chunk.message.content
        if let thinking = chunk.message.thinking { next.message.thinking = (message.thinking ?? "") + thinking }
        guard chunk.done == true else { return next }
        next.done = true
        next.doneReason = chunk.doneReason
        next.totalDuration = chunk.totalDuration
        next.loadDuration = chunk.loadDuration
        next.promptEvalCount = chunk.promptEvalCount
        next.promptEvalDuration = chunk.promptEvalDuration
        next.evalCount = chunk.evalCount
        next.evalDuration = chunk.evalDuration
        return next
    }

    /// Whether the answer stopped at its length limit (`num_predict`) rather than because it was complete: thinking
    /// counts toward the limit, so a model that thinks long can stop before it has written any of the answer.
    public var reachedLengthLimit: Bool { doneReason == Self.lengthReason }

    /// The `done_reason` Ollama gives an answer cut off at `num_predict`.
    public static let lengthReason = "length"

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
    /// The server this asks now: what is learnt of a model, such as what it can do, is learnt of it there
    /// (`ModelManager.capabilities(of:)`).
    var baseURL: URL { get }
    func version() async throws -> String
    func tags() async throws -> [OllamaModelInfo]
    func show(model: String) async throws -> OllamaShowResponse
    /// The model's answer to `request`. With `partial`, Ollama streams it, and `partial` is given the answer so far each
    /// time it grows, until it is complete (`OllamaChatResponse.continued(by:)`); without, it comes whole.
    func chat(_ request: OllamaChatRequest, partial: (@Sendable (OllamaChatResponse) async -> Void)?) async throws -> OllamaChatResponse
    func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse
    func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error>
}

extension OllamaAPI {
    /// The model's whole answer to `request`, not streamed.
    public func chat(_ request: OllamaChatRequest) async throws -> OllamaChatResponse { try await chat(request, partial: nil) }
}
