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

    /// The file a job reads: the one it was queued for, or, for a document read again (`reanalyse`), the document's where
    /// it is now (`stillToReadAgain`), until it is filed, when filing finds it; nil, and the job cancelled, for a document
    /// no longer to be read again, as one left for later meanwhile.
    func source(_ job: inout JobRecord, payload: inout JobPayload, trace: TraceContext) async throws -> URL? {
        guard job.kind == .reanalyse, job.state != .filing else { return URL(fileURLWithPath: job.sourcePath) }
        guard let document = try await stillToReadAgain(job) else {
            Log.info(.ingest, "No longer to be read again; left as it is", ["job": String(job.id ?? 0)])
            try await save(&job, &payload, state: .cancelled, trace: trace)
            return nil
        }
        status.current?.path = document.path
        return document.url
    }

    /// Has the model read the document, `content` being its text: a file read the first time keeps what it reads at once
    /// (`PipelineServices.analyse`); a document read again keeps it with its job until it is filed
    /// (`PipelineServices.reread`).
    func read(_ job: JobRecord, payload: inout JobPayload, docID: Int64, content: ExtractedContent, settings: AppSettings,
              trace: TraceContext) async throws {
        let given = payload.tags ?? []
        guard job.kind == .reanalyse else {
            payload.outcome = try await services.analyse(docID: docID, jobID: job.id, content: content, given: given, settings: settings,
                                                         trace: trace)
            return
        }
        let read = try await services.reread(docID: docID, content: content, given: given, settings: settings, trace: trace)
        (payload.outcome, payload.rereading) = (read.outcome, read.rereading)
    }

    /// What filing `document`, read again, as it is now, does with what its reading named it, `analysis`: nil when it is
    /// no longer to be read again, as one the user left for later or undid meanwhile, which keeps everything it had; and
    /// whether it keeps the name it has, given it by the user since the reading began (`Rereading.path`), as a label the
    /// user changes meanwhile stays (`IndexStore.kept`), its analysis then naming it so.
    func filing(_ document: DocumentRecord, rereading: Rereading,
                analysis: DocumentAnalysis) -> (analysis: DocumentAnalysis, keepsItsName: Bool)? {
        guard [.filed, .needsReview, .failed, .processing].contains(document.status), services.isInArchive(document) else { return nil }
        guard document.path != rereading.path else { return (analysis, false) }
        var named = analysis
        named.fileName = (document.filename as NSString).deletingPathExtension
        return (named, true)
    }

    /// The document a job reading it again (`reanalyse`) reads, where it is now, as one moved or renamed in Finder while
    /// it waited is, as the record of it says: one still kept in the archive as itself, or being read again, its file
    /// there. Nil for one that is no longer, as one the user left for later, undid or removed meanwhile, which is not
    /// read again: what the user did since stands. Throws what the archive's folder missing throws, so the job waits.
    func stillToReadAgain(_ job: JobRecord) async throws -> DocumentRecord? {
        try checkArchiveThere()
        guard let id = job.docId, let document = try await services.documents.document(id: id),
              [.filed, .needsReview, .failed, .processing].contains(document.status), services.isInArchive(document),
              FileManager.default.fileExists(atPath: document.path) else { return nil }
        return document
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
