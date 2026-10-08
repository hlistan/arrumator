import Foundation
import GRDB
import Synchronization

/// What the user changes of a document's labels: the labels added and those taken off, never the whole set as a card
/// last showed it, so that a change made meanwhile, by the user or by a reading, is kept.
public struct LabelEdit: Sendable, Hashable {
    public var adding: [DocumentLabel]
    public var removing: [DocumentLabel]

    public init(adding: [DocumentLabel] = [], removing: [DocumentLabel] = []) {
        self.adding = adding
        self.removing = removing
    }

    /// `labels` with this change made: those taken off gone, those added after the rest, each kept as
    /// `DocumentLabel.normalized` keeps it, once. One taken off is the label its kind keeps or the one written so, as an
    /// earlier reading may have given a label in a form its kind no longer keeps. One added of a single-valued kind
    /// (`LabelKind.isSingle`) takes the place of the one there, in its place, from the app and the command line alike,
    /// and only when it is written otherwise (`DocumentLabel.distinctKey`): the one there given again changes nothing. Of
    /// several added of such a kind, the first.
    public func applied(to labels: [DocumentLabel]) -> [DocumentLabel] {
        let removed = Set(removing.flatMap { label in
            [DocumentLabel.normalized(label.value, kind: label.kind), DocumentLabel(kind: label.kind, value: DocumentLabel.oneLine(label.value))]
                .compactMap { $0 }
        })
        var kept = labels.filter { !removed.contains($0) }
        var appended: [DocumentLabel] = []
        var single = Set<LabelKind>()
        for label in adding.compactMap({ DocumentLabel.normalized($0.value, kind: $0.kind) }) {
            if label.kind.isSingle {
                guard single.insert(label.kind).inserted else { continue }
                if let place = kept.firstIndex(where: { $0.kind == label.kind }) {
                    if kept[place].distinctKey != label.distinctKey { kept[place] = label }
                    continue
                }
            }
            appended.append(label)
        }
        return (kept + appended).distinct()
    }
}

/// What the user can do with a document from its card, beside correcting its name and labels.
public enum DocumentAction: String, Sendable, Hashable, CaseIterable {
    case undo, confirm, hold, readAgain
    /// Move its file to the Trash and take it out of the archive (`ReviewActions.remove`).
    case remove
}

/// What History keeps of a document removed (`ReviewActions.remove`): its number, which the index no longer has, where
/// its file was, as the disk spells it, and where the Trash put it; nil when it had no file to move, as one missing.
public struct RemovedPayload: Sendable, Codable, Hashable {
    public var document: Int64
    public var from: String
    public var trashed: String?
}

/// What a document's card offers, decided where the document is: the actions in the order they are shown, whether it
/// was left in Incoming not filed, which its card says, with what to do, and when the user confirmed it as it is, which
/// its card says too.
public struct DocumentChoices: Sendable, Hashable {
    public var actions: [DocumentAction]
    public var notFiled: Bool
    /// When the user confirmed the filed document as it is (`ReviewActions.confirm`), if nothing has read, corrected,
    /// undone, renamed or moved it since; nil otherwise.
    public var confirmed: Date?

    public init(actions: [DocumentAction], notFiled: Bool, confirmed: Date? = nil) {
        self.actions = actions
        self.notFiled = notFiled
        self.confirmed = confirmed
    }
}

/// What the user does with a document: confirm it, correct its name or labels, read it again, leave it for later,
/// undo its filing, remove it. Every action is recorded in the history.
public struct ReviewActions: Sendable {
    public let services: PipelineServices
    public let coordinator: IngestCoordinator

    public init(services: PipelineServices, coordinator: IngestCoordinator) {
        self.services = services
        self.coordinator = coordinator
    }

    private func document(_ id: Int64) async throws -> DocumentRecord {
        guard let d = try await services.documents.document(id: id) else { throw IngestError.documentNotFound(id) }
        return d
    }

    /// What `document`'s card offers, by its status and by where its file is: a document left in Incoming (failed, not
    /// filed) can be read again or left for later, never confirmed as filed or undone, as it is in no archive. One filed
    /// and confirmed as it is (`confirmation`) is not offered to be confirmed again, and its card says when it was.
    public func choices(for document: DocumentRecord) async throws -> DocumentChoices {
        let inArchive = services.isInArchive(document)
        var confirmed: Date?
        if document.status == .filed, inArchive, let id = document.id {
            confirmed = try await services.database.reader.read { db in try Self.confirmation(db, docID: id) }
        }
        var actions: [DocumentAction] = switch document.status {
        case .filed: inArchive ? (confirmed == nil ? [.undo, .confirm] : [.undo]) : []
        case .needsReview, .failed: inArchive ? [.hold, .readAgain, .confirm] : [.hold, .readAgain]
        case .held, .undone: [.readAgain]
        case .arrived, .processing, .duplicate, .missing: []
        }
        // Any document can be removed, but one being read in, which its reading files.
        if ![.arrived, .processing].contains(document.status) { actions.append(.remove) }
        // Its reading in not ended, as in the instant between its filing and its job's end, it is neither undone, left
        // for later nor removed (`undo`, `hold`, `remove`), nor read again where that reading's job is
        // (`PipelineServices.queueReadingAgain`), so none of those is offered; nor removed while reading it again moves
        // its file (`remove`). The card asks again as the worker moves on.
        if let id = document.id, !actions.isEmpty {
            let claims = services.claims
            let (readIn, here, moving) = try await services.database.reader.read { db in
                (try JobStore.isReadIn(db, docID: id), try JobStore.isReadIn(db, docID: id, at: document.path),
                 try JobStore.plannedMove(db, docID: id, claims: claims)?.held == true)
            }
            if readIn { actions.removeAll { [.undo, .hold, .remove].contains($0) } }
            if here { actions.removeAll { $0 == .readAgain } }
            if moving { actions.removeAll { $0 == .remove } }
        }
        return DocumentChoices(actions: actions, notFiled: !inArchive && document.status == .failed, confirmed: confirmed)
    }

    /// The events that change what a confirmation was of: a reading, a filing, a correction, an undo, and a change to its
    /// name or place made outside the app, as a rename or a move in Finder, or its file going and coming back.
    private static let confirmable: [EventKind] = [.markedCorrect, .analysed, .filed, .needsReview, .corrected, .undone, .retry, .error,
                                                   .userRenamed, .userMoved, .missing, .adopted]

    /// When the user last confirmed document `docID` as it is, read in the transaction of `db`: the time of its
    /// `markedCorrect` event when no reading, filing, correction, undo or change to its name or place has come after
    /// it; nil otherwise. History is the
    /// record of it, so a rebuild keeps it.
    static func confirmation(_ db: Database, docID: Int64) throws -> Date? {
        let last = try EventRecord.filter(Column("doc_id") == docID)
            .filter(confirmable.map(\.rawValue).contains(Column("kind")))
            .order(Column("at").desc, Column("id").desc).fetchOne(db)
        return last?.kind == .markedCorrect ? last?.at : nil
    }

    /// Confirms the document as it is: its name and labels are right. One waiting for the user is filed. One already
    /// filed and confirmed, with nothing read or changed since (`confirmation`), is left as it is and nothing is recorded
    /// again: decided in the transaction that would record it.
    public func confirm(_ docID: Int64) async throws {
        let services = services
        let now = services.time.now()
        try await services.database.writer.write { db in
            guard var doc = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
            guard [.filed, .needsReview, .failed].contains(doc.status), services.isInArchive(doc) else {
                throw IngestError.notInArchive(docID, .confirm)
            }
            var analysis = doc.analysis ?? DocumentAnalysis()
            if doc.status == .filed, analysis.problems.isEmpty, try Self.confirmation(db, docID: docID) != nil { return }
            let read = doc
            analysis.problems = []
            doc.status = .filed
            doc.analysisJson = try JSON.string(analysis)
            doc.updatedAt = now
            try doc.updateChanges(db, from: read)
            try HistoryStore.insert(db, .markedCorrect, at: now, actor: .user, doc: docID, summary: "Confirmed \(doc.filename)")
        }
    }

    /// Reads the document again from the start, as after changing models, from its file, and files it under the name the
    /// model gives: where it is in the archive, found as it was until then, or, for one back in Incoming, at the top of
    /// the archive. It keeps its tags, which its row in the queue shows, and one in a folder in Incoming is given that
    /// folder's too (`PipelineServices.queueReadingAgain`), and History records it when it queues the reading, as in
    /// place of its turn in reading every document again, or of reading its text again after a rebuild (both give way,
    /// `JobRecord.givesWay`): not while another reading of it waits or is under way at its file, an earlier Read
    /// Again's, an exact copy's, or its reading in before that has filed it, which it is read with. One its reading in
    /// has filed, before that reading ends, is read once it has (`JobStore.nextDue`), but one filed where its reading in
    /// is, as a file put into the archive, is refused until then (`IngestError.beingReadIn`).
    public func retry(_ docID: Int64) async throws {
        try await services.queueReadingAgain(docID, settings: await services.settings.current)
        await coordinator.wake()
    }

    /// Reads every document the model has not labelled yet again (`retry`), as `arrumatorcli labels unlabelled` asks:
    /// one with no file to read, as one missing, is left out, as there is nothing to read again, and so is one whose
    /// reading in has not ended where it is, which is left to it (`IngestError.beingReadIn`). The documents queued.
    public func retryUnlabelled() async throws -> [Int64] {
        var ids: [Int64] = []
        for id in try await services.documents.unlabelled() {
            do { try await retry(id) } catch IngestError.cannotReadAgain, IngestError.beingReadIn { continue }
            ids.append(id)
        }
        return ids
    }

    /// Reads every document of the archive again, as `retry` reads one, with the profile in use, after every file that
    /// arrives meanwhile (`PipelineServices.queueReadingAllAgain`): what changing models, or a better Arrumator, is for.
    /// The documents queued.
    @discardableResult
    public func retryAll() async throws -> [Int64] {
        let queued = try await services.queueReadingAllAgain(settings: await services.settings.current)
        await coordinator.wake()
        return queued
    }

    /// Keeps the document where it is; the watcher and queue leave it alone, and a reading of it again under way changes
    /// nothing of it (`JobStore.cancelReadingAgain`), decided with the change and recorded in History with it. A document
    /// still being read in, as its file has just come or it is read again from Incoming, is refused
    /// (`IngestError.beingReadIn`), as the app offers it no such choice (`choices`): its reading files it.
    public func hold(_ docID: Int64) async throws {
        let now = services.time.now()
        try await services.database.writer.write { db in
            guard let read = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
            guard try !JobStore.isReadIn(db, docID: docID) else { throw IngestError.beingReadIn(docID, name: read.filename) }
            var held = read
            held.status = .held
            held.updatedAt = now
            try held.updateChanges(db, from: read)
            try JobStore.cancelReadingAgain(db, docID: docID, at: now)
            try HistoryStore.insert(db, .needsReview, at: now, actor: .user, doc: docID, summary: "Left for later")
        }
    }

    /// Moves a document in the archive back to Incoming, held, so it is not filed again automatically. Only a document
    /// kept in the archive as itself (`DocumentStatus.inArchive`, its file in the archive) is undone: one already undone,
    /// or left in Incoming, is refused (`IngestError.notInArchive`) and its file left as it is. Incoming may be on another
    /// volume than the archive; the move is then a copy checked against the document's hash before the archive's file
    /// goes to the Trash (`FileOperations`), never a delete, and a file the Trash will not take stays where it is, undone
    /// in nothing. History records where the file was and went as the disk spells both (`URL.spelledOnDisk`), the one
    /// form a path in Incoming is recorded in. A document whose reading in has not ended, as in the instant between its
    /// filing and its job's end, is refused (`IngestError.beingReadIn`), as leaving it for later is: that reading would
    /// file it again. No such reading begins for a document already in the archive, so the look before the move holds.
    public func undo(_ docID: Int64) async throws {
        var doc = try await document(docID)
        guard DocumentStatus.inArchive.contains(doc.status), services.isInArchive(doc) else { throw IngestError.notInArchive(docID, .undo) }
        guard try await !services.database.reader.read({ db in try JobStore.isReadIn(db, docID: docID) }) else {
            throw IngestError.beingReadIn(docID, name: doc.filename)
        }
        let settings = await services.settings.current
        guard FileManager.default.fileExists(atPath: doc.path) else { throw IngestError.sourceMissing(doc.path) }
        let from = doc.url.spelledOnDisk.path
        let placer = services.filer.placer
        // Spelled as the watcher and `enqueue` spell a path in Incoming, so a rescan finds the undone document there.
        let incoming = settings.incomingURL.folderOnDisk
        let (destination, collision) = try placer.builder.uniqueDestination(directory: incoming, filename: doc.originalFilename)
        // The archive's watcher names what changes in it under the archive as the runtime names it, as `doc.path` does.
        await services.filer.registry.expect([doc.path, destination.path])
        _ = try placer.operations.move(doc.url, to: destination, within: incoming, collision: collision, expectedSHA256: doc.sha256,
                                       fingerprint: nil)
        // What the file is in Incoming, which a copy to another volume changes, so a rescan knows it for this document.
        let moved = try? FileFingerprint.of(destination)
        let now = services.time.now()
        // A reading of it again under way changes nothing of it from now on (`JobStore.cancelReadingAgain`).
        doc = try await services.database.writer.write { db in
            guard let read = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
            var undone = read
            undone.path = destination.path
            undone.status = .undone
            if let moved { (undone.size, undone.inode, undone.fileMtime) = (moved.size, moved.inode, moved.modified) }
            undone.updatedAt = now
            try undone.updateChanges(db, from: read)
            try JobStore.cancelReadingAgain(db, docID: docID, at: now)
            return undone
        }
        try await services.index.updateFilename(docID: docID, filename: destination.lastPathComponent)
        await services.vectors.remove(docID: docID)
        try await services.history.record(.undone, actor: .user, doc: docID, summary: "\(from) → Incoming",
                                          payload: ["from": from, "to": destination.path])
    }

    /// Removes the document: its file goes to the Trash (`Trashing`), never deleted, wherever it is, in the archive or
    /// back in Incoming, and the document leaves the index, its labels, text, meaning, place in tasks' sets and the work
    /// queued for it with it, and its record file's entry (`documents_record_delete`), with the History event that says
    /// where its file was and went (`RemovedPayload`). All of it is decided and done in one write, which holds the
    /// index's lock, so two removals of one document, from the app and a command, move its file and record it once, and
    /// the move and its record are made in a task of their own, which a stop does not cut between them. Only the file
    /// that is the document's is moved: one at its path that carries another document's identifier is not, and the
    /// document, whose file is then not there, as one missing, only leaves the index. A file the Trash refuses stays
    /// where it is, and so does the document: nothing is removed (`IngestError.notTrashed`); and a file in the Trash
    /// whose removal then fails to be recorded or committed comes back, so the document is as it was. Only a crash
    /// between the two leaves the file in the Trash and the document in the index, which the next start marks missing,
    /// as one whose file the user took away. A document whose reading in has not ended is refused
    /// (`IngestError.beingReadIn`), as that reading would file it again, and so is one a worker reading it again holds
    /// while it may be moving its file (`IngestError.beingMoved`), as the file would be filed with no document; one whose
    /// move failed or was cut off, and waits to be tried again, is removed with its file where the move left it
    /// (`JobStore.plannedMove`). A reading of it again otherwise under way loses its claim with its job, which goes with
    /// the document, so it keeps nothing and moves nothing. What History keeps of it.
    @discardableResult
    public func remove(_ docID: Int64) async throws -> RemovedPayload {
        let known = try await document(docID)
        let claims = services.claims
        let planned = try await services.database.reader.read { db in try JobStore.plannedMove(db, docID: docID, claims: claims)?.path }
        // The archive's watcher is told, so the file leaving is no change of the user's to follow.
        await services.filer.registry.expect([known.path] + [planned].compactMap { $0 })
        let (database, trash, now) = (services.database, services.trash, services.time.now())
        let moved = TrashedFile()
        let removed: RemovedPayload
        do {
            removed = try await Task {
                try await database.writer.write { db in
                    guard let doc = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
                    guard try !JobStore.isReadIn(db, docID: docID) else { throw IngestError.beingReadIn(docID, name: doc.filename) }
                    let move = try JobStore.plannedMove(db, docID: docID, claims: claims)
                    guard move?.held != true else { throw IngestError.beingMoved(docID, name: doc.filename) }
                    let file = Self.ownFile(of: doc, movedTo: move?.path)
                    let from = file?.spelledOnDisk.path ?? doc.path
                    var trashed: URL?
                    if let file {
                        do { trashed = try trash.trash(file) } catch { throw IngestError.notTrashed(from, reason: error.localizedDescription) }
                        moved.keep(trashed.map { (trashed: $0, from: file) })
                    }
                    _ = try DocumentRecord.deleteOne(db, key: docID)
                    let removed = RemovedPayload(document: docID, from: from, trashed: trashed?.spelledOnDisk.path)
                    try HistoryStore.insert(db, .documentRemoved, at: now, actor: .user,
                                            summary: "Removed “\(doc.filename)”" + (file != nil ? "; its file is in the Trash" : "; its file was not there"),
                                            payload: removed)
                    return removed
                }
            }.value
        } catch {
            // Not removed after all, as its record failed or did not commit: its file comes back from the Trash.
            if let (trashed, from) = moved.kept {
                do { try FileManager.default.moveItem(at: trashed, to: from) } catch let back {
                    Log.error(.fileops, "Could not bring a file back from the Trash", ["path": trashed.path, "error": back.localizedDescription])
                }
            }
            throw error
        }
        await services.vectors.remove(docID: docID)
        return removed
    }

    /// The document's own file: at its path, unless the file there carries another document's identifier, or else where
    /// reading it again moved it before recording the move (`movedTo`), carrying its identifier; nil when neither.
    private static func ownFile(of doc: DocumentRecord, movedTo planned: String?) -> URL? {
        if FileManager.default.fileExists(atPath: doc.path), (Xattr.get(Xattr.documentID, from: doc.url) ?? doc.uid) == doc.uid { return doc.url }
        guard let planned, FileManager.default.fileExists(atPath: planned) else { return nil }
        let url = URL(fileURLWithPath: planned)
        return Xattr.get(Xattr.documentID, from: url) == doc.uid ? url : nil
    }

    /// The file a removal put in the Trash, and where it was, kept past the transaction, so it is put back should the
    /// transaction then fail, at its commit too.
    private final class TrashedFile: Sendable {
        private let file = Mutex<(trashed: URL, from: URL)?>(nil)
        var kept: (trashed: URL, from: URL)? { file.withLock { $0 } }
        func keep(_ moved: (trashed: URL, from: URL)?) { file.withLock { $0 = moved } }
    }

    /// Applies the user's corrections: a new file name renames the file where it is, and `labels`, when given, are
    /// applied to the labels the document has when the change is made (`LabelEdit.applied(to:)`), read and written in
    /// one transaction with the event that records them, so changes made one after another, such as two labels taken off
    /// a card, each keep what the other did. A label of another kind than a tag labels a document not labelled yet; a
    /// tag, the user's own, does not (`DocumentLabel.stored`). A label added that is no label of its kind
    /// (`LabelError.refusal(of:)`) is refused, saying what the kind takes, before anything changes.
    public func edit(_ docID: Int64, fileName: String?, labels: LabelEdit?) async throws {
        if let refused = labels?.adding.lazy.compactMap(LabelError.refusal(of:)).first { throw refused }
        let placer = services.filer.placer
        var doc = try await document(docID)
        let target = try fileName.map { name in
            guard let target = placer.builder.bounded(name, fileExtension: doc.url.pathExtension) else { throw IngestError.unusableFileName(name) }
            return target
        }
        var edited: [String: String] = [:]
        var said: [String] = []
        if let target {
            if target != doc.filename {
                let (url, collision) = try placer.builder.uniqueDestination(directory: doc.url.deletingLastPathComponent(), filename: target)
                await services.filer.registry.expect([doc.path, url.path])
                _ = try placer.operations.move(doc.url, to: url, within: doc.url.deletingLastPathComponent(), collision: collision,
                                               expectedSHA256: doc.sha256, fingerprint: nil)
                doc = try await services.documents.update(docID) { doc in
                    doc.path = url.path
                    var analysis = doc.analysis ?? DocumentAnalysis()
                    analysis.fileName = (url.lastPathComponent as NSString).deletingPathExtension
                    doc.analysisJson = try JSON.string(analysis)
                }
                try await services.index.updateFilename(docID: docID, filename: doc.filename)
                edited["fileName"] = url.lastPathComponent
                said.append("Renamed to “\(url.lastPathComponent)”")
            }
        }
        let now = services.time.now()
        try await services.database.writer.write { [edited, said] db in
            var (edited, said) = (edited, said)
            if let labels {
                guard let current = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
                let before = current.labels ?? []
                let after = labels.applied(to: before)
                if DocumentLabel.stored(after, labelled: current.isLabelled).labels != current.labels {
                    try IndexStore.saveLabels(db, after, docID: docID, labelled: current.isLabelled, at: now)
                    edited["labels"] = after.map { "\($0.kind.rawValue): \($0.value)" }.joined(separator: "; ")
                    said += Self.changes(from: before, to: after)
                }
            }
            guard !edited.isEmpty else { return }
            try HistoryStore.insert(db, .corrected, at: now, actor: .user, doc: docID,
                                    summary: said.isEmpty ? "Corrected the labels" : said.joined(separator: "; "), payload: edited)
        }
    }

    /// What a correction changed of a document's labels, as History says it: “added sender “EDP”, type “receipt””,
    /// “removed type “invoice””; nothing when only their order changed.
    static func changes(from before: [DocumentLabel], to after: [DocumentLabel]) -> [String] {
        let said = { (labels: [DocumentLabel]) in labels.map { "\($0.kind.rawValue) “\($0.value)”" }.joined(separator: ", ") }
        let added = after.filter { !before.contains($0) }
        let removed = before.filter { !after.contains($0) }
        return (added.isEmpty ? [] : ["added " + said(added)]) + (removed.isEmpty ? [] : ["removed " + said(removed)])
    }
}
