import Foundation
import GRDB

public enum DatabaseOpeningError: Error, LocalizedError {
    case unreadable(String, String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, why):
            "The index at \(path) cannot be opened (\(why)), and the archive holds no record files to rebuild it from. "
                + "Move the file away to start with an empty index."
        }
    }
}

/// An archive's index: one SQLite database per archive, shared by the app and the CLI (WAL, multi-process safe). It
/// indexes the archive's record files and caches what can be recomputed; see docs/storage.md.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// How the database was found when the app opened it.
    public enum Opening: Sendable, Equatable {
        case existing
        /// There was no database: a fresh one was created.
        case created
        /// The database could not be opened or migrated and was moved to this path; a fresh one was created.
        case setAside(URL)

        /// The index is empty and has to be read from the archive's record files.
        public var needsRebuild: Bool { self != .existing }
    }

    /// Opens (creating if needed) the on-disk database. One that cannot be opened or migrated is moved aside, never
    /// deleted, when `canRebuild` says the archive holds the records to rebuild it from; otherwise the error stands, so
    /// the app stops instead of starting empty.
    public static func open(at url: URL, setAsideSuffix: String, canRebuild: () -> Bool) throws -> (AppDatabase, Opening) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: url.path)
        do {
            return (try openPool(at: url), existed ? .existing : .created)
        } catch {
            guard existed, canRebuild() else { throw DatabaseOpeningError.unreadable(url.path, error.localizedDescription) }
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
                .timeSeparator(.omitted).dateTimeSeparator(.standard))
            let aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(setAsideSuffix)-\(stamp)")
            for suffix in [""] + companionSuffixes {
                let from = URL(fileURLWithPath: url.path + suffix)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try FileManager.default.moveItem(at: from, to: URL(fileURLWithPath: aside.path + suffix))
            }
            Log.error(.db, "Database could not be opened; moved aside and rebuilding from the archive",
                      ["path": aside.path, "error": error.localizedDescription])
            return (try openPool(at: url), .setAside(aside))
        }
    }

    /// The files SQLite keeps next to a database in WAL mode, named by adding these to its path.
    public static let companionSuffixes = ["-wal", "-shm"]

    private static func openPool(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    public var reader: any DatabaseReader { writer }

    // MARK: Meta

    public func meta(_ key: String) async throws -> String? {
        try await reader.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, value])
        }
    }
}

extension AppDatabase {
    /// Emits how many record files are waiting to be written, whenever that changes.
    public func pendingRecords() -> AsyncStream<Int> {
        let observation = ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty") ?? 0
        }.removeDuplicates()
        let reader = reader
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: reader) { continuation.yield(value) }
                } catch {
                    Log.error(.db, "Record observation ended", ["error": error.localizedDescription])
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Emits a new value whenever something is recorded in the history (arrivals, readings, filings, corrections,
    /// decisions about labels…). The UI refreshes on it instead of polling.
    public func activity() -> AsyncStream<Int64> {
        let observation = ValueObservation.tracking { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM events") ?? 0
        }.removeDuplicates()
        let reader = reader
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: reader) { continuation.yield(value) }
                } catch {
                    Log.error(.db, "Activity observation ended", ["error": error.localizedDescription])
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
