import Darwin
import Foundation
import Synchronization

/// A stand-in for Ollama's HTTP API on the loopback address, for a command run as a process, or a runtime whose
/// connection is made from its settings, which no in-process double reaches: it says every model is installed and can
/// answer, and answers every chat as it is told, by default with an empty object, which no reading takes for a valid
/// answer, so a document read with it waits for the user. Nothing leaves this Mac. It listens and answers on threads of
/// its own, never Dispatch's or Swift's shared pools, which the tests that wait on a command hold (`ChildProcess`): an
/// answer queued behind them might never be sent.
public final class LoopbackOllama: Sendable {
    private let stopped = Flag()
    /// Whether a chat is held unanswered, as a model still writing its answer (`holdChats(_:)`).
    private let holding = Hold()
    private let chats = Count()
    /// The address of the server, which listens from the moment it is made.
    public let address: String

    /// Whether the server is to stop, which its listening thread looks at between connections.
    private final class Flag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set() { value.withLock { $0 = true } }
    }

    /// Whether chats are held, which a thread with a chat in hand waits on until they are answered again or the server
    /// stops.
    private final class Hold: Sendable {
        private let condition = NSCondition()
        private let state = Mutex((held: false, ended: false))

        func set(held: Bool) { change { $0.held = held } }
        func end() { change { $0.ended = true } }

        /// Waits while chats are held and the server runs: whether a chat is to be answered.
        func waitWhileHeld() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            while true {
                let now = state.withLock { $0 }
                if now.ended { return false }
                if !now.held { return true }
                condition.wait()
            }
        }

        private func change(_ body: (inout (held: Bool, ended: Bool)) -> Void) {
            condition.lock()
            state.withLock { body(&$0) }
            condition.broadcast()
            condition.unlock()
        }
    }

    /// A number the server's threads add to.
    private final class Count: Sendable {
        private let value = Mutex(0)
        var now: Int { value.withLock { $0 } }
        func add() { value.withLock { $0 += 1 } }
    }

    /// Settings for a command run against the stand-in (`Home.make(pipeline:)`): its answers are waited for as long as a
    /// loaded machine may take, as a test asks what the command does with them, never how fast the runner is.
    public static var patient: [String: Any] { ["ollama": ["timeouts": ["meta": 60, "version": 60, "resolve": 60]]] }

    /// An answer to a chat: a status line's code and text, and a JSON body.
    public typealias Answer = (status: String, body: String)

    /// The chat answer no reading takes for a valid one.
    public static let emptyAnswer: Answer = ("200 OK", #"{"model":"loopback","message":{"role":"assistant","content":"{}"},"done":true,"done_reason":"stop"}"#)

    /// How long the listening thread waits for a connection before it looks whether it is to stop, in milliseconds.
    private static let stopCheckMilliseconds: Int32 = 100

    /// A server that answers every chat with `chat`, listening on a port of the loopback address the system gives it.
    public init(chat: Answer = emptyAnswer) throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // A client gone before its answer is written ends the write, not the test process: every connection taken from
        // this socket inherits it, whatever state the client left it in.
        var noSignal: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(socket)
            throw failure
        }
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
        address = "http://127.0.0.1:\(UInt16(bigEndian: assigned.sin_port))"
        let (stopped, holding, chats) = (stopped, holding, chats)
        Thread { Self.accept(on: socket, until: stopped, chat: { () -> Answer? in
            chats.add()
            return holding.waitWhileHeld() ? chat : nil
        }) }.start()
    }

    /// Stops listening: the listening thread closes the socket once it next looks, and a chat held is never answered.
    public func stop() {
        stopped.set()
        holding.end()
    }

    /// Holds every chat from now on unanswered, as a model still writing its answer, or answers them again, those held
    /// too.
    public func holdChats(_ hold: Bool) { holding.set(held: hold) }

    /// How many chats the server was sent, those held among them.
    public var chatsReceived: Int { chats.now }

    /// Takes each connection to `socket` until told to stop, answering it on a thread of its own: a chat with what
    /// `chat` gives once it gives it, or nothing when it gives none.
    private static func accept(on socket: Int32, until stopped: Flag, chat: @escaping @Sendable () -> Answer?) {
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
    private static func serve(_ connection: Int32, chat: @Sendable () -> Answer?) {
        defer { close(connection) }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: received[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if received.count - end.upperBound >= length {
                    let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    guard let (status, body) = path == "/api/chat" ? chat() : answer(path) else { return }
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
