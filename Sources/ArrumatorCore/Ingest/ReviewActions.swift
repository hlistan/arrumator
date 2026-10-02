import Foundation
import GRDB

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

    /// Confirms the document as it is: its name and labels are right. One waiting for the user is filed.
    public func confirm(_ docID: Int64) async throws {
        var doc = try await document(docID)
        guard [.filed, .needsReview, .failed].contains(doc.status) else {
            throw IngestError.invalidState("only a document in the archive can be confirmed")
        }
        var analysis = doc.analysis ?? DocumentAnalysis()
        analysis.problems = []
        doc.status = .filed
        doc.analysisJson = JSON.string(analysis)
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
    /// archive's file goes to the Trash (`FileOperations`), never a delete.
    public func undo(_ docID: Int64) async throws {
        var doc = try await document(docID)
        let settings = await services.settings.current
        guard FileManager.default.fileExists(atPath: doc.path) else { throw IngestError.sourceMissing(doc.path) }
        let from = doc.path
        let operations = services.filer.placer.operations
        let (destination, collision) = try operations.uniqueDestination(directory: settings.incomingURL, filename: doc.originalFilename)
        await services.filer.registry.expect([from, destination.path])
        _ = try operations.move(doc.url, to: destination, collision: collision, expectedSHA256: doc.sha256)
        doc.path = destination.path
        doc.status = .undone
        doc = try await services.documents.save(doc)
        try await services.index.updateFilename(docID: docID, filename: destination.lastPathComponent)
        await services.vectors.remove(docID: docID)
        try await services.history.record(.undone, actor: .user, doc: docID, summary: "\(from) → Incoming",
                                          payload: ["from": from, "to": destination.path])
    }

    /// Applies the user's corrections: a new file name renames the file where it is, and `labels`, when given, become
    /// the document's labels, each kept as `DocumentLabel.normalized` keeps it, once, and one of a single-valued kind. A
    /// label of another kind than a tag labels a document not labelled yet; a tag, the user's own, does not
    /// (`DocumentLabel.stored`).
    public func edit(_ docID: Int64, fileName: String?, labels: [DocumentLabel]?) async throws {
        var doc = try await document(docID)
        var edited: [String: String] = [:]
        if let fileName, !fileName.isEmpty {
            let target = services.filer.placer.builder.bounded(fileName, fileExtension: doc.url.pathExtension)
            if target != doc.filename {
                let operations = services.filer.placer.operations
                let (url, collision) = try operations.uniqueDestination(directory: doc.url.deletingLastPathComponent(), filename: target)
                await services.filer.registry.expect([doc.path, url.path])
                _ = try operations.move(doc.url, to: url, collision: collision, expectedSHA256: doc.sha256)
                doc.path = url.path
                var analysis = doc.analysis ?? DocumentAnalysis()
                analysis.fileName = (url.lastPathComponent as NSString).deletingPathExtension
                doc.analysisJson = JSON.string(analysis)
                doc = try await services.documents.save(doc)
                try await services.index.updateFilename(docID: docID, filename: doc.filename)
                edited["fileName"] = url.lastPathComponent
            }
        }
        if let labels {
            let kept = labels.compactMap { DocumentLabel.normalized($0.value, kind: $0.kind) }.distinct()
            if DocumentLabel.stored(kept, labelled: doc.isLabelled).labels != doc.labels {
                try await services.index.saveLabels(kept, docID: docID, labelled: doc.isLabelled)
                edited["labels"] = kept.map { "\($0.kind.rawValue): \($0.value)" }.joined(separator: "; ")
            }
        }
        guard !edited.isEmpty else { return }
        try await services.history.record(.corrected, actor: .user, doc: docID,
                                          summary: "Corrected \(edited.keys.sorted().joined(separator: ", "))", payload: edited)
    }
}
