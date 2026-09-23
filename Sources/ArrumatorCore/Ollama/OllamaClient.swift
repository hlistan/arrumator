import Foundation

/// URLSession-based Ollama client restricted to loopback hosts.
public struct OllamaClient: OllamaAPI {
    public let baseURL: URL
    private let config: OllamaConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(config: OllamaConfig) throws {
        guard let url = URL(string: config.baseURL), let host = url.host()?.lowercased() else {
            throw OllamaError.invalidBaseURL(config.baseURL)
        }
        let allowed = Set(config.allowedHosts.map { $0.lowercased() })
        guard allowed.contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) else {
            throw OllamaError.nonLocalHost(host)
        }
        NetworkGuardProtocol.configure(allowedHosts: config.allowedHosts)
        baseURL = url
        self.config = config
        session = URLSession(configuration: NetworkGuardProtocol.guardedConfiguration())
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
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

    public func running() async throws -> [OllamaRunningModel] {
        struct R: Decodable { var models: [OllamaRunningModel] }
        let r: R = try await get("api/ps", timeout: config.timeouts.meta)
        return r.models
    }

    public func show(model: String) async throws -> OllamaShowResponse {
        struct Body: Encodable { var model: String }
        return try await post("api/show", body: Body(model: model), timeout: config.timeouts.meta, model: model)
    }

    public func chat(_ request: OllamaChatRequest) async throws -> OllamaChatResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        urlRequest.httpMethod = "POST"
        if config.timeouts.chat > 0 { urlRequest.timeoutInterval = config.timeouts.chat }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = Data(request.body.serialized().utf8)
        return try await send(urlRequest, model: request.model)
    }

    public func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse {
        try await post("api/embed", body: request, timeout: config.timeouts.embed, model: request.model)
    }

    public func unload(model: String) async throws {
        struct Body: Encodable { var model: String; var keepAlive: Int }
        struct R: Decodable { var model: String? }
        let _: R = try await post("api/generate", body: Body(model: model, keepAlive: 0), timeout: config.timeouts.meta,
                                  model: model)
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
        let decoder = decoder
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.check(response, body: "")
                    for try await line in bytes.lines where !line.isEmpty {
                        let progress = try decoder.decode(OllamaPullProgress.self, from: Data(line.utf8))
                        if let error = progress.error { throw OllamaError.http(status: 500, body: error) }
                        continuation.yield(progress)
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
        return try await send(request, model: nil)
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable, timeout: Double, model: String?) async throws -> T {
        let request = try makeRequest(path, method: "POST", body: body, timeout: timeout)
        return try await send(request, model: model)
    }

    private func send<T: Decodable>(_ request: URLRequest, model: String?) async throws -> T {
        let started = Date()
        let path = request.url?.path() ?? ""
        do {
            let (data, response) = try await session.data(for: request)
            let body = String(decoding: data, as: UTF8.self)
            if let http = response as? HTTPURLResponse, http.statusCode == 404, let model, body.contains("not found") {
                throw OllamaError.modelNotFound(model)
            }
            try Self.check(response, body: body)
            Log.debug(.ollama, "HTTP \(request.httpMethod ?? "") \(path)", [
                "model": model ?? "-", "ms": String(format: "%.0f", Date().timeIntervalSince(started) * 1000),
                "bytes": String(data.count),
            ])
            guard !data.isEmpty else { throw OllamaError.emptyResponse }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw OllamaError.decoding("\(path): \(error)")
            }
        } catch {
            let mapped = Self.map(error)
            Log.warning(.ollama, "HTTP \(request.httpMethod ?? "") \(path) failed", [
                "model": model ?? "-", "ms": String(format: "%.0f", Date().timeIntervalSince(started) * 1000),
                "error": mapped.localizedDescription,
            ])
            throw mapped
        }
    }

    private static func check(_ response: URLResponse, body: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw OllamaError.http(status: http.statusCode, body: body) }
    }

    private static func map(_ error: any Error) -> any Error {
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
