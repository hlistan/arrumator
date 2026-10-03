import Foundation
import GRDB

public enum DatabaseOpeningError: Error, LocalizedError {
    case unreadable(String, String)
    /// The index is sound, but cannot be opened now: another process holds it, the disk is full, or it may not be read.
    case unavailable(String, String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, why):
            "The index at \(path) cannot be opened (\(why)), and the archive holds no record files to rebuild it from. "
                + "Move the file away to start with an empty index."
        case let .unavailable(path, why):
            "The index at \(path) cannot be opened right now (\(why)). It is left as it is; quit whatever else uses it, "
                + "free disk space or check its permissions, then try again."
        }
    }
}

/// An archive's index: one SQLite database per archive, shared by the app and the CLI (WAL, multi-process safe). It
/// indexes the archive's record files and caches what can be recomputed; see docs/storage.md.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    /// Seconds before an observation that failed is made again (`database.observationRetry`).
    let observationRetry: Double
    /// The clock that wait is slept on.
    let time: any TimeSource

    public init(_ writer: any DatabaseWriter, observationRetry: Double, time: any TimeSource) throws {
        self.writer = writer
        self.observationRetry = observationRetry
        self.time = time
        try Self.migrator.migrate(writer)
    }

    /// How the database was found when the app opened it.
    public enum Opening: Sendable, Equatable {
        case existing
        /// There was no database: a fresh one was created.
        case created
        /// The database could not be opened or migrated and was moved to this path; a fresh one was created.
        case setAside(URL)
    }

    /// The key in `meta` of an index that is still to be rebuilt from its archive's record files, which says how far it
    /// got (`PendingRebuild`). The index says so itself from the transaction that makes it (`v1_initial`), so a rebuild
    /// that never ran, as when the app quits before onboarding opens the archive, or that was refused or cut short, is
    /// done at the next opening; until then the index takes no change to what the record files hold
    /// (`v19_unreadIndexRefusesRecords`), holds the events of other changes until it is rebuilt (`HistoryStore.insert`)
    /// and is worked on by nothing (`ArchiveRecords.rebuildIfPending`, `ArrumatorRuntime.start`).
    public static let rebuildPendingKey = "rebuild_pending"

    /// The key in `meta` of the record files that kept the index's last rebuild from being done, which a change it then
    /// refused names (`explained`).
    static let rebuildRefusedKey = "rebuild_refused"

    /// How far an index still to be rebuilt from its archive got.
    public enum PendingRebuild: String, Sendable {
        /// It was created or set aside, and holds nothing of the archive yet: nothing is read into it from the record
        /// files, or written into them from it, but by its rebuild.
        case unread
        /// The archive was read into it; its documents are still to be found on disk and queued to be read again.
        case unfinished
    }

    /// Where this index is in being rebuilt from its archive; nil when it is not to be rebuilt. A value this version does
    /// not know, which a later version wrote, is taken as `unread`: the index is not taken for one that holds the archive.
    public func pendingRebuild() async throws -> PendingRebuild? {
        try await reader.read { db in try Self.pendingRebuild(db) }
    }

    /// `pendingRebuild()`, read in the transaction of `db`, where what it decides is acted on.
    static func pendingRebuild(_ db: Database) throws -> PendingRebuild? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [rebuildPendingKey]).map { PendingRebuild(rawValue: $0) ?? .unread }
    }

    /// Records, in the transaction of `db`, where the index is in being rebuilt; nil when it is rebuilt, which also
    /// forgets what kept it from being and records the events held while it held nothing of its archive
    /// (`HistoryStore.recordHeld`).
    static func setPendingRebuild(_ db: Database, _ pending: PendingRebuild?) throws {
        if let pending {
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [rebuildPendingKey, pending.rawValue])
        } else {
            try db.execute(sql: "DELETE FROM meta WHERE key IN (?, ?)", arguments: [rebuildPendingKey, rebuildRefusedKey])
            try HistoryStore.recordHeld(db)
        }
    }

    /// Whether, in the transaction of `db`, the index's last rebuild was refused for record files it could not read, and
    /// none has succeeded since.
    static func rebuildWasRefused(_ db: Database) throws -> Bool {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [rebuildRefusedKey]) != nil
    }

    /// Whether the index has ever held anything of its archive, which an empty folder made in the archive's place would
    /// hide: a document, a record file written or read, or a rebuild refused for record files it could not read.
    public func heldAnArchive() async throws -> Bool {
        try await reader.read { db in
            try DocumentRecord.fetchCount(db) > 0 || Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM record_files)") == true
                || Self.rebuildWasRefused(db)
        }
    }

    /// Records, in the transaction of `db`, the record files that kept the index from being rebuilt.
    static func setRebuildRefused(_ db: Database, _ files: [UnreadableRecordFile]) throws {
        try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [rebuildRefusedKey, try JSON.string(files)])
    }

    /// Why nothing the record files hold can be changed in the index yet: the record files its last rebuild could not
    /// read, if it was refused.
    public func notRebuilt() async -> RecordsError {
        // Only to say why; a refusal that cannot be read back still says what to do.
        let files = (try? await meta(Self.rebuildRefusedKey)).flatMap { JSON.decode([UnreadableRecordFile].self, from: $0) }
        return .notRebuilt(files ?? [])
    }

    /// `error`, or, when it is a change the index refused as it is not rebuilt yet (`v19_unreadIndexRefusesRecords`),
    /// `RecordsError.notRebuilt`, which names the record files to correct and says what to do. Whatever shows a failed
    /// change to the user shows it through this, the one place the database's refusal is read.
    public func explained(_ error: any Error) async -> any Error {
        guard let refusal = error as? DatabaseError, refusal.message == Self.notRebuiltMessage else { return error }
        return await notRebuilt()
    }

    /// Opens (creating if needed) the on-disk database. One that is damaged or cannot be migrated is moved aside, never
    /// deleted, when `canRebuild` says the archive holds the records to rebuild it from; otherwise the error stands, so
    /// the app stops instead of starting empty. One that cannot be opened for the moment (`isPassing`) is never set
    /// aside: rebuilding it would lose its traces and queue for a lock that would have been released. A new index, and
    /// the one that takes the place of one set aside, is to be rebuilt (`PendingRebuild.unread`), even when the archive
    /// seems to hold no records: whether it does is decided when it is opened, by walking it whole
    /// (`ArchiveRecords.rebuildIfPending`), as its records may not show yet, while a sync goes on or before macOS lets the
    /// app read the folder.
    public static func open(at url: URL, config: DatabaseConfig, setAsideSuffix: String, time: any TimeSource,
                            canRebuild: () -> Bool) throws -> (AppDatabase, Opening) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: url.path)
        do {
            let database = try openPool(at: url, config: config, time: time)
            return (database, existed ? .existing : .created)
        } catch {
            if isPassing(error) { throw DatabaseOpeningError.unavailable(url.path, error.localizedDescription) }
            guard existed, canRebuild() else { throw DatabaseOpeningError.unreadable(url.path, error.localizedDescription) }
            let stamp = time.now().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
                .timeSeparator(.omitted).dateTimeSeparator(.standard))
            let aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(setAsideSuffix)-\(stamp)")
            for suffix in [""] + companionSuffixes {
                let from = URL(fileURLWithPath: url.path + suffix)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try FileManager.default.moveItem(at: from, to: URL(fileURLWithPath: aside.path + suffix))
            }
            Log.error(.db, "Database could not be opened; moved aside and rebuilding from the archive",
                      ["path": aside.path, "error": error.localizedDescription])
            return (try openPool(at: url, config: config, time: time), .setAside(aside))
        }
    }

    /// SQLite's results that say nothing about the database itself (https://sqlite.org/rescode.html): it is locked by
    /// another connection, the disk is full or failing, the file may not be opened or written, or memory ran out.
    private static let passingResults: [ResultCode] = [
        .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_FULL, .SQLITE_IOERR, .SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_READONLY,
        .SQLITE_NOMEM, .SQLITE_INTERRUPT,
    ]

    static func isPassing(_ error: any Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }
        return passingResults.contains(error.resultCode.primaryResultCode)
    }

    /// The files SQLite keeps next to a database in WAL mode, named by adding these to its path.
    public static let companionSuffixes = ["-wal", "-shm"]

    /// What the first column of `PRAGMA wal_checkpoint` holds when another connection kept it from finishing.
    static let checkpointBlocked = 1

    /// Writes the database's write-ahead log into its file and empties it (https://sqlite.org/wal.html, "Checkpointing"),
    /// so the file alone holds everything, and it can be moved without the files beside it. One held by another process
    /// is left as it is, and says so, as opening it would; one that is damaged is left as it is, to be set aside when it
    /// is opened (`open`).
    static func checkpoint(_ url: URL) throws {
        do {
            let queue = try DatabaseQueue(path: url.path)
            // TRUNCATE copies every frame of the log into the database, then empties the log.
            let blocked = try queue.inDatabase { db in try Int.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            try queue.close()
            if blocked == checkpointBlocked { throw DatabaseOpeningError.unavailable(url.path, "another process is writing to it") }
        } catch let error where isPassing(error) {
            throw DatabaseOpeningError.unavailable(url.path, error.localizedDescription)
        } catch let error as DatabaseError {
            Log.warning(.db, "Database could not be checkpointed; moved as it is", ["path": url.path, "error": error.localizedDescription])
        }
    }

    private static func openPool(at url: URL, config database: DatabaseConfig, time: any TimeSource) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(database.busyTimeout)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool, observationRetry: database.observationRetry, time: time)
    }

    /// In-memory database for tests, configured as the bundled defaults say, and complete: it is not to be rebuilt from
    /// an archive. `time` is what a failed observation waits on before it is made again; a test that makes one fail gives
    /// a clock of its own.
    public static func inMemory(time: any TimeSource = SystemTime()) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let database = try AppDatabase(DatabaseQueue(configuration: config),
                                       observationRetry: try PipelineConfig.bundledDefaults().database.observationRetry, time: time)
        try database.writer.write { db in try setPendingRebuild(db, nil) }
        return database
    }

    public var reader: any DatabaseReader { writer }

    // MARK: Meta

    public func meta(_ key: String) async throws -> String? {
        try await reader.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String) async throws {
        try await writer.write { db in try Self.setMeta(db, key, value) }
    }

    /// Sets `key` within a write of the caller's, so it is kept with what else that write keeps, or not at all.
    static func setMeta(_ db: Database, _ key: String, _ value: String?) throws {
        guard let value else {
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
            return
        }
        try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [key, value])
    }
}

extension AppDatabase {
    /// Emits how many record files are waiting to be written, whenever that changes.
    public func pendingRecords() -> AsyncStream<Int> {
        values(of: ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty") ?? 0
        }.removeDuplicates(), named: "records")
    }

    /// Emits a new value whenever something is recorded in the history (arrivals, readings, filings, corrections,
    /// decisions about labels…). The UI refreshes on it instead of polling.
    public func activity() -> AsyncStream<Int64> {
        values(of: ValueObservation.tracking { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM events") ?? 0
        }.removeDuplicates(), named: "activity")
    }

    /// The values of `observation` for as long as the stream is consumed, the current one first. GRDB ends an
    /// observation at its first error, which would leave whoever watches it deaf to every later change, as nothing
    /// subscribes again; so one that fails is logged once and made again after `observationRetry` seconds, and the
    /// stream goes on from the value it has then. Only cancelling the stream's consumer ends it.
    func values<Reducer: ValueReducer>(of observation: ValueObservation<Reducer>, named name: String) -> AsyncStream<Reducer.Value>
    where Reducer.Value: Sendable {
        let (reader, retry, time) = (reader, observationRetry, time)
        return AsyncStream { continuation in
            let task = Task {
                var failing = false
                while !Task.isCancelled {
                    do {
                        for try await value in observation.values(in: reader) {
                            if failing { Log.info(.db, "Observation of the index resumed", ["observation": name]) }
                            failing = false
                            continuation.yield(value)
                        }
                        break
                    } catch is CancellationError {
                        break
                    } catch {
                        if !failing {
                            Log.error(.db, "Observation of the index failed; observing it again", ["observation": name, "seconds": String(retry),
                                                                                                  "error": error.localizedDescription])
                        }
                        failing = true
                        do { try await time.sleep(seconds: retry) } catch { break }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
