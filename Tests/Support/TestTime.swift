import ArrumatorCore
import Foundation
import Synchronization

/// Time a test controls. It starts at a fixed moment and moves only when a test advances it or something sleeps on
/// it: `advances` makes every sleep pass at once, moving the time by what was slept; `blocks` makes every sleep wait
/// until its task is cancelled, as a deadline that never comes.
public final class TestTime: TimeSource {
    public enum Sleeping: Sendable { case advances, blocks }

    /// 2026-07-05 12:00:00 UTC: a fixed day for everything a test stamps.
    public static let start = Date(timeIntervalSince1970: 1_783_252_800)

    private let current: Mutex<Date>
    private let sleeping: Sleeping

    public init(_ sleeping: Sleeping, at start: Date = TestTime.start) {
        current = Mutex(start)
        self.sleeping = sleeping
    }

    public func now() -> Date { current.withLock { $0 } }

    public func advance(by seconds: Double) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }

    public func sleep(seconds: Double) async throws {
        switch sleeping {
        case .advances:
            try Task.checkCancellation()
            advance(by: seconds)
            await Task.yield()
        case .blocks:
            let (stream, continuation) = AsyncStream<Never>.makeStream()
            defer { continuation.finish() }
            for await _ in stream {}
            throw CancellationError()
        }
    }
}
