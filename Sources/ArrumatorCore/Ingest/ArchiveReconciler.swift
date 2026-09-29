import Foundation

/// Applies archive changes reported by `ArchiveWatcher`: user moves become corrections, untracked files are
/// adopted in place, vanished files are marked missing, folder edits re-sync the taxonomy.
public actor ArchiveReconciler {
    private let services: PipelineServices
    private let coordinator: IngestCoordinator

    public init(services: PipelineServices, coordinator: IngestCoordinator) {
        self.services = services
        self.coordinator = coordinator
    }

    public func apply(_ changes: [ArchiveChange]) async {
        let settings = await services.settings.current
        if changes.contains(.taxonomyChanged) {
            do {
                let folderChanges = try await services.taxonomy.sync(root: settings.archiveURL)
                if !folderChanges.isEmpty {
                    let snapshot = try await services.taxonomy.snapshot(root: settings.archiveURL)
                    await services.learner.taxonomyChanged(folderChanges, taxonomy: snapshot)
                }
            } catch {
                Log.error(.taxonomy, "Taxonomy sync failed", ["error": error.localizedDescription])
            }
        }
        for change in changes {
            do {
                switch change {
                case let .documentMoved(uid, newPath): try await moved(uid: uid, to: newPath, settings: settings)
                case let .documentMissing(path): try await missing(path)
                case let .untrackedFile(path): try await adopt(path)
                case .taxonomyChanged, .recordsChanged: continue
                }
            } catch {
                Log.error(.watch, "Could not apply archive change", ["change": String(describing: change),
                                                                    "error": error.localizedDescription])
            }
        }
    }

    private func moved(uid: String, to newPath: String, settings: AppSettings) async throws {
        guard var doc = try await services.documents.document(uid: uid), doc.path != newPath, let docID = doc.id else { return }
        let taxonomy = try await services.taxonomy.snapshot(root: settings.archiveURL)
        let newFolder = folder(containing: newPath, taxonomy: taxonomy)
        let oldFolder = doc.folderId
        let oldName = doc.filename
        doc.path = newPath
        doc.inode = FileFingerprint.inode(of: URL(fileURLWithPath: newPath))
        if let newFolder {
            doc.folderId = newFolder.id
            if newFolder.role == nil { doc.status = .filed }
            if newFolder.role == .needsReview { doc.status = .needsReview }
        }
        doc = try await services.documents.save(doc)
        try await services.index.updateHeader(docID: docID, title: doc.title ?? "", correspondent: doc.correspondent ?? "",
                                              filename: doc.filename)
        if let newFolder, newFolder.id != oldFolder {
            let correction = CorrectionEvent(documentID: docID, source: .finderMove, fromFolderID: oldFolder, toFolderID: newFolder.id,
                                             fromFilename: oldName, toFilename: doc.filename, proposed: doc.decision,
                                             traceID: doc.lastTraceId)
            try await GRDBLearningStore(database: services.database).insertCorrection(correction)
            try await services.history.record(.userMoved, actor: .user, doc: docID,
                                              summary: "\(oldName) moved to \(taxonomy.path(of: newFolder))", payload: correction)
            await services.learner.correctionRecorded(correction, trace: .disabled)
            if newFolder.acceptsFiles, let content = try await services.documents.content(docID: docID) {
                var decision = doc.decision ?? FilingDecision(folderCode: newFolder.code, title: content.source.stem,
                                                              confidence: ConfidenceReport(final: 1, band: .auto, thresholds: settings.thresholds),
                                                              decidedBy: .user, rationale: "Moved by the user in Finder")
                decision.folderCode = newFolder.code
                decision.decidedBy = .user
                let embedModel = try services.config.models(for: settings.models).embed
                let embedding = try await services.index.embedding(docID: docID, model: embedModel)
                await services.learner.documentFiled(documentID: docID, folderID: newFolder.id,
                                                     outcome: ClassificationOutcome(decision: decision, embedding: embedding,
                                                                                    embeddingModel: embedModel),
                                                     content: content, confirmedByUser: true, trace: .disabled)
            }
        } else if oldName != doc.filename {
            try await services.history.record(.userRenamed, actor: .user, doc: docID, summary: "\(oldName) → \(doc.filename)")
        }
        Log.info(.learn, "User moved document", ["doc": String(docID), "to": newPath])
    }

    private func missing(_ path: String) async throws {
        guard var doc = try await services.documents.document(path: path), let docID = doc.id,
              [.filed, .needsReview, .duplicate, .failed].contains(doc.status) else { return }
        doc.status = .missing
        _ = try await services.documents.save(doc)
        await services.vectors.remove(docID: docID)
        try await services.history.record(.missing, actor: .user, doc: docID, summary: "\(doc.filename) was removed from the archive")
    }

    private func adopt(_ path: String) async throws {
        if try await services.documents.document(path: path) != nil { return }
        let settings = await services.settings.current
        let taxonomy = try await services.taxonomy.snapshot(root: settings.archiveURL)
        guard let folder = folder(containing: path, taxonomy: taxonomy), folder.holdsUserDocuments else { return }
        var payload = JobPayload()
        payload.userFolderID = folder.id
        try await services.jobs.enqueue(path: path, kind: .adopt, payload: payload)
        try await services.history.record(.adopted, actor: .user, summary: "\((path as NSString).lastPathComponent) added to \(taxonomy.path(of: folder))",
                                          payload: ["path": path])
        await coordinator.wake()
    }

    /// The folder `path` is in, directly or in one of its year folders: the deepest that contains it.
    private func folder(containing path: String, taxonomy: TaxonomySnapshot) -> TaxonomyFolder? {
        taxonomy.folder(holding: URL(fileURLWithPath: path).deletingLastPathComponent())
    }
}
