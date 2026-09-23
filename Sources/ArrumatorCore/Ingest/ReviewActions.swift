import Foundation
import GRDB

/// User decisions on documents: approve, choose a folder, create a folder, move, retry, hold, undo, mark correct.
/// Every action is recorded in history and, when it changes or confirms a placement, reported to the learner.
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

    /// Accepts the classifier's proposal for a held document, creating the proposed folder when there is one.
    public func approve(_ docID: Int64) async throws {
        let doc = try await document(docID)
        let settings = await services.settings.current
        guard let decision = doc.decision else { throw IngestError.noTarget("no proposal to approve") }
        let folder: TaxonomyFolder
        if let code = decision.folderCode {
            guard let existing = try await services.taxonomy.snapshot(root: settings.archiveURL).folder(code: code) else {
                throw PlacementError.unknownFolder(code)
            }
            folder = existing
        } else if let spec = decision.proposedNewFolder {
            folder = try await services.taxonomy.materialize(spec, root: settings.archiveURL, origin: .learned)
        } else {
            throw IngestError.noTarget("no proposal to approve")
        }
        let taxonomy = try await services.taxonomy.snapshot(root: settings.archiveURL)
        try await file(doc, into: folder, source: .reviewApprove, taxonomy: taxonomy, settings: settings)
    }

    /// Files a document into a folder the user picked (Review "Choose folder", Browser/Search "Move to…").
    public func move(_ docID: Int64, toFolder folderID: Int64) async throws {
        let doc = try await document(docID)
        let settings = await services.settings.current
        let taxonomy = try await services.taxonomy.snapshot(root: settings.archiveURL)
        guard let folder = taxonomy.folder(id: folderID) else { throw TaxonomyError.unknownFolder(folderID) }
        let source: CorrectionSource = doc.status.isReviewable ? .review : .moveTo
        try await file(doc, into: folder, source: source, taxonomy: taxonomy, settings: settings)
    }

    /// Creates a folder the user described (possibly in a new area) and files the document there.
    public func createFolderAndFile(_ docID: Int64, spec: FolderSpec) async throws {
        let settings = await services.settings.current
        let folder = try await services.taxonomy.materialize(spec, root: settings.archiveURL, origin: .user)
        try await move(docID, toFolder: folder.id)
    }

    private func file(_ doc: DocumentRecord, into folder: TaxonomyFolder, source: CorrectionSource,
                      taxonomy: TaxonomySnapshot, settings: AppSettings) async throws {
        guard let docID = doc.id else { throw IngestError.documentNotPersisted }
        guard var content = try await services.documents.content(docID: docID) else { throw IngestError.contentUnavailable(docID) }
        content.source.path = doc.path
        let proposed = doc.decision
        var decision = proposed ?? FilingDecision(folderCode: nil, title: content.source.stem,
                                                  confidence: ConfidenceReport(final: 0, band: .review, thresholds: settings.thresholds),
                                                  decidedBy: .review, rationale: "")
        let previousFolder = doc.folderId
        decision.folderCode = folder.code
        decision.decidedBy = .user
        decision.confidence.final = 1
        decision.confidence.band = .auto
        let trace = try await services.startTrace(docID: docID, jobID: nil, attempt: 0, source: .review, settings: settings)
        await trace.record(.review, startedAt: Date(), input: ["action": source.rawValue, "folder": folder.code],
                           output: ["previousFolder": previousFolder.map(String.init) ?? "none"])
        let result = try await services.filer.file(doc, source: content.source, decision: decision, folderCode: folder.code,
                                                   status: .filed, userChosen: true, inPlace: false, taxonomy: taxonomy,
                                                   settings: settings, trace: trace)
        let correction = CorrectionEvent(documentID: docID, source: source, fromFolderID: previousFolder, toFolderID: folder.id,
                                         fromFilename: doc.filename, toFilename: result.document.filename, proposed: proposed,
                                         traceID: doc.lastTraceId)
        try await recordCorrection(correction, trace: trace)
        let embedModel = try services.config.models(for: settings.models).embed
        let outcome = ClassificationOutcome(decision: decision,
                                            embedding: try await services.index.embedding(docID: docID, model: embedModel),
                                            embeddingModel: embedModel)
        var filed = content
        filed.source.path = result.document.path
        await services.learner.documentFiled(documentID: docID, folderID: folder.id, outcome: outcome, content: filed,
                                             confirmedByUser: true, trace: trace)
        if let previousFolder, previousFolder != folder.id {
            try await removeIfEmptied(previousFolder, settings: settings, move: PlacementMove(
                documentID: docID, fromFolderID: previousFolder, toFolderID: folder.id,
                correspondentID: result.document.correspondentId, documentType: decision.documentType))
        }
        await services.traces.finish(trace, outcome: "user-filed", docID: docID)
    }

    /// Removes the folder a document left when nothing else is in it; its rules follow the document, if it went on
    /// to another folder.
    private func removeIfEmptied(_ folderID: Int64, settings: AppSettings, move: PlacementMove?) async throws {
        let removed = try await services.taxonomy.pruneEmpty(root: settings.archiveURL, folderIDs: [folderID])
        guard !removed.isEmpty else { return }
        await services.learner.placementsRearranged(move.map { [$0] } ?? [], removedFolderIDs: Set(removed.map(\.id)))
    }

    private func recordCorrection(_ correction: CorrectionEvent, trace: TraceContext) async throws {
        let store = GRDBLearningStore(database: services.database)
        try await store.insertCorrection(correction)
        let changed = correction.fromFolderID != correction.toFolderID
        try await services.history.record(changed ? .corrected : .markedCorrect, actor: .user, doc: correction.documentID,
                                          trace: trace.traceID,
                                          summary: "\(correction.fromFilename ?? "") → folder \(correction.toFolderID.map(String.init) ?? "-")",
                                          payload: correction)
        await services.learner.correctionRecorded(correction, trace: trace)
    }

    /// Confirms an automatic filing was right (positive example for calibration and memories).
    public func markCorrect(_ docID: Int64) async throws {
        let doc = try await document(docID)
        guard let folderID = doc.folderId else { throw IngestError.noTarget("document is not filed") }
        let correction = CorrectionEvent(documentID: docID, source: .markCorrect, fromFolderID: folderID, toFolderID: folderID,
                                         fromFilename: doc.filename, toFilename: doc.filename, proposed: doc.decision,
                                         traceID: doc.lastTraceId)
        try await recordCorrection(correction, trace: .disabled)
    }

    /// Runs classification again (e.g. after models or descriptions changed).
    public func retry(_ docID: Int64) async throws {
        let doc = try await document(docID)
        var payload = JobPayload()
        payload.sha256 = doc.sha256
        payload.content = try await services.documents.content(docID: docID)
        let state: JobState = payload.content == nil ? .extracting : .classifying
        try await services.jobs.enqueue(path: doc.path, kind: .reclassify, docID: docID, payload: payload, state: state)
        await coordinator.wake()
    }

    /// Keeps the document where it is; the watcher and queue leave it alone.
    public func hold(_ docID: Int64) async throws {
        var doc = try await document(docID)
        doc.status = .held
        _ = try await services.documents.save(doc)
        try await services.history.record(.needsReview, actor: .user, doc: docID, summary: "Left for later")
    }

    /// Moves a filed document back to Incoming (held, so it is not re-filed automatically) and forgets what was learned.
    public func undo(_ docID: Int64) async throws {
        var doc = try await document(docID)
        let settings = await services.settings.current
        guard FileManager.default.fileExists(atPath: doc.path) else { throw IngestError.sourceMissing(doc.path) }
        let from = doc.path
        let operations = FileOperations(naming: services.config.naming)
        let (destination, _) = try operations.uniqueDestination(directory: settings.incomingURL, filename: doc.originalFilename)
        await services.filer.registry.expect([from, destination.path])
        try FileManager.default.createDirectory(at: settings.incomingURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: doc.url, to: destination)
        let previousFolder = doc.folderId
        doc.path = destination.path
        doc.folderId = nil
        doc.status = .undone
        doc = try await services.documents.save(doc)
        try await services.index.updateHeader(docID: docID, title: doc.title ?? "", correspondent: doc.correspondent ?? "",
                                              filename: destination.lastPathComponent)
        await services.vectors.remove(docID: docID)
        await services.learner.documentForgotten(documentID: docID)
        let correction = CorrectionEvent(documentID: docID, source: .undo, fromFolderID: previousFolder, toFolderID: nil,
                                         fromFilename: (from as NSString).lastPathComponent,
                                         toFilename: destination.lastPathComponent, proposed: doc.decision, traceID: doc.lastTraceId)
        try await GRDBLearningStore(database: services.database).insertCorrection(correction)
        try await services.history.record(.undone, actor: .user, doc: docID, summary: "\(from) → Incoming",
                                          payload: ["from": from, "to": destination.path])
        if let previousFolder { try await removeIfEmptied(previousFolder, settings: settings, move: nil) }
    }

    /// Re-files an undone or held document through the full pipeline.
    public func refile(_ docID: Int64) async throws {
        var doc = try await document(docID)
        doc.status = .processing
        _ = try await services.documents.save(doc)
        try await services.history.record(.refiled, actor: .user, doc: docID, summary: "Decide again: \(doc.filename)")
        try await retry(docID)
    }

    /// Applies user edits to the file name and metadata. A new file name renames the file in place; every edit is
    /// recorded as a correction so naming and metadata preferences can be learned.
    public func edit(_ docID: Int64, fileName: String?, title: String?, correspondent: String?, date: String?,
                     type: DocumentType?) async throws {
        var doc = try await document(docID)
        guard var decision = doc.decision else { throw IngestError.invalidState("document has no decision to edit") }
        var edited: [String: String] = [:]
        if let title, title != decision.title { decision.title = title; edited["title"] = title }
        if let correspondent, correspondent != decision.correspondent { decision.correspondent = correspondent; edited["correspondent"] = correspondent }
        if let date, date != decision.documentDate { decision.documentDate = date; edited["date"] = date }
        if let type, type != decision.documentType { decision.documentType = type; edited["type"] = type.rawValue }
        let oldName = doc.filename
        if let fileName, !fileName.isEmpty {
            let target = services.filer.placer.builder.bounded(fileName, fileExtension: doc.url.pathExtension)
            if target != oldName {
                let operations = FileOperations(naming: services.config.naming)
                let (url, _) = try operations.uniqueDestination(directory: doc.url.deletingLastPathComponent(), filename: target)
                await services.filer.registry.expect([doc.path, url.path])
                try FileManager.default.moveItem(at: doc.url, to: url)
                doc.path = url.path
                decision.fileName = (url.lastPathComponent as NSString).deletingPathExtension
                edited["fileName"] = url.lastPathComponent
            }
        }
        guard !edited.isEmpty else { return }
        doc.title = decision.title
        doc.correspondent = decision.correspondent
        doc.docDate = decision.documentDate
        doc.docType = decision.documentType.rawValue
        doc.decisionJson = JSON.string(decision)
        doc = try await services.documents.save(doc)
        try await services.index.updateHeader(docID: docID, title: doc.title ?? "", correspondent: doc.correspondent ?? "",
                                              filename: doc.filename)
        let correction = CorrectionEvent(documentID: docID, source: .moveTo, fromFolderID: doc.folderId, toFolderID: doc.folderId,
                                         fromFilename: oldName, toFilename: doc.filename, proposed: nil, editedFields: edited,
                                         traceID: doc.lastTraceId)
        try await GRDBLearningStore(database: services.database).insertCorrection(correction)
        await services.learner.correctionRecorded(correction, trace: .disabled)
        try await services.history.record(.corrected, actor: .user, doc: docID,
                                          summary: "Edited \(edited.keys.sorted().joined(separator: ", "))", payload: edited)
    }
}
