import Foundation
import GRDB

/// What History keeps of a document put back (`ReviewActions.putBack`): the removal it undoes, the document, the file
/// in the Trash and where it went, both as the disk spells them.
public struct PutBackPayload: Sendable, Codable, Hashable {
    /// The `documentRemoved` event this put back.
    public var removal: Int64
    public var document: Int64
    /// The number the document had when it was removed, written only when it came back under another, as its own was
    /// taken meanwhile (§4.2: written only when it differs from what its absence has always meant).
    public var removedAs: Int64?
    public var from: String
    public var to: String
    /// True when the file came back across volumes as a checked copy and its original stays in the Trash; written only then.
    public var copied: Bool?

    public init(removal: Int64, document: Int64, removedAs: Int64?, from: String, to: String, copied: Bool?) {
        self.removal = removal
        self.document = document
        self.removedAs = removedAs
        self.from = from
        self.to = to
        self.copied = copied
    }
}

/// Why a removed document is not put back, naming it by its file as the app shows it, and what the user can do.
public enum PutBackError: Error, LocalizedError, Equatable {
    /// No removal of this number is in this archive's History.
    case notRemoved(document: Int64)
    /// The History event of this number is no removal that can be put back: there is none, it is of another kind, or its
    /// payload cannot be read.
    case noSuchRemoval(event: Int64)
    /// The removal recorded no place in the Trash: its file was not there, or the Trash did not say where it put it.
    case nothingInTrash(name: String)
    /// The place recorded for the file is not in the Trash the app uses, so nothing is taken from it: History is a record
    /// file a person can edit, and what it names is not trusted to name a file to move.
    case notInTrash(name: String, trashed: String)
    /// Nothing is at the place the Trash was recorded to hold the file, as when it was emptied or the file taken out.
    case noLongerInTrash(name: String, trashed: String)
    /// The item at that place is not the document's file: a link, another identifier, or another size or content.
    case notItsFile(name: String, trashed: String)
    /// The removal was put back already.
    case alreadyPutBack(name: String)
    /// A document with the same identity is in the index; `other` is its file.
    case sameDocumentThere(name: String, other: String)
    /// The removal was recorded by a release before it kept the document's entry, so what the document was is not known.
    case removedBeforeEntriesKept(name: String)
    /// The folder its file was in is neither inside the archive nor inside Incoming as they are now.
    case outsideFolders(name: String, folder: String)
    /// The archive's folder is not there, as on a disk not connected: nothing is put back into it.
    case archiveNotThere(String)
    /// The file could not be moved out of the Trash, for the reason given; it stays there.
    case notMoved(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .notRemoved(number):
            "Document \(number) was not removed in this archive, so there is nothing to put back; arrumatorcli history shows what was removed"
        case let .noSuchRemoval(event):
            "History holds no removal numbered \(event) that can be put back; arrumatorcli history shows what was removed"
        case let .notInTrash(name, trashed):
            "“\(name)” cannot be put back: \(trashed) is not in the Trash, so it is left where it is"
        case let .nothingInTrash(name):
            "“\(name)” cannot be put back: there is nothing in the Trash to put back, as its file was not there when it was removed"
        case let .noLongerInTrash(name, trashed):
            "“\(name)” cannot be put back: it is no longer in the Trash at \(trashed), as when the Trash was emptied or the file taken out"
        case let .notItsFile(name, trashed):
            "“\(name)” cannot be put back: what is in the Trash at \(trashed) is not its file, so it is left there"
        case let .alreadyPutBack(name): "“\(name)” was already put back"
        case let .sameDocumentThere(name, other):
            "“\(name)” cannot be put back: the archive already holds that document, as “\(other)”"
        case let .removedBeforeEntriesKept(name):
            "“\(name)” was removed by an earlier version of Arrumator, which did not keep what it needs to be put back; "
                + "put its file into Incoming from the Trash to have it read as a new document"
        case let .outsideFolders(name, folder):
            "“\(name)” cannot be put back: its folder \(folder) is inside neither the archive nor Incoming as they are now"
        case let .archiveNotThere(path):
            RecordsError.archiveNotThere(path).errorDescription
        case let .notMoved(name, reason): "“\(name)” could not be put back: its file would not leave the Trash (\(reason)), so it stays there"
        }
    }
}

/// A removal as History records it (`ReviewActions.remove`).
struct Removal: Sendable {
    let eventID: Int64
    let payload: RemovedPayload

    /// Document-facing name: the file as the app showed it (the entry's), else, for a removal an earlier release recorded,
    /// the name its file had.
    var name: String { payload.entry?.file ?? URL(fileURLWithPath: payload.from).lastPathComponent }

    /// The removals of document `number`, newest first, in the transaction of `db`.
    static func all(_ db: Database, document number: Int64) throws -> [Removal] {
        try EventRecord.filter(Column("kind") == EventKind.documentRemoved.rawValue)
            .filter(sql: "json_valid(payload_json) AND json_extract(payload_json, '$.document') = ?", arguments: [number])
            .order(Column("at").desc, Column("id").desc).fetchAll(db).compactMap(Self.init)
    }

    /// The removal recorded by `event`; nil for an event that is no removal or whose payload cannot be read.
    init?(_ event: EventRecord) {
        guard event.kind == .documentRemoved, let id = event.id,
              let payload = JSON.decode(RemovedPayload.self, from: event.payloadJson) else { return nil }
        (eventID, self.payload) = (id, payload)
    }

    /// Whether a put-back of removal `eventID` is recorded, in the transaction of `db`.
    static func isPutBack(_ db: Database, _ eventID: Int64) throws -> Bool {
        try EventRecord.filter(Column("kind") == EventKind.documentPutBack.rawValue)
            .filter(sql: "json_valid(payload_json) AND json_extract(payload_json, '$.removal') = ?", arguments: [eventID])
            .fetchCount(db) > 0
    }
}

/// The one rule of whether a removal can be put back, which the action applies and the History listing applies to say it
/// before it is asked: what the index and the record show (`checked`), read in a transaction, and what the disk shows
/// (`onDisk`), never read inside one, as it waits on whatever the path names. What only the content shows, its checksum
/// (`reading`), only the action sees.
enum PutBackRule {
    /// What a removal records, once nothing in the index refuses it: the document's entry, the place in the Trash, and the
    /// folder its file was in, as the root it belongs to (the archive or Incoming) and the path below it.
    struct Checked: Sendable {
        let entry: DocumentEntry
        let trashed: String
        let root: URL
        /// The folder the file was in, relative to `root`; empty for `root` itself.
        let folder: String
    }

    /// Whether `removal` can be put back as far as the index and its record show, in the transaction of `db`.
    static func checked(_ db: Database, _ removal: Removal, archive: URL, incoming: URL) throws -> Result<Checked, PutBackError> {
        let name = removal.name
        guard let entry = removal.payload.entry else { return .failure(.removedBeforeEntriesKept(name: name)) }
        guard let trashed = removal.payload.trashed else { return .failure(.nothingInTrash(name: name)) }
        if let refusal = try inIndex(db, removal, entry: entry) { return .failure(refusal) }
        guard ArchiveRecords.isFolder(archive) else { return .failure(.archiveNotThere(archive.standardizedFileURL.path)) }
        let from = removal.payload.from
        if let folder = archive.relativeFolder(of: from) {
            return .success(Checked(entry: entry, trashed: trashed, root: archive, folder: folder))
        }
        if let folder = incoming.relativeFolder(of: from) {
            return .success(Checked(entry: entry, trashed: trashed, root: incoming, folder: folder))
        }
        return .failure(.outsideFolders(name: name, folder: URL(fileURLWithPath: from).deletingLastPathComponent().path))
    }

    /// What the index alone refuses, in the transaction of `db`: the removal put back already, and a document of the same
    /// identity there. What can change between the look and the write that records the put-back, so the write asks it again.
    static func inIndex(_ db: Database, _ removal: Removal, entry: DocumentEntry) throws -> PutBackError? {
        if try Removal.isPutBack(db, removal.eventID) { return .alreadyPutBack(name: removal.name) }
        if let other = try DocumentRecord.filter(Column("uid") == entry.uid).fetchOne(db) {
            return .sameDocumentThere(name: removal.name, other: other.filename)
        }
        return nil
    }

    /// Whether what is at the place recorded in the Trash can be the document's file, as the disk shows it without reading
    /// its content: the place is in `trash`, which is asked before anything there is touched, and holds an item, not a
    /// link, carrying no other document's identifier and of its size; a package is weighed no further than `packageItems`
    /// items. Nil when nothing refuses it.
    @concurrent static func onDisk(_ removal: Removal, _ checked: Checked, trash: any Trashing, packageItems: Int) async -> PutBackError? {
        let (name, trashed) = (removal.name, checked.trashed)
        let url = URL(fileURLWithPath: trashed)
        guard trash.holds(url) else { return .notInTrash(name: name, trashed: trashed) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: trashed) else {
            return .noLongerInTrash(name: name, trashed: trashed)
        }
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { return .notItsFile(name: name, trashed: trashed) }
        // Another document's identifier is another document's file. One with none, as a file left in Incoming never filed, or
        // one a copy or a synchronisation stripped in the archive, is what `remove` takes as the document's own, so it is
        // known by its size and content alone, which the action hashes.
        let identifier = Xattr.get(Xattr.documentID, from: url)
        guard identifier == nil || identifier == checked.entry.uid else { return .notItsFile(name: name, trashed: trashed) }
        do {
            return try FileFingerprint.of(url, packageItems: packageItems).size == checked.entry.size ? nil : .notItsFile(name: name, trashed: trashed)
        } catch {
            // Taken out meanwhile, or not to be weighed (a package of too many items, a file that cannot be read).
            return FileManager.default.fileExists(atPath: trashed) ? .notItsFile(name: name, trashed: trashed) : .noLongerInTrash(name: name, trashed: trashed)
        }
    }

    /// The fingerprint and checksum of the file at `trashed`, as the action takes them before the write that moves it. A
    /// file taken out of the Trash meanwhile, as by a put-back at the same time, at whichever step it is found gone, is
    /// `PutBackError.noLongerInTrash`, as the rule says it; anything else, such as a stop, is thrown as it is.
    @concurrent static func reading(_ trashed: String, name: String) async throws -> (fingerprint: FileFingerprint, sha256: String) {
        let url = URL(fileURLWithPath: trashed)
        do {
            let fingerprint = try FileFingerprint.of(url)
            return (fingerprint, try HashService.sha256(of: url))
        } catch {
            if !FileManager.default.fileExists(atPath: trashed) { throw PutBackError.noLongerInTrash(name: name, trashed: trashed) }
            throw error
        }
    }
}
