import Foundation

public enum Retry {
    /// Runs `body`, retrying after each delay in `delays` while `shouldRetry` accepts the error.
    public static func run<T: Sendable>(delays: [Double], shouldRetry: @Sendable (any Error) -> Bool,
                                        onRetry: @Sendable (Int, any Error) -> Void = { _, _ in },
                                        _ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch {
                guard attempt < delays.count, shouldRetry(error), !Task.isCancelled else { throw error }
                onRetry(attempt + 1, error)
                try await Task.sleep(for: .seconds(delays[attempt]))
                attempt += 1
            }
        }
    }
}

/// FIFO async semaphore; used to serialise model calls across actors.
public actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(permits: Int) { self.permits = permits }

    public func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    public func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
