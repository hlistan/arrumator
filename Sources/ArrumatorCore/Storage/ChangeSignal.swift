import CryptoKit
import Foundation
import GRDB
import notify
import Synchronization

/// How one process tells the others that it changed a file they all keep open: an archive's index, after every
/// transaction that changed it commits (`CommitAnnouncer`), and the settings, after every change saved
/// (`SettingsStore`). A Darwin notification (`notify(3)`) named after the file's path. GRDB's observations see only the
/// commits of their own database pool: "changes performed by another process" are among the undetected changes
/// `Database.notifyChanges(in:)` exists to tell them of (GRDB, `TransactionObserver`, "Dealing with Undetected Changes"),
/// so without it the app would not see a task `arrumatorcli` queued, a rule it forgot or labels it changed until it
/// looked again for another reason (`AppDatabase.othersCommits()`); nor would it see a profile `arrumatorcli profiles`
/// added, or filing it paused. A notification carries nothing but its name: no path, no document, nothing of the file.
struct ChangeSignal: Sendable {
    /// What every index's notification is named with, before what tells one index from another.
    static let indexPrefix = "app.arrumator.index-changed."
    /// What every settings file's notification is named with, before what tells one from another.
    static let settingsPrefix = "app.arrumator.settings-changed."
    /// Bytes of the SHA-256 of the file's path that name its notification.
    static let nameBytes = 8

    let name: String

    /// The notification of the index at `index`.
    init(index: URL) { self.init(prefix: Self.indexPrefix, file: index) }

    /// The notification of the settings at `settings`.
    init(settings: URL) { self.init(prefix: Self.settingsPrefix, file: settings) }

    /// The notification of `file`, as every process names it: by its path as the disk spells it (`URL.spelledOnDisk`), so
    /// processes that open it through a link, `/private` or not, or in another case hear one another.
    private init(prefix: String, file: URL) {
        let digest = SHA256.hash(data: Data(file.spelledOnDisk.path.utf8)).prefix(Self.nameBytes)
        name = prefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Tells every process listening that the file changed, this one included.
    func post() {
        let status = notify_post(name)
        if status != NOTIFY_STATUS_OK { Log.warning(.db, "Could not tell other processes of a change", ["status": String(status)]) }
    }

    /// Each time a process posts the notification, for as long as the stream is read: a burst of posts is one, as only
    /// whether something changed since the last look matters.
    func posts() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, DispatchQueue.global(qos: .utility)) { _ in continuation.yield() }
        guard status == NOTIFY_STATUS_OK else {
            Log.warning(.db, "Could not listen for other processes' changes", ["status": String(status)])
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [token] _ in notify_cancel(token) }
        return stream
    }
}

/// Posts its index's `ChangeSignal` after each transaction that changed the index commits: one that changed
/// nothing, as a read in a write, posts nothing. Told of changes on the database pool's one writer connection.
final class CommitAnnouncer: TransactionObserver, Sendable {
    private let signal: ChangeSignal
    /// Whether the transaction under way has changed anything.
    private let changed = Mutex(false)

    init(signal: ChangeSignal) {
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
