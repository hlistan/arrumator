import Foundation
import Network
import Synchronization

/// A stand-in for Ollama's HTTP API on the loopback address, for a command run as a process, which no in-process double
/// reaches: it says every model is installed and can answer, and answers every chat with an empty object, which no
/// reading takes for a valid answer, so a document read with it waits for the user. Nothing leaves this Mac.
final class LoopbackOllama: Sendable {
    private let listener: NWListener
    private let ready = Port()

    /// The port the server listens on, once it does.
    final class Port: Sendable {
        private let number = Mutex<UInt16?>(nil)
        var value: UInt16? { number.withLock { $0 } }
        func set(_ value: UInt16?) { number.withLock { $0 = value } }
    }

    /// The address of the server, once it listens.
    var address: String? { ready.value.map { "http://127.0.0.1:\($0)" } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.serve(connection, received: Data())
        }
        listener.stateUpdateHandler = { [ready, listener] state in
            if case .ready = state { ready.set(listener.port?.rawValue) }
        }
        listener.start(queue: .global())
    }

    func stop() { listener.cancel() }

    /// Reads a request whole, by its headers and its Content-Length, then answers it and closes the connection.
    private static func serve(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            let all = received + (data ?? Data())
            guard error == nil else { return connection.cancel() }
            guard let end = all.range(of: Data("\r\n\r\n".utf8)) else {
                return done ? connection.cancel() : serve(connection, received: all)
            }
            let head = String(decoding: all[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard all.count - end.upperBound >= length || done else { return serve(connection, received: all) }
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let (status, body) = answer(path)
            let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// What Ollama answers at `path`, as its API documents it (https://github.com/ollama/ollama/blob/main/docs/api.md).
    private static func answer(_ path: String) -> (String, String) {
        switch path {
        case "/api/version": ("200 OK", #"{"version":"0.0.0-loopback"}"#)
        case "/api/tags": ("200 OK", #"{"models":[]}"#)
        case "/api/show": ("200 OK", #"{"capabilities":["completion","vision"]}"#)
        case "/api/chat": ("200 OK", #"{"model":"loopback","message":{"role":"assistant","content":"{}"},"done":true,"done_reason":"stop"}"#)
        default: ("404 Not Found", #"{"error":"not served here"}"#)
        }
    }
}
