import Foundation
import GRDB

/// Applies the changes `ArchiveWatcher` reports, deciding what each is from what the disk and the index hold when it is
/// applied, so a change applied twice, as after a restart, does nothing more. A file is told by its identity on disk,
/// its volume and inode (`FileOnDisk`), and by the identifier the app stores on it, never by how a path is spelled: a
/// document the user moved or renamed is followed to where it is now, one put back is in the archive again as it was, a
/// file the archive does not know, a copy of a document included, is read and labelled where it is, and a document whose
/// file is gone is marked missing, unless the archive's folder itself is not there.
public actor ArchiveReconciler {
    private let services: PipelineServices
    private let coordinator: IngestCoordinator
    /// Called before each change is applied: what a test does there, a stop or a failure, is what could happen then. Set by
    /// tests only.
    private var beforeApplying: (@Sendable (ArchiveChange) async throws -> Void)?
    /// What the disk is asked; a test gives another (`use(_:)`).
    private var disk = ArchiveDisk.disk
    /// How many times each change that could not be applied has failed, by its path, across starts (a JSON object).
    static let attemptsKey = "archive_change_attempts"

    public init(services: PipelineServices, coordinator: IngestCoordinator) {
        self.services = services
        self.coordinator = coordinator
    }

    func setBeforeApplying(_ hook: (@Sendable (ArchiveChange) async throws -> Void)?) {
        beforeApplying = hook
    }

    func use(_ disk: ArchiveDisk) {
        self.disk = disk
    }

    /// Applies `changes` in order, and returns whether every one was applied. One that fails is logged, and the next is
    /// applied; whoever reported them is not to take them as applied, so that what failed is applied again at the next
    /// start (`ArchiveWatcher.applied`). A change is tried so at most `ingest.maxAttempts` times, counted across starts by
    /// its path, and then given up, as applied; History says so when it first fails and when it is given up. Throws only
    /// `CancellationError`, when the task is cancelled, as the app stopping cancels it: what is not applied then is
    /// reported again at the next start.
    @discardableResult
    public func apply(_ changes: [ArchiveChange]) async throws -> Bool {
        let batch = Batch(root: services.archive, changes: changes, disk: disk)
        let earlier = await attempts()
        var attempts = earlier
        var appliedAll = true
        for change in changes {
            try Task.checkCancellation()
            do {
                try await beforeApplying?(change)
                switch change {
                case let .found(path): try await found(path, in: batch)
                case let .gone(path): try await gone(path, in: batch)
                case .recordsChanged: continue
                }
                if let key = change.attemptsKey { attempts[key] = nil }
            } catch {
                try Task.checkCancellation()
                let path = change.path ?? batch.root.path
                let key = change.attemptsKey ?? path
                let attempt = (attempts[key] ?? 0) + 1
                let givenUp = attempt >= services.config.ingest.maxAttempts
                attempts[key] = givenUp ? nil : attempt
                appliedAll = appliedAll && givenUp
                await recordFailure(of: change, at: path, error, attempt: attempt, givenUp: givenUp)
            }
        }
        if attempts != earlier {
            do { try await services.database.setMeta(Self.attemptsKey, JSON.string(attempts)) } catch {
                Log.error(.db, "Could not keep how often archive changes failed", ["error": error.localizedDescription])
            }
        }
        return appliedAll
    }

    /// How many times each change that could not be applied has failed, by its path; none when that cannot be read.
    private func attempts() async -> [String: Int] {
        do { return JSON.decode([String: Int].self, from: try await services.database.meta(Self.attemptsKey)) ?? [:] } catch {
            Log.error(.db, "Could not read how often archive changes failed", ["error": error.localizedDescription])
            return [:]
        }
    }

    /// Logs that `change` at `path` could not be applied, and says so in History the first time and when it is given up.
    private func recordFailure(of change: ArchiveChange, at path: String, _ error: any Error, attempt: Int, givenUp: Bool) async {
        Log.error(.watch, "Could not apply archive change", ["change": String(describing: change), "error": error.localizedDescription,
                                                            "attempt": String(attempt)])
        let summary = givenUp
            ? "Gave up taking in what changed at \(path) after \(attempt) attempts: \(error.localizedDescription)."
            : "Could not take in what changed at \(path): \(error.localizedDescription). It is tried again when Arrumator next starts."
        guard givenUp || attempt == 1 else { return }
        do {
            try await services.history.record(.error, summary: summary, payload: ["path": path])
        } catch {
            Log.error(.db, "Could not record an event in the history", ["event": EventKind.error.rawValue, "error": error.localizedDescription])
        }
    }

    /// A file or package at `path`. A document recorded there whose file this is, by the identifier on it or by its inode,
    /// is that document, back in the archive if it was missing. Then, by the identifier on it (`Xattr.documentID`), it is
    /// that document's file under another name, or its file moved (`isFile(of:)`); otherwise, by its inode, a document's
    /// file moved that carries no identifier of its own, as a copy whose identifier could not be taken off it does. A
    /// copy, a file with an identifier the index does not know, as from another archive, and a file with none are new to
    /// the archive (`adopt`).
    private func found(_ path: String, in batch: Batch) async throws {
        let url = URL(fileURLWithPath: path)
        // Gone since it was reported, or there only under another name: the change that says so follows, or came.
        guard batch.isThere(url), let file = batch.disk.file(url) else { return }
        let identifier = Xattr.get(Xattr.documentID, from: url)
        let recordedHere = try await services.documents.documents(atOrInside: path).filter { $0.path == path }
        // Another place of a document found in two of them, when nothing told which is the copy: left as it is until the
        // user removes the copy (`DocumentInTwoPlaces`).
        if recordedHere.isEmpty, let identifier, try await inTwoPlaces(identifier)?.paths.contains(path) == true { return }
        let here = recordedHere.first { $0.uid == identifier || (batch.keepsFileIDs && $0.inode == file.number) }
        // A document recorded here whose file this is not, as one filed here while another folder was the archive, is
        // missing: its file was another.
        for other in recordedHere where other.id != here?.id && batch.holdsAnother(than: other, identifier: identifier, file: file) {
            try await markMissing(other)
        }
        if let here {
            try await keep(here, file: file)
            return
        }
        if let identifier, let document = try await services.documents.document(uid: identifier),
           try await isFile(of: document, identifier: identifier, at: path, file: file, in: batch) { return }
        if let moved = try await movedByInode(file, at: url, in: batch) {
            try await follow(moved, to: path)
            return
        }
        try await adopt(url, identifier: identifier)
    }

    /// Whether `file`, at `path` and carrying `document`'s identifier, is that document's file, which is then followed: its
    /// own file under another name, a rename that changed only case, though another link to it changes nothing; or its
    /// file moved, as its recorded path no longer holds the identifier, unless another file found with it has the inode the
    /// document's file has, and is it. False for a copy.
    private func isFile(of document: DocumentRecord, identifier: String, at path: String, file: FileOnDisk,
                        in batch: Batch) async throws -> Bool {
        let recorded = document.url
        if batch.disk.file(recorded) == file {
            if !batch.isThere(recorded) { try await follow(document, to: path) }
            return true
        }
        if Xattr.get(Xattr.documentID, from: recorded) == identifier { return false }
        // Two files there at once never share a number, on any volume: the tiebreak between files found together holds
        // where a number may be given again later, as on exFAT.
        if let inode = document.inode, inode != file.number, batch.found(carrying: identifier, besides: path, withInode: inode) {
            return false
        }
        try await follow(document, to: path)
        return true
    }

    /// The document whose file `file`, at `url`, is by its inode, moved from where it is recorded: one in the archive whose
    /// recorded path no longer holds that file, and of its size, a package aside. Only on the archive's own volume, as
    /// inodes are numbered per volume, and one that keeps each file's ID for good: exFAT gives an inode a deletion freed
    /// to the next file made, which would be taken for the document deleted.
    private func movedByInode(_ file: FileOnDisk, at url: URL, in batch: Batch) async throws -> DocumentRecord? {
        guard batch.keepsFileIDs, file.device == batch.rootFile?.device else { return nil }
        let size = Packages.isPackage(url) ? nil : (try? FileFingerprint.of(url))?.size
        let moved = try await services.documents.documents(inode: file.number).filter { document in
            DocumentStatus.withFileInArchive.contains(document.status) && batch.disk.file(document.url) != file
                && (size.map { $0 == document.size } ?? true)
        }
        return moved.count == 1 ? moved.first : nil
    }

    /// `document`'s own file, where it is recorded: one that was missing is back. Its inode is kept as the file has it
    /// now, as saving a file anew, which many apps do, gives it another, by which it is told from its copies.
    private func keep(_ document: DocumentRecord, file: FileOnDisk) async throws {
        if document.status == .missing {
            try await follow(document, to: document.path)
            return
        }
        guard let docID = document.id, document.inode != file.number else { return }
        try await services.documents.setInode(file.number, docID: docID)
    }

    /// Follows `document` to its file at `path`. One that was missing takes back the status it had and its place in
    /// search by meaning. Another document recorded at `path` had its file replaced by this one, and is missing.
    private func follow(_ document: DocumentRecord, to path: String) async throws {
        guard let docID = document.id else { return }
        if let other = try await services.documents.document(path: path), other.id != docID { try await markMissing(other) }
        var doc = document
        let (from, oldName, returning) = (doc.path, doc.filename, doc.status == .missing)
        doc.path = path
        doc.inode = FileOnDisk(URL(fileURLWithPath: path))?.number
        if returning { doc.status = try await services.database.reader.read { db in try MissingPayload.statusBefore(db, docID: docID) } }
        doc = try await services.documents.save(doc)
        try await services.index.updateFilename(docID: docID, filename: doc.filename)
        if returning { try await restoreVector(docID) }
        let event = FileEvent.followed(from: from, named: oldName, to: path, named: doc.filename)
        try await services.history.record(event.kind, actor: .user, doc: docID, summary: event.summary, payload: event.payload)
        Log.info(.watch, "User moved document", ["doc": String(docID), "to": path])
    }

    /// Puts a document back into search by meaning, from the embedding the index kept of it, when search by meaning has
    /// been made ready.
    private func restoreVector(_ docID: Int64) async throws {
        guard let model = await services.vectors.model,
              let vector = try await services.index.embedding(docID: docID, model: model) else { return }
        await services.vectors.upsert(docID: docID, vector: vector, model: model)
    }

    /// What was at `path`, a file, a package or a folder, may be gone: each document recorded at it or inside it whose
    /// file is in the archive, and not there, is missing, as is one whose path now holds another document's file. An archive whose folder is not there, renamed or on a disk that
    /// went, has nothing missing from it. A place of a document in two places that is gone is no longer one of its places,
    /// whether the document was kept there, when it follows the file that is left, or elsewhere.
    private func gone(_ path: String, in batch: Batch) async throws {
        guard batch.archiveIsThere else { return }
        for document in try await services.documents.documents(atOrInside: path)
        where DocumentStatus.withFileInArchive.contains(document.status) && !batch.holdsFile(of: document) {
            // A document in two places whose place was removed is at the other, as the user removed the copy.
            if let other = try await inTwoPlaces(document.uid)?.paths(stillCarrying: document.uid).first {
                try await follow(document, to: other)
                continue
            }
            try await markMissing(document)
        }
        try await services.database.writer.write { db in try TwoPlaces.gone(db, path) }
    }

    /// Where the document `uid` is, if it was found in two places of the archive (`TwoPlaces`).
    private func inTwoPlaces(_ uid: String) async throws -> DocumentInTwoPlaces? {
        try await services.database.reader.read { db in try TwoPlaces.place(db, uid: uid) }
    }

    private func markMissing(_ document: DocumentRecord) async throws {
        guard let docID = document.id, DocumentStatus.withFileInArchive.contains(document.status) else { return }
        var doc = document
        doc.status = .missing
        _ = try await services.documents.save(doc)
        await services.vectors.remove(docID: docID)
        let event = FileEvent.missing(document)
        try await services.history.record(event.kind, actor: .user, doc: docID, summary: event.summary, payload: event.payload)
    }

    /// Takes a file new to the archive in, to be read and labelled where it is, unless the index has a document or a job
    /// for it already, or it is in the system folder, which holds none. An identifier on it that is not its own, a copy's
    /// or another archive's, is taken off it first, so it is not taken for the document whose identifier it carries; it
    /// is given one of its own when it is filed (`DocumentFiler`).
    private func adopt(_ url: URL, identifier: String?) async throws {
        let path = url.path
        if try await services.documents.document(path: path) != nil { return }
        if ArchiveLayout(root: services.archive, records: services.config.records, watcher: services.config.watcher).system.holds(path) { return }
        if try await services.jobs.active(path: path) != nil { return }
        if identifier != nil {
            do { try Xattr.remove(Xattr.documentID, from: url) } catch {
                Log.warning(.watch, "Could not take another document's identifier off a file put into the archive",
                            ["path": path, "error": error.localizedDescription])
            }
        }
        // A file already queued, as found by a rescan, is recorded once.
        guard try await services.jobs.enqueue(path: path, kind: .adopt).isNew else { return }
        try await services.history.record(.adopted, actor: .user, summary: "\(url.lastPathComponent) added to the archive",
                                          payload: ["path": path])
        await coordinator.wake()
    }
}

/// What History keeps of a document found missing: the status it had, which it takes again when its file is found. It
/// is written only for a document that was not filed, as every document found again was filed before it was kept.
struct MissingPayload: Sendable, Codable, Hashable {
    /// The status the document had; absent for filed.
    var status: DocumentStatus?

    /// What a missing document without a status kept had: filed.
    static let absent = DocumentStatus.filed

    init(had: DocumentStatus) {
        status = had == Self.absent ? nil : had
    }

    /// The status the document had.
    var had: DocumentStatus { status ?? Self.absent }

    /// The status document `docID`, missing, had when its file went, as the History event that marked it missing keeps
    /// it, read in the transaction of `db`; filed when no such event is the last of its file's, as for one an earlier
    /// version found missing.
    static func statusBefore(_ db: Database, docID: Int64) throws -> DocumentStatus {
        let last = try EventRecord.filter(Column("doc_id") == docID)
            .filter([EventKind.missing, .userMoved, .userRenamed].map(\.rawValue).contains(Column("kind")))
            .order(Column("at").desc, Column("id").desc).fetchOne(db)
        guard let last, last.kind == .missing else { return absent }
        return JSON.decode(MissingPayload.self, from: last.payloadJson)?.had ?? absent
    }
}

/// What History records of a document whose file went from the archive or was found again, as the user moved,
/// renamed, removed or put it back: the same whether the archive watcher saw it (`ArchiveReconciler`) or a rebuild
/// found it (`ArchiveRecords.locateDocuments`).
struct FileEvent {
    let kind: EventKind
    let summary: String
    let payload: any Encodable & Sendable

    /// `document`'s file went: the status it had is kept, to be taken again when its file is found.
    static func missing(_ document: DocumentRecord) -> FileEvent {
        FileEvent(kind: .missing, summary: "\(document.filename) was removed from the archive", payload: MissingPayload(had: document.status))
    }

    /// A document's file, `oldName` at `from`, is at `path` as `newName`: back where it was, renamed, or moved.
    static func followed(from: String, named oldName: String, to path: String, named newName: String) -> FileEvent {
        let sameDirectory = (from as NSString).deletingLastPathComponent == (path as NSString).deletingLastPathComponent
        let (kind, summary): (EventKind, String) = if from == path {
            (.userMoved, "\(newName) is back in the archive")
        } else if sameDirectory {
            (.userRenamed, "\(oldName) → \(newName)")
        } else {
            (.userMoved, "\(oldName) moved to \(path)")
        }
        return FileEvent(kind: kind, summary: summary, payload: ["from": from, "to": path])
    }
}

extension ArchiveReconciler {
    /// What applying one batch of changes knows of the disk: the archive's folder, and the identifier on each file found.
    struct Batch: Sendable {
        let root: URL
        /// The archive's folder as the disk names it, and the folder itself.
        let rootOnDisk: String?
        let rootFile: FileOnDisk?
        /// The paths of the files found, by the identifier each carries.
        let carriers: [String: [String]]

        /// What the disk is asked.
        let disk: ArchiveDisk
        /// Whether the archive's volume keeps each file's ID for good, so an inode tells a file (`ArchiveDisk.keepsFileIDs`).
        let keepsFileIDs: Bool

        init(root: URL, changes: [ArchiveChange], disk: ArchiveDisk) {
            self.root = root.standardizedFileURL
            self.disk = disk
            rootOnDisk = root.folderOnDisk.path
            rootFile = disk.file(root)
            keepsFileIDs = disk.keepsFileIDs(root)
            var carriers: [String: [String]] = [:]
            for case let .found(path) in changes {
                if let identifier = Xattr.get(Xattr.documentID, from: URL(fileURLWithPath: path)) { carriers[identifier, default: []].append(path) }
            }
            self.carriers = carriers
        }

        /// Whether what `url` names is there under that very name (`FileOnDisk.isThere`).
        func isThere(_ url: URL) -> Bool {
            FileOnDisk.isThere(url, inside: root, rootOnDisk: rootOnDisk)
        }

        /// Whether the archive's folder is there now.
        var archiveIsThere: Bool { FileManager.default.fileExists(atPath: root.path) }

        /// Whether `document`'s recorded path holds its file: a file is there, and does not hold another document's,
        /// by the identifier on it or, where the volume keeps file IDs, by its inode.
        func holdsFile(of document: DocumentRecord) -> Bool {
            let url = document.url
            guard FileManager.default.fileExists(atPath: url.path), let file = disk.file(url) else { return false }
            return !holdsAnother(than: document, identifier: Xattr.get(Xattr.documentID, from: url), file: file)
        }

        /// Whether `file`, carrying `identifier`, at `document`'s recorded path, is another document's: it carries
        /// another identifier, or, carrying none, has another inode than the document's on a volume that keeps file IDs.
        func holdsAnother(than document: DocumentRecord, identifier: String?, file: FileOnDisk) -> Bool {
            if let identifier { return identifier != document.uid }
            guard keepsFileIDs, let inode = document.inode else { return false }
            return inode != file.number
        }

        /// Whether a file found with this batch, other than the one at `path`, carries `identifier` and has the inode `inode`.
        func found(carrying identifier: String, besides path: String, withInode inode: Int64) -> Bool {
            (carriers[identifier] ?? []).contains { $0 != path && disk.file(URL(fileURLWithPath: $0))?.number == inode }
        }
    }
}

extension ArchiveChange {
    /// The path the change is at; none for record files changed or the archive's folder replaced.
    var path: String? {
        switch self {
        case let .found(path), let .gone(path): path
        case .recordsChanged: nil
        }
    }

    /// The change, as the attempts at it are counted (`ArchiveReconciler.attemptsKey`): a file found and a path gone are
    /// two changes, though at one path.
    var attemptsKey: String? {
        switch self {
        case let .found(path): "found " + path
        case let .gone(path): "gone " + path
        case .recordsChanged: nil
        }
    }
}
