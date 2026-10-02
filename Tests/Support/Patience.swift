import Foundation
import Synchronization

/// How a test waits for work running in the background, such as a started queue or a stream's subscriber, to make
/// something so: never by sleeping, but by checking a condition until it holds or a deadline passes.
public enum Patience {
    /// How long a test waits before it fails.
    public static let limit: Duration = .seconds(10)

    /// Waits, yielding to the tasks that make it so, until `condition` holds or `limit` has passed; whether it held.
    public static func until(_ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            await Task.yield()
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

/// Work that ends, such as a stop or a wait, each time it ended: whether its task was cancelled then.
public actor Ending {
    public private(set) var ended: [Bool] = []

    public init() {}

    public func end() { ended.append(Task.isCancelled) }
}
