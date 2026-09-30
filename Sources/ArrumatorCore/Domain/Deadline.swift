import Foundation
import Synchronization

/// A value delivered exactly once, awaited by one waiter. The first `fire` wins; later calls are ignored.
public final class OneShot<Value: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Value, Never>)
        case fired(Value)
        case consumed
    }

    private let state = Mutex<State>(.idle)

    public init() {}

    /// Delivers `value` if nothing was delivered before. Returns `true` when this call won.
    @discardableResult
    public func fire(_ value: Value) -> Bool {
        let outcome: (won: Bool, waiter: CheckedContinuation<Value, Never>?) = state.withLock { state in
            switch state {
            case .idle:
                state = .fired(value)
                return (true, nil)
            case let .waiting(continuation):
                state = .consumed
                return (true, continuation)
            case .fired, .consumed:
                return (false, nil)
            }
        }
        outcome.waiter?.resume(returning: value)
        return outcome.won
    }

    /// Suspends until a value is fired (returns immediately if it already was). One waiter only: every caller in this
    /// package awaits the one-shot it created, so a second waiter is a programmer error, not something from outside.
    public func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let ready: Value? = state.withLock { state in
                switch state {
                case .idle:
                    state = .waiting(continuation)
                    return nil
                case let .fired(value):
                    state = .consumed
                    return value
                case .waiting, .consumed:
                    preconditionFailure("OneShot supports a single waiter")
                }
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Thrown, by a caller's choice, when `Deadline.run` ran out of time.
public struct DeadlineExceeded: Error, Sendable, Equatable {
    public let seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
}

/// Bounds work by its total time. URLSession's request timeout counts only idle time, and a reply lost on the local
/// network can leave a request waiting on a connection that stays open (seen with Ollama on another Mac over Wi-Fi),
/// holding every request queued behind it; PDFKit, Vision and CoreXLSX do not notice cancellation at all. A reply that
/// is not streamed sends nothing before it is complete, so an exchange that would have succeeded is not cut short.
public enum Deadline {
    /// Runs `operation` in a task of its own and returns its result, or throws `expired()` after `seconds` of `time`,
    /// without waiting for work that does not notice the cancellation it is then sent. `seconds` of 0 or less leaves it
    /// unbounded. Cancelling the caller cancels the operation and throws `CancellationError`.
    public static func run<T: Sendable>(_ seconds: Double, time: any TimeSource, expired: @escaping @Sendable () -> any Error,
                                        _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds > 0 else { return try await operation() }
        let outcome = OneShot<Result<T, any Error>>()
        let work = Task { try await operation() }
        Task { outcome.fire(await work.result) }
        let timer = Task {
            try await time.sleep(seconds: seconds)
            outcome.fire(.failure(expired()))
        }
        defer {
            timer.cancel()
            work.cancel()
        }
        let result = await withTaskCancellationHandler {
            await outcome.wait()
        } onCancel: {
            outcome.fire(.failure(CancellationError()))
        }
        return try result.get()
    }
}
