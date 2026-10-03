import Foundation
import Synchronization

/// How a queue's worker is told its queue changed. A ring while it waits ends the wait; a ring while nobody waits is
/// kept, as one however many came, so the worker looks at its queue once more when it next waits, and none is lost.
///
/// Each wait is ended by a one-shot of its own (`OneShot`), which a ring, its timer or its task's cancellation fires,
/// whichever comes first. Nothing waits on a stream the waits share: cancelling a task that awaits `AsyncStream`'s
/// `next()` ends the stream for every later consumer ("If you cancel the task this iterator is running in while next()
/// is awaiting a value, the AsyncStream terminates", Apple, `AsyncStream.Iterator.next()`), so a wait whose timer won
/// would have left every later wait returning at once, and the worker reading its queue without pause.
public final class Doorbell: Sendable {
    private struct State {
        /// A ring came while nobody waited.
        var rung = false
        /// The waits in progress, each ended by its own one-shot.
        var waiting: [OneShot<Void>] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Ends every wait in progress, or, with none, the next one as soon as it begins.
    public func ring() {
        let woken: [OneShot<Void>] = state.withLock { state in
            guard !state.waiting.isEmpty else {
                state.rung = true
                return []
            }
            defer { state.waiting.removeAll() }
            return state.waiting
        }
        for wake in woken { wake.fire(()) }
    }

    /// Whether a wait is in progress: the worker it rings for has looked at its queue, found nothing it may take, and
    /// waits.
    var isWaitedOn: Bool { state.withLock { !$0.waiting.isEmpty } }

    /// Waits for a ring, or for `timeout` seconds of `time` when it is given. Cancellation ends the wait early too, and
    /// the worker then sees it and ends.
    public func wait(timeout: Double?, time: any TimeSource) async {
        let wake = OneShot<Void>()
        let kept = state.withLock { state in
            if state.rung {
                state.rung = false
                return true
            }
            state.waiting.append(wake)
            return false
        }
        guard !kept else { return }
        await withTaskGroup(of: Void.self) { group in
            if let timeout {
                group.addTask {
                    // A timer cancelled because the wait ended otherwise has nothing left to end.
                    do { try await time.sleep(seconds: timeout) } catch { return }
                    wake.fire(())
                }
            }
            await withTaskCancellationHandler {
                await wake.wait()
            } onCancel: {
                wake.fire(())
            }
            group.cancelAll()
        }
        state.withLock { $0.waiting.removeAll { $0 === wake } }
    }
}
