import Foundation
import GRDB

/// What History is told of the record files that cannot be read (docs/storage.md, "Keeping files and index together"): each
/// once, whichever process finds it, and once more when it reads again, which the app shows meanwhile.
extension ArchiveRecords {
    /// The key in `meta` of the record files History has said cannot be read, and why, by their paths (a JSON object): so
    /// each is said once, whichever process finds it, and once more when it reads again.
    static let unreadableKey = "records_unreadable"

    /// The record files History last said cannot be read, and why: what the app shows until it says they read again.
    public func unreadableRecorded() async throws -> [UnreadableRecordFile] {
        let said = JSON.decode([String: String].self, from: try await database.meta(Self.unreadableKey)) ?? [:]
        return said.map { UnreadableRecordFile(path: $0.key, reason: $0.value) }.sorted { $0.path < $1.path }
    }

    /// Of the record files `found` unreadable and those `read`, the paths History has not been told of, as `said` keeps
    /// what it was told: those that cannot be read, and those it was told cannot that now can.
    private static func untold(said: [String: String], found: [String: String], read: Set<String>) -> (unreadable: [String], readable: [String]) {
        (found.keys.filter { said[$0] == nil }.sorted(), read.filter { said[$0] != nil && found[$0] == nil }.sorted())
    }

    /// Records in History, once, each record file found unreadable that it has not been told of, and, once more, each it
    /// was told of that has since been read, or gone, to be written again from the index; decided in the transaction that
    /// records it, against what the index keeps it was told (`unreadableKey`), so another process that finds the same
    /// says nothing again. Nothing is said while the archive's folder is not there, which is no record file that cannot
    /// be read, but the archive away. Nothing is written when nothing changed. What was read is forgotten only once
    /// History has it, or has nothing to say of it: a file read again while the archive is away, or when the write
    /// fails, is said to read again the next time.
    func recordUnreadable() async throws {
        let (found, read) = (unreadable.filter { $0.key != archive.path }, readable)
        guard archiveIsThere else { return }
        let now = time.now()
        let kept = JSON.decode([String: String].self, from: try await database.meta(Self.unreadableKey)) ?? [:]
        let (unreadableNow, readableAgain) = Self.untold(said: kept, found: found, read: read)
        guard !unreadableNow.isEmpty || !readableAgain.isEmpty else {
            readable.subtract(read)
            return
        }
        try await database.writer.write { db in
            var said = JSON.decode([String: String].self,
                                   from: try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [Self.unreadableKey])) ?? [:]
            let (unreadableNow, readableAgain) = Self.untold(said: said, found: found, read: read)
            for path in unreadableNow {
                let reason = found[path] ?? ""
                said[path] = reason
                try HistoryStore.insert(db, .recordFileUnreadable, at: now,
                                        summary: "The record file \(path) cannot be read: \(reason). It is not written over; what is filed or "
                                            + "changed meanwhile is kept and written into it once it can be read",
                                        payload: UnreadableRecordFile(path: path, reason: reason))
            }
            for path in readableAgain {
                said[path] = nil
                try HistoryStore.insert(db, .recordFileReadable, at: now,
                                        summary: "The record file \(path) can be read again; what was kept meanwhile is written into it",
                                        payload: ["path": path])
            }
            guard !unreadableNow.isEmpty || !readableAgain.isEmpty else { return }
            try AppDatabase.setMeta(db, Self.unreadableKey, said.isEmpty ? nil : try JSON.string(said))
        }
        // Those read since stay, for the next time.
        readable.subtract(read)
    }
}
