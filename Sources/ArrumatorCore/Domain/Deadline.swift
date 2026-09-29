import Foundation

/// Bounds an exchange by its total time. URLSession's request timeout counts only idle time, and a reply lost on the
/// local network can leave a request waiting on a connection that stays open (seen with Ollama on another Mac over
/// Wi-Fi), holding every request queued behind it. A reply that is not streamed sends nothing before it is complete,
/// so an exchange that would have succeeded is not cut short.
public enum Deadline {
    /// Runs `operation`, and after `seconds` cancels it and throws `expired()`; 0 or less leaves it unbounded.
    /// `sleep` waits the given seconds; it is injected so tests need not wait.
    public static func run<T: Sendable>(_ seconds: Double, expired: @escaping @Sendable () -> any Error,
                                        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                                        _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds > 0 else { return try await operation() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await sleep(seconds)
                throw expired()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw expired() }
            return first
        }
    }
}
