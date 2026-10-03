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

/// Work that a deadline, or its caller's cancellation, gave up waiting for and that still runs, as a parse PDFKit does
/// not let be cancelled: how much of it there is, for the work it was done for, which a worker does not start again
/// while any goes on, so abandoned runs of one file never stack up (`IngestCoordinator`). It is told of the work it
/// stands for through the task that does it (`current`), so whatever bounds work by `Deadline.run` beneath it, a file's
/// extraction or a model's reading, is counted without being handed it.
public final class LeftRunning: Sendable {
    /// The count for the work the current task does; nil where nothing counts it.
    @TaskLocal public static var current: LeftRunning?

    private let count = Mutex(0)
    private let ended: @Sendable () -> Void

    /// - Parameter ended: called each time a run left behind ends, as to wake the worker waiting for it.
    public init(ended: @escaping @Sendable () -> Void) { self.ended = ended }

    /// Whether any run left behind still goes on.
    public var isRunning: Bool { count.withLock { $0 > 0 } }

    func began() { count.withLock { $0 += 1 } }

    func end() {
        count.withLock { $0 -= 1 }
        ended()
    }
}

/// Bounds work by its total time. URLSession's request timeout counts only idle time, and a reply lost on the local
/// network can leave a request waiting on a connection that stays open (seen with Ollama on another Mac over Wi-Fi),
/// holding every request queued behind it; PDFKit, Vision and ZIPFoundation do not notice cancellation at all. A reply that
/// is not streamed sends nothing before it is complete, so an exchange that would have succeeded is not cut short.
public enum Deadline {
    /// Runs `operation` in a task of its own and returns its result, or throws `expired()` after `seconds` of `time`,
    /// without waiting for work that does not notice the cancellation it is then sent. `seconds` of 0 or less leaves it
    /// unbounded. Cancelling the caller cancels the operation and throws `CancellationError`. Work given up on while it
    /// still runs is counted, until it ends, by the `LeftRunning` of the task that called this.
    public static func run<T: Sendable>(_ seconds: Double, time: any TimeSource, expired: @escaping @Sendable () -> any Error,
                                        _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds > 0 else { return try await operation() }
        let outcome = OneShot<Result<T, any Error>>()
        let leftRunning = LeftRunning.current
        // Whether the work has ended, and whether it was given up on before it did, decided under one lock.
        let state = Mutex((ended: false, givenUp: false))
        let work = Task { try await operation() }
        Task {
            let result = await work.result
            if state.withLock({ state in
                state.ended = true
                return state.givenUp
            }) { leftRunning?.end() }
            outcome.fire(result)
        }
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
        if state.withLock({ state in
            guard !state.ended else { return false }
            state.givenUp = true
            return true
        }) { leftRunning?.began() }
        return try result.get()
    }
}
