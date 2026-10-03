import Foundation
import Synchronization

/// An Ollama server for the tests of the HTTP client (`OllamaClient`): what a test scripts it to answer, sent through a
/// URL protocol (`Transport`) the client's session is given after its guard, so a request takes the client's whole path
/// to the network and no further. Each server answers at a host of its own, so tests that run at once never answer one
/// another, and records what it was sent.
public final class StubOllamaServer: Sendable {
    /// A request as the server received it.
    public struct Request: Sendable {
        public var method: String
        /// The URL's path, such as `/api/chat`.
        public var path: String
        public var body: Data
        /// How long the request may wait for more of its answer (`URLRequest.timeoutInterval`).
        public var timeout: TimeInterval

        /// The body as a JSON object, by its keys.
        public func json() throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
            return object
        }
    }

    /// What the server does with a request to a path.
    public enum Reply: Sendable {
        /// Answers with `status` and `headers`, and a body delivered piece by piece, each piece as one read off the
        /// network: a piece may end inside a line or a character.
        case answer(status: Int, headers: [String: String], pieces: [Data])
        /// Sends the request to `location` with `status`, as a redirect does.
        case redirect(status: Int, location: String)
        /// Never answers, as a server that hangs; the request ends only when it is stopped (`stopped`).
        case stall

        /// A JSON answer, whole.
        public static func json(_ text: String, status: Int = 200) -> Reply {
            .answer(status: status, headers: ["Content-Type": "application/json"], pieces: [Data(text.utf8)])
        }

        /// Lines streamed as Ollama streams them, a JSON object and a line feed each, cut into pieces of `size` bytes.
        public static func lines(_ lines: [String], piecesOf size: Int) -> Reply {
            let body = Array(lines.map { $0 + "\n" }.joined().utf8)
            let pieces = stride(from: 0, to: body.count, by: size).map { Data(body[$0..<min($0 + size, body.count)]) }
            return .answer(status: 200, headers: ["Content-Type": "application/x-ndjson"], pieces: pieces)
        }
    }

    private struct State {
        var replies: [String: Reply] = [:]
        var requests: [Request] = []
        var stopped = 0
    }

    /// Where the server answers: a `.local` name of its own, which no request ever looks up, as `Transport` answers it.
    public let baseURL: URL
    private let host: String
    private let state = Mutex(State())
    private static let servers = Mutex<[String: StubOllamaServer]>([:])
    /// The port Ollama listens on, which the address names as an address of the app's would.
    private static let port = 11434

    public init() throws {
        host = "stub-\(UUID().uuidString.lowercased()).local"
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Self.port
        guard let url = components.url else { throw URLError(.badURL) }
        baseURL = url
        Self.servers.withLock { $0[host] = self }
    }

    /// Answers every request to `path`, such as `/api/chat`, with `reply` from now on. A path given no reply answers 404.
    public func reply(to path: String, with reply: Reply) { state.withLock { $0.replies[path] = reply } }

    /// What the server was sent, in order.
    public var requests: [Request] { state.withLock { $0.requests } }

    /// How many requests the server never answered were stopped, as cancelling their task stops them.
    public var stopped: Int { state.withLock { $0.stopped } }

    fileprivate static func server(for request: URLRequest) -> StubOllamaServer? {
        guard let host = request.url?.host() else { return nil }
        return servers.withLock { $0[host] }
    }

    fileprivate func receive(_ request: Request) -> Reply {
        state.withLock { state in
            state.requests.append(request)
            return state.replies[request.path] ?? .json(#"{"error":"nothing scripted for \#(request.path)"}"#, status: 404)
        }
    }

    fileprivate func stop() { state.withLock { $0.stopped += 1 } }

    /// The URL protocol a client's session is given to reach the stub servers.
    public final class Transport: URLProtocol {
        /// Whether this request was left unanswered, so that stopping it is what ends it.
        private let stalled = Mutex(false)

        override public static func canInit(with request: URLRequest) -> Bool { server(for: request) != nil }
        override public static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override public func startLoading() {
            guard let url = request.url, let server = StubOllamaServer.server(for: request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            let received = Request(method: request.httpMethod ?? "", path: url.path(), body: Self.body(of: request),
                                   timeout: request.timeoutInterval)
            switch server.receive(received) {
            case let .answer(status, headers, pieces):
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for piece in pieces { client?.urlProtocol(self, didLoad: piece) }
                client?.urlProtocolDidFinishLoading(self)
            case let .redirect(status, location):
                guard let target = URL(string: location),
                      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location])
                else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                var next = request
                next.url = target
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                // Refused, the redirect's own response is the answer.
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            case .stall:
                stalled.withLock { $0 = true }
            }
        }

        override public func stopLoading() {
            guard stalled.withLock({ $0 }), let server = StubOllamaServer.server(for: request) else { return }
            server.stop()
        }

        /// The body a request carries, which a session hands a URL protocol as a stream.
        private static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                body.append(buffer, count: read)
            }
            return body
        }
    }
}
