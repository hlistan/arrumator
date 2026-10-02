import Foundation

/// How a queue's worker is told its queue changed. A ring while it waits ends the wait; rings while it works are kept as
/// one, so it looks at its queue once more when it is done, and none is lost.
public struct Doorbell: Sendable {
    private let rings: AsyncStream<Void>
    private let ringer: AsyncStream<Void>.Continuation

    public init() {
        (rings, ringer) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func ring() { ringer.yield() }

    /// Waits for a ring, or for `timeout` seconds of `time` when it is given. Cancellation ends the wait early too, and
    /// the worker then sees it and ends.
    public func wait(timeout: Double?, time: any TimeSource) async {
        let rings = rings
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var it = rings.makeAsyncIterator()
                _ = await it.next()
            }
            if let timeout {
                group.addTask { try? await time.sleep(seconds: timeout) }
            }
            await group.next()
            group.cancelAll()
        }
    }
}
