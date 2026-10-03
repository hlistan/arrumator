import Foundation

/// Cancellation stops the work: a fallback, `try?` or a `catch` that goes on never stands in for it (AGENTS.md §3).
public enum Cancellation {
    /// Throws when `error` is cancellation, or the task was cancelled, as a failure that comes while it is stopping may
    /// be no more than the stop showing through the code it reached, such as a database access cancelled with it (GRDB's
    /// `DatabaseWriter.write` throws `CancellationError`) or a request cut off. A catch-all calls it first, so only the
    /// failures its fallback stands in for go on.
    public static func rethrow(_ error: any Error) throws {
        if error is CancellationError { throw error }
        try Task.checkCancellation()
    }

    /// Whether `error` ends the work as a stop does: cancellation, or any failure while the task is cancelled.
    public static func stops(_ error: any Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }
}
