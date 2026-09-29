import Foundation
import Synchronization

/// A value delivered exactly once, awaited by one waiter. The first `fire` wins; later calls are ignored.
final class OneShot<Value: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Value, Never>)
        case fired(Value)
        case consumed
    }

    private let state = Mutex<State>(.idle)

    /// Delivers `value` if nothing was delivered before. Returns `true` when this call won.
    @discardableResult
    func fire(_ value: Value) -> Bool {
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

    /// Suspends until a value is fired (returns immediately if it already was).
    func wait() async -> Value {
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

/// Thrown by `Deadline.run` when the operation did not finish in time.
struct DeadlineExceeded: Error, Sendable {
    let seconds: Double
}

enum Deadline {
    /// Runs `operation` in its own task and returns its result, or throws `DeadlineExceeded` after `seconds`
    /// without waiting for non-cooperative work (PDFKit, Vision, CoreXLSX) to notice the cancellation.
    /// `seconds <= 0` disables the deadline. Cancellation of the caller cancels the operation and throws
    /// `CancellationError`.
    static func run<T: Sendable>(seconds: Double,
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds > 0 else { return try await operation() }
        let outcome = OneShot<Result<T, any Error>>()
        let work = Task { try await operation() }
        Task { outcome.fire(await work.result) }
        let timer = Task {
            try await Task.sleep(for: .seconds(seconds))
            outcome.fire(.failure(DeadlineExceeded(seconds: seconds)))
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
