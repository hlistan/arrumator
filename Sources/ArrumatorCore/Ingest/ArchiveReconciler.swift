import Foundation

/// Applies archive changes reported by `ArchiveWatcher`: a document the user moved or renamed is followed to where it
/// is now, files the app does not know are read and labelled where they are, and vanished files are marked missing.
public actor ArchiveReconciler {
    private let services: PipelineServices
    private let coordinator: IngestCoordinator

    public init(services: PipelineServices, coordinator: IngestCoordinator) {
        self.services = services
        self.coordinator = coordinator
    }

    public func apply(_ changes: [ArchiveChange]) async {
        for change in changes {
            do {
                switch change {
                case let .documentMoved(uid, newPath): try await moved(uid: uid, to: newPath)
                case let .documentMissing(path): try await missing(path)
                case let .untrackedFile(path): try await adopt(path)
                case .recordsChanged: continue
                }
            } catch {
                Log.error(.watch, "Could not apply archive change", ["change": String(describing: change),
                                                                    "error": error.localizedDescription])
            }
        }
    }

    private func moved(uid: String, to newPath: String) async throws {
        guard var doc = try await services.documents.document(uid: uid), doc.path != newPath, let docID = doc.id else { return }
        let from = doc.path
        let oldName = doc.filename
        doc.path = newPath
        doc.inode = FileFingerprint.inode(of: URL(fileURLWithPath: newPath))
        if doc.status == .missing { doc.status = .filed }
        doc = try await services.documents.save(doc)
        try await services.index.updateFilename(docID: docID, filename: doc.filename)
        let sameDirectory = (from as NSString).deletingLastPathComponent == (newPath as NSString).deletingLastPathComponent
        try await services.history.record(sameDirectory ? .userRenamed : .userMoved, actor: .user, doc: docID,
                                          summary: sameDirectory ? "\(oldName) → \(doc.filename)" : "\(oldName) moved to \(newPath)",
                                          payload: ["from": from, "to": newPath])
        Log.info(.watch, "User moved document", ["doc": String(docID), "to": newPath])
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
        try await services.jobs.enqueue(path: path, kind: .adopt)
        try await services.history.record(.adopted, actor: .user, summary: "\((path as NSString).lastPathComponent) added to the archive",
                                          payload: ["path": path])
        await coordinator.wake()
    }
}
