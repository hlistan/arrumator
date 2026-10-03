import Foundation
import UniformTypeIdentifiers

/// The document a job's file is, and where a filing cut off by a crash left it.
extension IngestCoordinator {
    /// The document the job's file is: the one the job has, as the file is now, hashed again after it changed
    /// (`readFromTheStart`), or a new one.
    func ensureDocument(for job: JobRecord, source: URL, sha: String, fingerprint: FileFingerprint) async throws -> DocumentRecord {
        if let id = job.docId, try await services.documents.document(id: id) != nil {
            return try await services.documents.update(id) { existing in
                (existing.sha256, existing.size, existing.inode, existing.fileMtime) = (sha, fingerprint.size, fingerprint.inode, fingerprint.modified)
            }
        }
        // A type the file system cannot tell is plain data, as UTType calls it.
        let uttype = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier) ?? UTType.data.identifier
        let record = DocumentRecord.arrived(path: source.path, sha256: sha, size: fingerprint.size, uttype: uttype,
                                            inode: fingerprint.inode, modified: fingerprint.modified, now: services.time.now())
        return try await services.documents.save(record)
    }

    /// Where an earlier attempt moved `document` without recording it: its file is no longer where its record says, and
    /// the file at `planned`, where the job was about to move it, is that document, by the identity the move gave it
    /// (`Xattr.documentID`) or, when a crash came before that, by its bytes. Nil otherwise, and for a file that is
    /// another document's: one whose identity names another, or whose path another document's row holds.
    func movedBefore(_ document: DocumentRecord, planned: String?) async throws -> String? {
        guard let planned, !FileManager.default.fileExists(atPath: document.path), FileManager.default.fileExists(atPath: planned) else {
            return nil
        }
        let url = URL(fileURLWithPath: planned)
        if let held = try await services.documents.document(path: planned), held.id != document.id { return nil }
        switch Xattr.get(Xattr.documentID, from: url) {
        case document.uid: return planned
        case nil: return try await HashService.sha256Concurrently(of: url) == document.sha256 ? planned : nil
        default: return nil
        }
    }
}
