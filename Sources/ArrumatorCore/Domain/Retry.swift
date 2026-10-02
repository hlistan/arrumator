import Foundation
import Synchronization

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

/// FIFO async semaphore; used to serialise model calls across actors. A task cancelled while it waits for a permit stops
/// waiting at once and gives up its place, so a worker that waits for the generation lane stops when it is told to,
/// without waiting for whoever holds the lane.
public final class AsyncSemaphore: Sendable {
    private struct State {
        var permits: Int
        /// Who waits for a permit, in the order they asked, each told by its own one-shot whether it got one.
        var queue: [OneShot<Bool>] = []
    }

    private let state: Mutex<State>

    public init(permits: Int) { state = Mutex(State(permits: permits)) }

    /// Takes a permit, waiting for one in turn when none is free. Throws `CancellationError`, holding no permit, when the
    /// task is cancelled before it has one.
    public func acquire() async throws {
        try Task.checkCancellation()
        let turn = OneShot<Bool>()
        let free = state.withLock { state in
            guard state.permits > 0 else {
                state.queue.append(turn)
                return false
            }
            state.permits -= 1
            return true
        }
        if free { return }
        let granted = await withTaskCancellationHandler {
            await turn.wait()
        } onCancel: {
            leave(turn)
        }
        guard granted else { throw CancellationError() }
    }

    /// Gives a permit back, to the first who waits for one.
    public func release() {
        let next: OneShot<Bool>? = state.withLock { state in
            guard !state.queue.isEmpty else {
                state.permits += 1
                return nil
            }
            return state.queue.removeFirst()
        }
        next?.fire(true)
    }

    /// Takes a waiter whose task was cancelled out of the queue. One no longer in it was given a permit just before, and
    /// keeps it, to give back when its work, which sees the cancellation, ends.
    private func leave(_ turn: OneShot<Bool>) {
        let left = state.withLock { state in
            guard let place = state.queue.firstIndex(where: { $0 === turn }) else { return false }
            state.queue.remove(at: place)
            return true
        }
        if left { turn.fire(false) }
    }

    public func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    /// How many wait for a permit: what a test watches for before it cancels one of them.
    var waiting: Int { state.withLock { $0.queue.count } }
}
