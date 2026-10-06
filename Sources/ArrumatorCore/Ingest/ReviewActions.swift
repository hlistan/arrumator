import Foundation
import GRDB

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
/// undo its filing. Every action is recorded in the history.
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
        // Its reading in not ended, as in the instant between its filing and its job's end, it is neither undone nor left
        // for later (`undo`, `hold`), so neither is offered; the card asks again as the worker moves on.
        if let id = document.id, actions.contains(where: { [.undo, .hold].contains($0) }),
           try await services.database.reader.read({ db in try JobStore.isReadIn(db, docID: id) }) {
            actions.removeAll { [.undo, .hold].contains($0) }
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
    /// place of one that gives way (`JobRecord.givesWay`): not while another reading of it waits or is under way, an
    /// earlier Read Again's, an exact copy's, or its reading in at its file, in Incoming or put into the archive, which
    /// it is read with.
    public func retry(_ docID: Int64) async throws {
        try await services.queueReadingAgain(docID, settings: await services.settings.current)
        await coordinator.wake()
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
