import Foundation
import Synchronization

/// Looks a name up as every connection of the Mac's would (`getaddrinfo`): a `.local` name by multicast DNS on the
/// local link (RFC 6762), through mDNSResponder. The lookup blocks while it waits, so it runs on a thread of its own,
/// and the caller waits for it at most the time it is given, or until it is cancelled: what the lookup finds after is
/// dropped.
public struct SystemHostResolver: HostResolving {
    /// How a name is looked up, blocking its thread: `getaddrinfo`, or what a test holds as a lookup that takes long.
    private let lookUp: @Sendable (String) -> [String]

    public init() { lookUp = Self.lookUp }

    init(lookingUpBy lookUp: @escaping @Sendable (String) -> [String]) { self.lookUp = lookUp }

    public func addresses(of host: String, within seconds: Double) async throws -> [String] {
        let lookup = Lookup()
        let lookUp = lookUp
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lookup.wait(continuation)
                DispatchQueue.global(qos: .utility).async { lookup.finish(.success(lookUp(host))) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { lookup.finish(.success([])) }
            }
        } onCancel: {
            lookup.finish(.failure(CancellationError()))
        }
    }

    /// One lookup's outcome, given to its caller once: by the lookup, its time running out or its cancellation,
    /// whichever comes first, also when that comes before the caller waits.
    final class Lookup: Sendable {
        private struct State {
            var waiting: CheckedContinuation<[String], any Error>?
            var outcome: Result<[String], any Error>?
        }

        private let state = Mutex(State())

        func wait(_ continuation: CheckedContinuation<[String], any Error>) {
            state.withLock { state in
                if let outcome = state.outcome { continuation.resume(with: outcome) } else { state.waiting = continuation }
            }
        }

        func finish(_ outcome: Result<[String], any Error>) {
            state.withLock { state in
                guard state.outcome == nil else { return }
                state.outcome = outcome
                state.waiting?.resume(with: outcome)
                state.waiting = nil
            }
        }
    }

    static func lookUp(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &found) == 0, let first = found else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = entry.pointee.ai_addr else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, entry.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !addresses.contains(text) { addresses.append(text) }
        }
        return addresses
    }
}
