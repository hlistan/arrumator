import CryptoKit
import Foundation
import GRDB
import notify
import Synchronization

/// How one process tells the others that have an archive's index open that it committed a change to it: a Darwin
/// notification (`notify(3)`) named after the index's file, posted after every transaction that changed the index commits
/// (`CommitAnnouncer`). GRDB's observations see only the commits of their own database pool: "changes performed by
/// another process" are among the undetected changes `Database.notifyChanges(in:)` exists to tell them of (GRDB,
/// `TransactionObserver`, "Dealing with Undetected Changes"), so without it the app would not see a task `arrumatorcli`
/// queued, a rule it forgot or labels it changed until it looked again for another reason
/// (`AppDatabase.othersCommits()`). A notification carries nothing but its name: no path, no document, nothing of the
/// index.
struct IndexChangeSignal: Sendable {
    /// What every index's notification is named with, before what tells one index from another.
    static let prefix = "app.arrumator.index-changed."
    /// Bytes of the SHA-256 of the index's path that name its notification.
    static let nameBytes = 8

    let name: String

    /// The notification of the index at `index`, as every process names it: by its path as the disk spells it
    /// (`URL.spelledOnDisk`), so processes that open it through a link, `/private` or not, or in another case hear one
    /// another.
    init(index: URL) {
        let digest = SHA256.hash(data: Data(index.spelledOnDisk.path.utf8)).prefix(Self.nameBytes)
        name = Self.prefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Tells every process listening that the index changed, this one included.
    func post() {
        let status = notify_post(name)
        if status != NOTIFY_STATUS_OK { Log.warning(.db, "Could not tell other processes the index changed", ["status": String(status)]) }
    }

    /// Each time a process posts the notification, for as long as the stream is read: a burst of posts is one, as only
    /// whether something changed since the last look matters.
    func posts() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, DispatchQueue.global(qos: .utility)) { _ in continuation.yield() }
        guard status == NOTIFY_STATUS_OK else {
            Log.warning(.db, "Could not listen for other processes' changes to the index", ["status": String(status)])
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [token] _ in notify_cancel(token) }
        return stream
    }
}

/// Posts its index's `IndexChangeSignal` after each transaction that changed the index commits: one that changed
/// nothing, as a read in a write, posts nothing. Told of changes on the database pool's one writer connection.
final class CommitAnnouncer: TransactionObserver, Sendable {
    private let signal: IndexChangeSignal
    /// Whether the transaction under way has changed anything.
    private let changed = Mutex(false)

    init(signal: IndexChangeSignal) {
        self.signal = signal
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }

    func databaseDidChange(with event: DatabaseEvent) {
        changed.withLock { $0 = true }
        // One change is enough to know: the rest of the transaction is not followed.
        stopObservingDatabaseChangesUntilNextTransaction()
    }

    func databaseDidCommit(_ db: Database) {
        if changed.withLock({ changed in defer { changed = false }; return changed }) { signal.post() }
    }

    func databaseDidRollback(_ db: Database) {
        changed.withLock { $0 = false }
    }
}
