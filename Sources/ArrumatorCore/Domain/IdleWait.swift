import Foundation

/// How long a queue's worker waits for the doorbell when it has taken no item, as the ingest worker and the queues of
/// tasks and questions (`ModelQueue`) wait alike: until the next item is due, or the doorbell rings. While another
/// process holds items of the queue, at most `ingest.heldElsewhereRecheckSeconds`: should that process end without
/// letting them go, as a command killed part way, nothing rings, and the worker takes them up when it looks again.
public enum IdleWait {
    /// Seconds to wait, from `now`, for an item due at `due`; nil to wait for the doorbell alone.
    public static func seconds(untilDue due: Date?, heldElsewhere: Bool, recheck: Double, now: Date) -> Double? {
        let toDue = due.map { max(0, $0.timeIntervalSince(now)) }
        guard heldElsewhere else { return toDue }
        return min(toDue ?? recheck, recheck)
    }
}
