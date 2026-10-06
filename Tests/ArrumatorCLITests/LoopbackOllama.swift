import Darwin
import Foundation
import Synchronization

/// A stand-in for Ollama's HTTP API on the loopback address, for a command run as a process, which no in-process double
/// reaches: it says every model is installed and can answer, and answers every chat as it is told, by default with an
/// empty object, which no reading takes for a valid answer, so a document read with it waits for the user. Nothing
/// leaves this Mac. It listens and answers on threads of its own, never Dispatch's or Swift's shared pools, which the
/// tests that wait on a command hold (`ChildProcess`): an answer queued behind them might never be sent.
final class LoopbackOllama: Sendable {
    private let stopped = Flag()
    private let port: UInt16

    /// Whether the server is to stop, which its listening thread looks at between connections.
    private final class Flag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set() { value.withLock { $0 = true } }
    }

    /// The address of the server, which listens from the moment it is made.
    var address: String? { "http://127.0.0.1:\(port)" }

    /// Settings for a command run against the stand-in (`Home.make(pipeline:)`): its answers are waited for as long as a
    /// loaded machine may take, as a test asks what the command does with them, never how fast the runner is.
    static var patient: [String: Any] { ["ollama": ["timeouts": ["meta": 60, "version": 60, "resolve": 60]]] }

    /// An answer to a chat: a status line's code and text, and a JSON body.
    typealias Answer = (status: String, body: String)

    /// The chat answer no reading takes for a valid one.
    static let emptyAnswer: Answer = ("200 OK", #"{"model":"loopback","message":{"role":"assistant","content":"{}"},"done":true,"done_reason":"stop"}"#)

    /// How long the listening thread waits for a connection before it looks whether it is to stop, in milliseconds.
    private static let stopCheckMilliseconds: Int32 = 100

    /// A server that answers every chat with `chat`, listening on a port of the loopback address the system gives it.
    init(chat: Answer = emptyAnswer) throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var loopback = sockaddr_in()
        loopback.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        loopback.sin_family = sa_family_t(AF_INET)
        loopback.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &loopback) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard bound == 0, listen(socket, SOMAXCONN) == 0, named == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(socket)
            throw failure
        }
        port = UInt16(bigEndian: assigned.sin_port)
        let stopped = stopped
        Thread { Self.accept(on: socket, until: stopped, chat: chat) }.start()
    }

    /// Stops listening: the listening thread closes the socket once it next looks.
    func stop() { stopped.set() }

    /// Takes each connection to `socket` until told to stop, answering it on a thread of its own.
    private static func accept(on socket: Int32, until stopped: Flag, chat: Answer) {
        defer { close(socket) }
        var waiting = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        while !stopped.isSet {
            guard poll(&waiting, 1, stopCheckMilliseconds) > 0 else { continue }
            let connection = Darwin.accept(socket, nil, nil)
            guard connection >= 0 else { continue }
            Thread { serve(connection, chat: chat) }.start()
        }
    }

    /// Reads a request whole, by its headers and its Content-Length, then answers it and closes the connection.
    private static func serve(_ connection: Int32, chat: Answer) {
        defer { close(connection) }
        // A client gone before its answer is written ends the write, not the test process.
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: received[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if received.count - end.upperBound >= length {
                    let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let (status, body) = path == "/api/chat" ? chat : answer(path)
                    send(Data(("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
                        + "Connection: close\r\n\r\n" + body).utf8), to: connection)
                    return
                }
            }
            let count = read(connection, &chunk, chunk.count)
            guard count > 0 else { return }
            received.append(contentsOf: chunk[0..<count])
        }
    }

    /// Writes all of `data` to `connection`, as far as it takes it.
    private static func send(_ data: Data, to connection: Int32) {
        data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = write(connection, start.advanced(by: sent), bytes.count - sent)
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    /// What Ollama answers at `path`, a chat aside, as its API documents it
    /// (https://github.com/ollama/ollama/blob/main/docs/api.md).
    private static func answer(_ path: String) -> Answer {
        switch path {
        case "/api/version": ("200 OK", #"{"version":"0.0.0-loopback"}"#)
        case "/api/tags": ("200 OK", #"{"models":[]}"#)
        case "/api/show": ("200 OK", #"{"capabilities":["completion","vision"]}"#)
        default: ("404 Not Found", #"{"error":"not served here"}"#)
        }
    }
}
