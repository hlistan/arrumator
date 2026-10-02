import Foundation

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
