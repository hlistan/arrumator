import Foundation
import GRDB

/// A document whose identifier (`Xattr.documentID`) files in more than one place of the archive carry, or that lists of
/// documents in more than one folder name, when nothing tells which is its file and which a copy: as after a folder was
/// duplicated in Finder, its list with it, while the index was lost. Neither the place where the index has the
/// document (it was itself read from one of the lists), nor an inode the index kept, nor the files' dates (a copy made
/// in Finder or by `FileManager.copyItem` keeps the creation date of its original) tells them apart. So nothing is
/// decided on a guess: the document stays at the place it was first found in, no file loses its identifier or is
/// taken in as new, the document's entry in each other list is kept as it is (`ArchiveRecords.composed`), and the user
/// is told, once in History and by `arrumatorcli doctor`, to remove the copy; the document then follows the file that is
/// left (`ArchiveReconciler`).
public struct DocumentInTwoPlaces: Sendable, Codable, Hashable {
    /// The document's number in the index.
    public var document: Int64
    /// Where files carrying its identifier, or lists naming it, were found, in the order of their paths.
    public var paths: [String]

    /// The places of `self` that still hold a file carrying `uid`: none or one means the user has removed the copies.
    func paths(stillCarrying uid: String) -> [String] {
        paths.filter { Xattr.get(Xattr.documentID, from: URL(fileURLWithPath: $0)) == uid }
    }
}

/// The documents found in two places, one row per place in `documents_in_two_places` (`v25_documentsInTwoPlaces`), so
/// every process that reads the archive's records, a rebuild, a read-back, the archive watcher and the doctor, leaves
/// them as they are until the user has removed the copy, and finds a document or a place by its key.
enum TwoPlaces {
    static let table = "documents_in_two_places"

    /// Every document found in two places, by its identifier, read in the transaction of `db`.
    static func all(_ db: Database) throws -> [String: DocumentInTwoPlaces] {
        var found: [String: DocumentInTwoPlaces] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT uid, doc_id, path FROM \(table) ORDER BY uid, path") {
            found[row["uid"], default: DocumentInTwoPlaces(document: row["doc_id"], paths: [])].paths.append(row["path"])
        }
        return found
    }

    /// The identifiers of the documents found in two places.
    static func uids(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT DISTINCT uid FROM \(table)"))
    }

    /// Where the document `uid` was found, if it is in two places.
    static func place(_ db: Database, uid: String) throws -> DocumentInTwoPlaces? {
        let rows = try Row.fetchAll(db, sql: "SELECT doc_id, path FROM \(table) WHERE uid = ? ORDER BY path", arguments: [uid])
        guard let first = rows.first else { return nil }
        return DocumentInTwoPlaces(document: first["doc_id"], paths: rows.map { $0["path"] })
    }

    /// Notes, in the transaction of `db`, that the document `uid`, named `name`, is at `paths`, besides where it was noted
    /// to be before unless `replacing`, as a walk of the whole archive does, and records it in History the first time it
    /// is found at those paths, so a read that finds it again records nothing more.
    static func note(_ db: Database, uid: String, document: Int64, name: String, paths: Set<String>, replacing: Bool,
                     at now: Date) throws {
        let before = Set(try place(db, uid: uid)?.paths ?? [])
        let after = replacing ? paths : paths.union(before)
        guard after != before else { return }
        try db.execute(sql: "DELETE FROM \(table) WHERE uid = ?", arguments: [uid])
        for path in after {
            try db.execute(sql: "INSERT INTO \(table) (uid, doc_id, path) VALUES (?, ?, ?)", arguments: [uid, document, path])
        }
        let place = DocumentInTwoPlaces(document: document, paths: after.sorted())
        try HistoryStore.insert(db, .foundInTwoPlaces, at: now, actor: .user, doc: document,
                                summary: "\(name) is in more than one place: \(place.paths.joined(separator: ", ")); remove the copy",
                                payload: place)
        Log.warning(.db, "A document is in more than one place of the archive; it stays where it was first found", ["doc": String(document)])
    }

    /// Forgets, in the transaction of `db`, that the documents `uids` were in two places.
    static func forget(_ db: Database, _ uids: some Sequence<String>) throws {
        for uid in uids { try db.execute(sql: "DELETE FROM \(table) WHERE uid = ?", arguments: [uid]) }
    }

    /// Forgets, in the transaction of `db`, the places at `path` or inside it, which are gone, and every document left in
    /// one place or none. The lists of the folders those places were in are marked, to be written without the entries
    /// they kept for those documents (`ArchiveRecords.heldEntries`).
    static func gone(_ db: Database, _ path: String) throws {
        let range: StatementArguments = [path, path + "/", path + DocumentFilter.afterSeparator]
        let places = try Row.fetchAll(db, sql: "SELECT uid, path FROM \(table) WHERE path = ? OR (path >= ? AND path < ?)", arguments: range)
        guard !places.isEmpty else { return }
        let affected = Set(places.map { $0["uid"] as String })
        for folder in Set(places.map { (($0["path"] as String) as NSString).deletingLastPathComponent }) {
            try ArchiveRecords.mark(db, .documents(directory: folder))
        }
        try db.execute(sql: "DELETE FROM \(table) WHERE path = ? OR (path >= ? AND path < ?)", arguments: range)
        for uid in affected where try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE uid = ?", arguments: [uid]) ?? 0 < 2 {
            try forget(db, [uid])
        }
    }
}
