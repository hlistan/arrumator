import Foundation
import Synchronization

/// Which jobs the workers of this process hold (`JobStore.nextDue`). A job is taken in the write that marks it with a
/// claim of its own and this process (`jobs.claim`, and `jobs.claimed_by`, its `ProcessTag`), and kept until it ends or
/// its worker lets it go, so no other worker, of this process or another, as `arrumatorcli` beside the app, works on it
/// meanwhile. A claim of another process is held while that process runs, and one of this process while the worker that
/// made it has it in hand: the claim of a process that crashed or was forced to quit, or of a worker that stopped
/// without letting it go, holds nothing (`ProcessWatching.hasLeft`, as the task queues tell an item left behind), and the
/// job is taken again.
public final class JobClaims: Sendable {
    /// Which process this is, and which others run: the system's (`SystemProcesses`), which cannot be made when the
    /// kernel does not say when this process started (`ProcessError.unknownStart`), or a test's.
    public let processes: any ProcessWatching
    /// The claims the workers of this process have in hand.
    private let inHand = Mutex<Set<String>>([])

    /// One per runtime, shared by its pipelines, so a claim one of its workers has in hand is held for all of them.
    public init(processes: any ProcessWatching) {
        self.processes = processes
    }

    /// This process, as `jobs.claimed_by` keeps it.
    var process: String { processes.current.description }

    /// A new claim, in hand from now until `letGo`.
    func make() -> String {
        let claim = UUID().uuidString
        inHand.withLock { _ = $0.insert(claim) }
        return claim
    }

    func letGo(_ claim: String) {
        inHand.withLock { _ = $0.remove(claim) }
    }

    /// Whether `claim`, made by the process kept as `worker`, still holds its job: another process's while it runs, this
    /// process's while a worker has it in hand.
    func holds(_ claim: String?, by worker: String?) -> Bool {
        guard let claim else { return false }
        if !processes.hasLeft(worker) { return true }
        return worker.flatMap(ProcessTag.init) == processes.current && inHand.withLock { $0.contains(claim) }
    }
}
