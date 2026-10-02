import Foundation

/// URLSession-based Ollama client for one server, which `OllamaEndpoint` has checked is on this Mac or the local
/// network. Its session refuses every other host, every proxy and every redirect (`NetworkGuardProtocol`), and it sends
/// a request to a model only once it knows the server runs that model itself (`refuseRemote`).
public struct OllamaClient: OllamaAPI {
    public let baseURL: URL
    private let config: OllamaConfig
    private let time: any TimeSource
    private let session: URLSession
    /// The one host this client's requests may reach, in the form the guard compares (`OllamaEndpoint.host(of:)`).
    private let host: String
    private let encoder: JSONEncoder
    /// Where this client's server runs each model it has described or listed lately.
    private let locations: ModelLocations

    /// Ollama's API, by path and method (https://github.com/ollama/ollama/blob/main/docs/api.md).
    enum Endpoint: String, Sendable {
        case version = "api/version"
        case tags = "api/tags"
        case show = "api/show"
        case chat = "api/chat"
        case embed = "api/embed"
        case pull = "api/pull"

        var method: String {
            switch self {
            case .version, .tags: Self.get
            case .show, .chat, .embed, .pull: Self.post
            }
        }

        static let get = "GET"
        static let post = "POST"
    }

    /// The header and type of a request's JSON body.
    static let contentTypeHeader = "Content-Type"
    static let jsonContentType = "application/json"

    /// The idle time of a request whose timeout is 0, none. URLRequest's `timeoutInterval` bounds how long a request
    /// may wait for more data, 60 seconds unless set; a request's own value overrides the session's; and an infinite
    /// one never runs out. Seen with a server that accepts and never answers: unset, a request timed out after 60
    /// seconds; set to infinity, it was still waiting after 75.
    static let noIdleTimeout = TimeInterval.infinity

    /// Ollama's JSON is snake_case (https://github.com/ollama/ollama/blob/main/docs/api.md).
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public init(config: OllamaConfig, baseURL url: URL, time: any TimeSource) throws {
        try self.init(config: config, baseURL: url, time: time, transport: [])
    }

    /// A client whose requests pass through `transport` after the guard: what a test puts there, such as a stub server,
    /// answers them. The app never passes any.
    init(config: OllamaConfig, baseURL url: URL, time: any TimeSource, transport: [URLProtocol.Type]) throws {
        host = try OllamaEndpoint.localHost(of: url)
        baseURL = url
        self.config = config
        self.time = time
        session = NetworkGuardProtocol.session(transport: transport)
        locations = ModelLocations(time: time, maxAge: config.modelLocationMaxAge)
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: Endpoints

    public func version() async throws -> String {
        struct R: Decodable { var version: String }
        let r: R = try await send(.version, body: Optional<String>.none, timeout: config.timeouts.version, model: nil)
        return r.version
    }

    public func tags() async throws -> [OllamaModelInfo] {
        struct R: Decodable { var models: [OllamaModelInfo] }
        let r: R = try await send(.tags, body: Optional<String>.none, timeout: config.timeouts.meta, model: nil)
        // A model the listing says runs elsewhere is sent nothing from now on, whatever was said of it before.
        for model in r.models {
            if let host = ModelLocation.remoteHost(of: model.name, said: model.remoteHost) { locations.remember(model.name, runsAt: host) }
        }
        return r.models
    }

    /// What Ollama says of `model`. Thinking metadata that cannot be read is logged here, where the model is known, and
    /// the capabilities decide how it is told to think (`OllamaShowResponse.thinkingProblem`).
    public func show(model: String) async throws -> OllamaShowResponse {
        struct Body: Encodable { var model: String }
        let shown: OllamaShowResponse = try await send(.show, body: Body(model: model), timeout: config.timeouts.meta, model: model)
        locations.remember(model, runsAt: ModelLocation.remoteHost(of: model, said: shown.remoteHost))
        if let problem = shown.thinkingProblem {
            Log.warning(.ollama, "How the model can be told to think could not be read; its capabilities decide",
                        ["model": model, "error": problem])
        }
        return shown
    }

    public func chat(_ request: OllamaChatRequest, partial: (@Sendable (OllamaChatResponse) async -> Void)?) async throws -> OllamaChatResponse {
        try await refuseRemote(request.model)
        var asked = request
        asked.stream = partial != nil
        let timeout = request.timeout ?? config.timeouts.chat
        let urlRequest = makeRequest(.chat, body: Data(asked.body.serialized().utf8), timeout: timeout)
        guard let partial else { return try await send(urlRequest, endpoint: .chat, model: request.model, timeout: timeout) }
        return try await stream(urlRequest, model: request.model, timeout: timeout, partial: partial)
    }

    public func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse {
        try await refuseRemote(request.model)
        return try await send(.embed, body: request, timeout: config.timeouts.embed, model: request.model)
    }

    /// Refuses `model` unless this client's server runs it itself, as every request that carries document text must be
    /// (`ModelLocation`): by its name, before the server is asked anything, then as the server last described or listed
    /// it within `ollama.modelLocationMaxAge`, asked again past that age and after a download; the check and the
    /// request go to this one client and so to one server. A model
    /// whose place cannot be told is sent nothing (`OllamaError.locationUnknown`), and waits as for Ollama being away
    /// when the description failed so; one the server does not have is that, as its request would be answered.
    func refuseRemote(_ model: String) async throws {
        if ModelLocation.namesCloud(model) { throw OllamaError.runsElsewhere(model: model, host: ModelLocation.cloudPlace) }
        let host: String?
        if let known = locations.location(of: model) {
            host = known
        } else {
            do {
                host = ModelLocation.remoteHost(of: model, said: try await show(model: model).remoteHost)
            } catch let error as OllamaError {
                if case .modelNotFound = error { throw error }
                throw OllamaError.locationUnknown(model: model, because: error)
            }
        }
        if let host { throw OllamaError.runsElsewhere(model: model, host: host) }
    }

    /// A model's download, as Ollama streams its progress. It takes as long as it takes: `ollama.timeouts.pull` bounds
    /// only how long it may wait for the next line.
    public func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> {
        struct Body: Encodable { var model: String; var stream: Bool }
        let request: URLRequest
        do {
            request = makeRequest(.pull, body: try encoder.encode(Body(model: model, stream: true)), timeout: config.timeouts.pull)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let session = session
        let limit = config.maxResponseBytes
        let locations = locations
        // A download can make a model one the server runs elsewhere, or itself: it is described again after one.
        locations.forget(model)
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { locations.forget(model) }
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    try await Self.refuseFailure(response, bytes, endpoint: .pull, model: model, limit: limit)
                    // A download streams for as long as it takes, so each line is bounded rather than all of them.
                    for try await line in OllamaLines(bytes, endpoint: .pull, lineLimit: limit, totalLimit: nil) {
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

    /// A request to `endpoint` with `body`, which only `host` may receive.
    private func makeRequest(_ endpoint: Endpoint, body: Data?, timeout: Double) -> URLRequest {
        let request = NSMutableURLRequest(url: baseURL.appendingPathComponent(endpoint.rawValue))
        request.httpMethod = endpoint.method
        request.timeoutInterval = timeout > 0 ? timeout : Self.noIdleTimeout
        if let body {
            request.setValue(Self.jsonContentType, forHTTPHeaderField: Self.contentTypeHeader)
            request.httpBody = body
        }
        NetworkGuardProtocol.allow(request, host: host)
        return request as URLRequest
    }

    private func send<T: Decodable>(_ endpoint: Endpoint, body: (some Encodable)?, timeout: Double, model: String?) async throws -> T {
        let request = makeRequest(endpoint, body: try body.map { try encoder.encode($0) }, timeout: timeout)
        return try await send(request, endpoint: endpoint, model: model, timeout: timeout)
    }

    /// Sends `request` and decodes the whole of its answer, at most `ollama.maxResponseBytes`.
    /// - timeout: the configured seconds, which bound the whole exchange as well as its idle time; 0 is none.
    private func send<T: Decodable>(_ request: URLRequest, endpoint: Endpoint, model: String?, timeout: Double) async throws -> T {
        let started = time.now()
        do {
            let session = session
            let limit = config.maxResponseBytes
            let (data, response) = try await Deadline.run(timeout, time: time, expired: { OllamaError.timeout(endpoint.rawValue) }) {
                let (bytes, response) = try await session.bytes(for: request)
                return (try await Self.body(bytes, endpoint: endpoint, limit: limit), response)
            }
            if let failure = Self.failure(response, body: String(decoding: data, as: UTF8.self), endpoint: endpoint, model: model) {
                throw failure
            }
            Log.debug(.ollama, "Ollama answered", [
                "endpoint": endpoint.rawValue, "model": model ?? "-", "ms": String(format: "%.0f", started.milliseconds(until: time.now())),
                "bytes": String(data.count),
            ])
            guard !data.isEmpty else { throw OllamaError.emptyResponse }
            do {
                return try Self.decoder.decode(T.self, from: data)
            } catch {
                throw OllamaError.decoding("\(endpoint.rawValue): \(error)")
            }
        } catch {
            let mapped = Self.map(error)
            Log.warning(.ollama, "A request to Ollama failed", [
                "endpoint": endpoint.rawValue, "model": model ?? "-", "ms": String(format: "%.0f", started.milliseconds(until: time.now())),
                "error": mapped.localizedDescription,
            ])
            throw mapped
        }
    }

    /// Reads an answer Ollama streams, a JSON object per line (https://github.com/ollama/ollama/blob/main/docs/api.md),
    /// giving `partial` the answer so far after each line. `timeout` bounds the whole answer, as it bounds one that is
    /// not streamed; an answer that ends before its last line is no answer.
    private func stream(_ request: URLRequest, model: String, timeout: Double,
                        partial: @escaping @Sendable (OllamaChatResponse) async -> Void) async throws -> OllamaChatResponse {
        let started = time.now()
        do {
            let session = session
            let limit = config.maxResponseBytes
            let answer = try await Deadline.run(timeout, time: time, expired: { OllamaError.timeout(Endpoint.chat.rawValue) }) {
                let (bytes, response) = try await session.bytes(for: request)
                try await Self.refuseFailure(response, bytes, endpoint: .chat, model: model, limit: limit)
                var answer: OllamaChatResponse?
                for try await line in OllamaLines(bytes, endpoint: .chat, lineLimit: limit, totalLimit: limit) {
                    let chunk = try Self.chatChunk(line, model: model)
                    let sofar = answer.map { $0.continued(by: chunk) } ?? chunk
                    answer = sofar
                    await partial(sofar)
                }
                guard let answer, answer.done == true else { throw OllamaError.emptyResponse }
                return answer
            }
            Log.debug(.ollama, "Ollama streamed an answer", [
                "endpoint": Endpoint.chat.rawValue, "model": model, "ms": String(format: "%.0f", started.milliseconds(until: time.now())),
                "chars": String(answer.message.content.count),
            ])
            return answer
        } catch {
            let mapped = Self.map(error)
            Log.warning(.ollama, "A request to Ollama failed", [
                "endpoint": Endpoint.chat.rawValue, "model": model, "ms": String(format: "%.0f", started.milliseconds(until: time.now())),
                "error": mapped.localizedDescription,
            ])
            throw mapped
        }
    }

    /// Throws the error `response` stands for, reading its body for it, unless it succeeded; a streamed answer that
    /// succeeded is then read line by line.
    private static func refuseFailure(_ response: URLResponse, _ bytes: URLSession.AsyncBytes, endpoint: Endpoint, model: String?,
                                      limit: Int) async throws {
        guard let http = response as? HTTPURLResponse, !successStatuses.contains(http.statusCode) else { return }
        let said = String(decoding: try await body(bytes, endpoint: endpoint, limit: limit), as: UTF8.self)
        throw failure(response, body: said, endpoint: endpoint, model: model) ?? OllamaError.http(status: http.statusCode, body: said)
    }

    /// The whole body of an answer, refused once it holds more than `limit` bytes.
    static func body(_ bytes: some AsyncSequence<UInt8, any Error>, endpoint: Endpoint, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw OllamaError.responseTooLarge(endpoint: endpoint.rawValue, limit: limit) }
            data.append(byte)
        }
        return data
    }

    /// HTTP statuses of success, of a redirect, and the one Ollama answers a model it does not have with.
    static let successStatuses = 200..<300
    static let redirectStatuses = 300..<400
    static let notFoundStatus = 404
    /// The header a redirect names where it sends the request.
    static let locationHeader = "Location"
    /// What Ollama's error body says of a model it does not have.
    static let notFoundMessage = "not found"

    /// The error an HTTP response stands for, or nil when it succeeded: a redirect, which the session refused to follow,
    /// is `redirected`, a model Ollama does not have `modelNotFound`, any other failure `http` with its status and body.
    static func failure(_ response: URLResponse, body: String, endpoint: Endpoint, model: String?) -> OllamaError? {
        guard let http = response as? HTTPURLResponse, !successStatuses.contains(http.statusCode) else { return nil }
        if redirectStatuses.contains(http.statusCode) {
            return .redirected(endpoint: endpoint.rawValue, location: http.value(forHTTPHeaderField: locationHeader))
        }
        if http.statusCode == notFoundStatus, let model, body.contains(notFoundMessage) { return .modelNotFound(model) }
        return .http(status: http.statusCode, body: body)
    }

    /// One line of a streamed answer; a line that reports an error ends the answer with it.
    static func chatChunk(_ line: Data, model: String) throws -> OllamaChatResponse {
        struct Failure: Decodable { var error: String }
        if let failure = try? decoder.decode(Failure.self, from: line) { throw OllamaError.answerFailed(model: model, message: failure.error) }
        do {
            return try decoder.decode(OllamaChatResponse.self, from: line)
        } catch {
            throw OllamaError.decoding("\(Endpoint.chat.rawValue): \(error)")
        }
    }

    /// One line of a download's progress; a line that reports an error ends the download with it.
    static func progress(_ line: Data, model: String) throws -> OllamaPullProgress {
        let progress = try decoder.decode(OllamaPullProgress.self, from: line)
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

/// The lines of an answer Ollama streams, each a JSON object, framed on the line feed alone: JSON never holds a raw
/// line feed within a value, and Ollama ends each object with one. `AsyncLineSequence` (`bytes.lines`) also ends a line
/// at a carriage return, U+0085, U+2028 and U+2029, which a model's words can hold, and would cut an object in two. A
/// line is bytes until it is whole, so a character split between two reads is decoded whole. One line may hold at most
/// `lineLimit` bytes and all of them `totalLimit`, when there is one; past either, the answer is refused.
struct OllamaLines<Base: AsyncSequence<UInt8, any Error>>: AsyncSequence {
    typealias Element = Data

    let base: Base
    let endpoint: OllamaClient.Endpoint
    let lineLimit: Int
    let totalLimit: Int?

    init(_ base: Base, endpoint: OllamaClient.Endpoint, lineLimit: Int, totalLimit: Int?) {
        self.base = base
        self.endpoint = endpoint
        self.lineLimit = lineLimit
        self.totalLimit = totalLimit
    }

    static var lineFeed: UInt8 { UInt8(ascii: "\n") }

    struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: Base.AsyncIterator
        let endpoint: OllamaClient.Endpoint
        let lineLimit: Int
        let totalLimit: Int?
        var total = 0

        mutating func next() async throws -> Data? {
            var line = Data()
            while let byte = try await bytes.next() {
                total += 1
                if let totalLimit, total > totalLimit { throw OllamaError.responseTooLarge(endpoint: endpoint.rawValue, limit: totalLimit) }
                if byte == OllamaLines.lineFeed {
                    if line.isEmpty { continue }
                    return line
                }
                guard line.count < lineLimit else { throw OllamaError.responseTooLarge(endpoint: endpoint.rawValue, limit: lineLimit) }
                line.append(byte)
            }
            return line.isEmpty ? nil : line
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: base.makeAsyncIterator(), endpoint: endpoint, lineLimit: lineLimit, totalLimit: totalLimit)
    }
}
