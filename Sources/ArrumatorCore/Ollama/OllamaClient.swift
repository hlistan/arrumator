import Foundation

/// URLSession-based Ollama client for one server, which `OllamaEndpoint` has checked is on this Mac or the local
/// network. Its session refuses every other host.
public struct OllamaClient: OllamaAPI {
    public let baseURL: URL
    private let config: OllamaConfig
    private let time: any TimeSource
    private let session: URLSession
    private let encoder: JSONEncoder

    /// Ollama's JSON is snake_case (https://github.com/ollama/ollama/blob/main/docs/api.md).
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public init(config: OllamaConfig, baseURL url: URL, time: any TimeSource) throws {
        guard let host = url.host(percentEncoded: false)?.lowercased(), OllamaEndpoint.isLocal(host: host) else {
            throw OllamaError.nonLocalHost(url.host() ?? url.absoluteString)
        }
        NetworkGuardProtocol.configure(allowedHosts: [host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))])
        baseURL = url
        self.config = config
        self.time = time
        session = URLSession(configuration: NetworkGuardProtocol.guardedConfiguration())
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: Endpoints

    public func version() async throws -> String {
        struct R: Decodable { var version: String }
        let r: R = try await get("api/version", timeout: config.timeouts.version)
        return r.version
    }

    public func tags() async throws -> [OllamaModelInfo] {
        struct R: Decodable { var models: [OllamaModelInfo] }
        let r: R = try await get("api/tags", timeout: config.timeouts.meta)
        return r.models
    }

    /// What Ollama says of `model`. Thinking metadata that cannot be read is logged here, where the model is known, and
    /// the capabilities decide how it is told to think (`OllamaShowResponse.thinkingProblem`).
    public func show(model: String) async throws -> OllamaShowResponse {
        struct Body: Encodable { var model: String }
        let shown: OllamaShowResponse = try await post("api/show", body: Body(model: model), timeout: config.timeouts.meta, model: model)
        if let problem = shown.thinkingProblem {
            Log.warning(.ollama, "How the model can be told to think could not be read; its capabilities decide",
                        ["model": model, "error": problem])
        }
        return shown
    }

    public func chat(_ request: OllamaChatRequest) async throws -> OllamaChatResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        urlRequest.httpMethod = "POST"
        let timeout = request.timeout ?? config.timeouts.chat
        if timeout > 0 { urlRequest.timeoutInterval = timeout }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = Data(request.body.serialized().utf8)
        return try await send(urlRequest, model: request.model, timeout: timeout)
    }

    public func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse {
        try await post("api/embed", body: request, timeout: config.timeouts.embed, model: request.model)
    }

    public func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> {
        struct Body: Encodable { var model: String; var stream: Bool }
        let request: URLRequest
        do {
            request = try makeRequest("api/pull", method: "POST", body: Body(model: model, stream: true),
                                      timeout: config.timeouts.pull)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let failure = Self.failure(response, body: "", model: model) { throw failure }
                    for try await line in bytes.lines where !line.isEmpty {
                        continuation.yield(try Self.progress(line, model: model))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Transport

    private func makeRequest(_ path: String, method: String, body: (some Encodable)?, timeout: Double) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if timeout > 0 { request.timeoutInterval = timeout }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    private func get<T: Decodable>(_ path: String, timeout: Double) async throws -> T {
        let request = try makeRequest(path, method: "GET", body: Optional<String>.none, timeout: timeout)
        return try await send(request, model: nil, timeout: timeout)
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable, timeout: Double, model: String?) async throws -> T {
        let request = try makeRequest(path, method: "POST", body: body, timeout: timeout)
        return try await send(request, model: model, timeout: timeout)
    }

    /// - timeout: the configured seconds, which bound the whole exchange as well as its idle time; 0 is none.
    private func send<T: Decodable>(_ request: URLRequest, model: String?, timeout: Double) async throws -> T {
        let started = time.now()
        let path = request.url?.path() ?? ""
        do {
            let session = session
            let (data, response) = try await Deadline.run(timeout, time: time, expired: { OllamaError.timeout(path) }) {
                try await session.data(for: request)
            }
            let body = String(decoding: data, as: UTF8.self)
            if let failure = Self.failure(response, body: body, model: model) { throw failure }
            Log.debug(.ollama, "HTTP \(request.httpMethod ?? "") \(path)", [
                "model": model ?? "-", "ms": String(format: "%.0f", started.milliseconds(until: time.now())),
                "bytes": String(data.count),
            ])
            guard !data.isEmpty else { throw OllamaError.emptyResponse }
            do {
                return try Self.decoder.decode(T.self, from: data)
            } catch {
                throw OllamaError.decoding("\(path): \(error)")
            }
        } catch {
            let mapped = Self.map(error)
            Log.warning(.ollama, "HTTP \(request.httpMethod ?? "") \(path) failed", [
                "model": model ?? "-", "ms": String(format: "%.0f", started.milliseconds(until: time.now())),
                "error": mapped.localizedDescription,
            ])
            throw mapped
        }
    }

    /// HTTP statuses of success, and the one Ollama answers a model it does not have with.
    static let successStatuses = 200..<300
    static let notFoundStatus = 404
    /// What Ollama's error body says of a model it does not have.
    static let notFoundMessage = "not found"

    /// The error an HTTP response stands for, or nil when it succeeded: a model Ollama does not have is `modelNotFound`,
    /// any other failure `http` with its status and body.
    static func failure(_ response: URLResponse, body: String, model: String?) -> OllamaError? {
        guard let http = response as? HTTPURLResponse, !successStatuses.contains(http.statusCode) else { return nil }
        if http.statusCode == notFoundStatus, let model, body.contains(notFoundMessage) { return .modelNotFound(model) }
        return .http(status: http.statusCode, body: body)
    }

    /// One line of a download's progress; a line that reports an error ends the download with it.
    static func progress(_ line: String, model: String) throws -> OllamaPullProgress {
        let progress = try decoder.decode(OllamaPullProgress.self, from: Data(line.utf8))
        if let error = progress.error { throw OllamaError.pullFailed(model: model, message: error) }
        return progress
    }

    static func map(_ error: any Error) -> any Error {
        if error is OllamaError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return OllamaError.timeout(urlError.failingURL?.path() ?? "request")
            case .cancelled: return CancellationError()
            default: return OllamaError.unreachable(urlError.localizedDescription)
            }
        }
        return error
    }
}
