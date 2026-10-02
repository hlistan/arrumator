import Foundation

public enum Retry {
    /// Runs `body`, retrying after each delay in `delays`, waited on `time`, while `shouldRetry` accepts the error.
    public static func run<T: Sendable>(delays: [Double], time: any TimeSource, shouldRetry: @Sendable (any Error) -> Bool,
                                        onRetry: @Sendable (Int, any Error) -> Void,
                                        _ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch {
                guard attempt < delays.count, shouldRetry(error), !Task.isCancelled else { throw error }
                onRetry(attempt + 1, error)
                try await time.sleep(seconds: delays[attempt])
                attempt += 1
            }
        }
    }
}

extension TimeSource {
    /// Waits for `work` until it ends or `seconds` have passed on this clock, whichever comes first: whether it ended in
    /// time. Work still running then is left to finish unawaited, never cancelled, and the caller goes on without it, as
    /// an app quits after a stop that hangs.
    public func wait(atMost seconds: Double, for work: @escaping @Sendable () async -> Void) async -> Bool {
        let (ends, end) = AsyncStream<Bool>.makeStream()
        Task {
            await work()
            end.yield(true)
        }
        let deadline = Task { [self] in
            do { try await sleep(seconds: seconds) } catch { return }
            end.yield(false)
        }
        defer { deadline.cancel() }
        for await inTime in ends { return inTime }
        return false
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
