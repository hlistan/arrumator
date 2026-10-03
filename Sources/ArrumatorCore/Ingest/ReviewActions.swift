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
    /// `DocumentLabel.normalized` keeps it, once. One added of a single-valued kind (`LabelKind.isSingle`) takes the place
    /// of the one there, in its place, from the app and the command line alike, and only when it is written otherwise
    /// (`DocumentLabel.distinctKey`): the one there given again changes nothing. Of several added of such a kind, the
    /// first.
    public func applied(to labels: [DocumentLabel]) -> [DocumentLabel] {
        let removed = Set(removing.compactMap { DocumentLabel.normalized($0.value, kind: $0.kind) })
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

/// What a document's card offers, decided where the document is: the actions in the order they are shown, and whether
/// it was left in Incoming not filed, which its card says, with what to do.
public struct DocumentChoices: Sendable, Hashable {
    public var actions: [DocumentAction]
    public var notFiled: Bool

    public init(actions: [DocumentAction], notFiled: Bool) {
        self.actions = actions
        self.notFiled = notFiled
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
    /// filed) can be read again or left for later, never confirmed as filed or undone, as it is in no archive.
    public func choices(for document: DocumentRecord) async -> DocumentChoices {
        let inArchive = services.isInArchive(document)
        let actions: [DocumentAction] = switch document.status {
        case .filed: inArchive ? [.undo, .confirm] : []
        case .needsReview, .failed: inArchive ? [.hold, .readAgain, .confirm] : [.hold, .readAgain]
        case .held, .undone: [.readAgain]
        case .arrived, .processing, .duplicate, .missing: []
        }
        return DocumentChoices(actions: actions, notFiled: !inArchive && document.status == .failed)
    }

    /// Confirms the document as it is: its name and labels are right. One waiting for the user is filed.
    public func confirm(_ docID: Int64) async throws {
        var doc = try await document(docID)
        guard [.filed, .needsReview, .failed].contains(doc.status), services.isInArchive(doc) else {
            throw IngestError.invalidState("only a document in the archive can be confirmed")
        }
        var analysis = doc.analysis ?? DocumentAnalysis()
        analysis.problems = []
        doc.status = .filed
        doc.analysisJson = try JSON.string(analysis)
        doc = try await services.documents.save(doc)
        try await services.history.record(.markedCorrect, actor: .user, doc: docID, summary: "Confirmed \(doc.filename)")
    }

    /// Reads the document again with the model, as after changing models, from the text read of it before, and files it
    /// under the name it gives: where it is in the archive, or, for one back in Incoming, at the top of the archive. It
    /// keeps its tags, which its row in the queue shows, and one in a folder in Incoming is given that folder's too
    /// (`PipelineServices.queueReadingAgain`).
    public func retry(_ docID: Int64) async throws {
        let doc = try await document(docID)
        try await services.queueReadingAgain(doc, content: try await services.documents.content(docID: docID),
                                             settings: await services.settings.current)
        try await services.history.record(.retry, actor: .user, doc: docID, summary: "Read again: \(doc.filename)")
        await coordinator.wake()
    }

    /// Keeps the document where it is; the watcher and queue leave it alone.
    public func hold(_ docID: Int64) async throws {
        var doc = try await document(docID)
        doc.status = .held
        _ = try await services.documents.save(doc)
        try await services.history.record(.needsReview, actor: .user, doc: docID, summary: "Left for later")
    }

    /// Moves a filed document back to Incoming, held, so it is not filed again automatically. Incoming may be on
    /// another volume than the archive; the move is then a copy checked against the document's hash before the
    /// archive's file goes to the Trash (`FileOperations`), never a delete, and a file the Trash will not take stays
    /// where it is, undone in nothing.
    public func undo(_ docID: Int64) async throws {
        var doc = try await document(docID)
        let settings = await services.settings.current
        guard FileManager.default.fileExists(atPath: doc.path) else { throw IngestError.sourceMissing(doc.path) }
        let from = doc.path
        let placer = services.filer.placer
        // Spelled as the watcher and `enqueue` spell a path in Incoming, so a rescan finds the undone document there.
        let incoming = settings.incomingURL.folderOnDisk
        let (destination, collision) = try placer.builder.uniqueDestination(directory: incoming, filename: doc.originalFilename)
        await services.filer.registry.expect([from, destination.path])
        _ = try placer.operations.move(doc.url, to: destination, within: incoming, collision: collision, expectedSHA256: doc.sha256,
                                       fingerprint: nil)
        doc.path = destination.path
        doc.status = .undone
        doc = try await services.documents.save(doc)
        try await services.index.updateFilename(docID: docID, filename: destination.lastPathComponent)
        await services.vectors.remove(docID: docID)
        try await services.history.record(.undone, actor: .user, doc: docID, summary: "\(from) → Incoming",
                                          payload: ["from": from, "to": destination.path])
    }

    /// Applies the user's corrections: a new file name renames the file where it is, and `labels`, when given, are
    /// applied to the labels the document has when the change is made (`LabelEdit.applied(to:)`), read and written in
    /// one transaction with the event that records them, so changes made one after another, such as two labels taken off
    /// a card, each keep what the other did. A label of another kind than a tag labels a document not labelled yet; a
    /// tag, the user's own, does not (`DocumentLabel.stored`).
    public func edit(_ docID: Int64, fileName: String?, labels: LabelEdit?) async throws {
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
                doc.path = url.path
                var analysis = doc.analysis ?? DocumentAnalysis()
                analysis.fileName = (url.lastPathComponent as NSString).deletingPathExtension
                doc.analysisJson = try JSON.string(analysis)
                doc = try await services.documents.save(doc)
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
