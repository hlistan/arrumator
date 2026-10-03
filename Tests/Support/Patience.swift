import Foundation
import Synchronization

/// How a test waits for work running in the background, such as a started queue or a stream's subscriber, to make
/// something so: never by sleeping a guessed time, but by checking a condition until it holds or a deadline passes.
/// This and the test clocks (`TestTime`, `SleepLog`) are the only waits a test makes (lint gate `test-sleeps`).
public enum Patience {
    /// How long a test waits before it fails: what tells a test that waits for ever from one that waits its turn, never
    /// how fast the work is. A wait that is met returns at once, so only a broken test waits it out. It is longer than a
    /// whole run of a test process on a loaded Mac (about 21 seconds for the core tests under load), as every test of a
    /// process starts at once and the work a test waits for queues behind all of theirs: in such a run a test that waits
    /// for nothing, such as one reading the app's version, has been seen to take eleven seconds, which a ten-second limit
    /// failed tests on. It stays well under the minute of the suites' `.timeLimit`, so a wait that fails says so itself.
    public static let limit: Duration = .seconds(30)
    /// How long it gives the work between two looks. Looking again at once, by `Task.yield()`, keeps a thread of the
    /// cooperative pool turning for every test that waits, and under a full parallel run those waiters starve the very
    /// work they wait for, which then misses the deadline.
    public static let look: Duration = .milliseconds(2)

    /// Waits until `condition` holds or `limit` has passed, giving the threads to the work that makes it so between
    /// looks; whether it held. A task cancelled meanwhile looks once more and stops waiting.
    public static func until(_ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if try await condition() { return true }
            do { try await Task.sleep(for: look) } catch { break }
        }
        return try await condition()
    }
}

/// Something that happens once, such as a double being reached, which a test waits for with
/// `Patience.until { signal.fired }` rather than by awaiting it, so a test whose feature is broken fails instead of
/// waiting for ever.
public final class Signal: Sendable {
    private let state = Mutex(false)

    public init() {}

    public func fire() { state.withLock { $0 = true } }

    public var fired: Bool { state.withLock { $0 } }
}

/// A place work is held at, such as a flush between reading a file and writing it: how many times it got there, and a
/// gate the first arrival waits at until the test opens it.
public final class Hold: Sendable {
    private let state = Mutex<(arrivals: Int, gate: CheckedContinuation<Void, Never>?, open: Bool)>((0, nil, false))

    public init() {}

    public var arrivals: Int { state.withLock { $0.arrivals } }

    /// Arrives; the first arrival waits until `open()`.
    public func arrive() async {
        let first = state.withLock { state in
            state.arrivals += 1
            return state.arrivals == 1
        }
        guard first else { return }
        await withCheckedContinuation { continuation in
            let open = state.withLock { state in
                if !state.open { state.gate = continuation }
                return state.open
            }
            if open { continuation.resume() }
        }
    }

    public func open() {
        let gate = state.withLock { state in
            state.open = true
            defer { state.gate = nil }
            return state.gate
        }
        gate?.resume()
    }
}

/// Work that ends, such as a stop or a wait, each time it ended: whether its task was cancelled then.
public actor Ending {
    public private(set) var ended: [Bool] = []

    public init() {}

    public func end() { ended.append(Task.isCancelled) }
}
