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

    /// The time zone the pipeline a test builds reckons days in, whatever the Mac's: fourteen hours ahead of UTC, where
    /// `start` is already 2026-07-06, so a day reckoned in UTC, or in the Mac's own zone, is told apart from it.
    public static let zone: TimeZone = {
        guard let zone = TimeZone(identifier: "Pacific/Kiritimati") else { preconditionFailure("a constant zone exists") }
        return zone
    }()

    /// `start`'s day in `zone`.
    public static let startDay = "2026-07-06"

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

/// Time that a test reads as `TestTime` and that never passes on its own: every sleep is recorded, then waits until its
/// task is cancelled. What a worker asked to wait for, when the test needs to know how long it would have waited.
public final class SleepLog: TimeSource {
    private let time: TestTime
    private let asked = Mutex<[Double]>([])

    public init(_ time: TestTime) { self.time = time }

    /// Every sleep asked for, in seconds, in the order asked.
    public var sleeps: [Double] { asked.withLock { $0 } }

    public func now() -> Date { time.now() }

    public func sleep(seconds: Double) async throws {
        asked.withLock { $0.append(seconds) }
        try await TestTime(.blocks).sleep(seconds: seconds)
    }
}
