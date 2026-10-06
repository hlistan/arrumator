import Foundation

/// Exact copies: a file in Incoming whose bytes a document of the archive holds is handed over to it, never a second
/// document of it; and a document's own file, however its path is spelled, is that document.
extension IngestCoordinator {
    /// The document recorded at `path`: one of the archive looked up as the archive spells its documents' paths, however
    /// `path` names the file, through a link or `/private` (`URL.spellings`).
    func knownDocument(at path: String) async throws -> DocumentRecord? {
        if let found = try await services.documents.document(path: path) { return found }
        let spellings = services.archive.spellings
        guard let named = spellings.first(where: { path.hasPrefix($0 + "/") }) else { return nil }
        let inside = path.dropFirst(named.count)
        for spelling in spellings where spelling != named {
            if let found = try await services.documents.document(path: spelling + inside) { return found }
        }
        return nil
    }

    /// The document in the archive the file at `source` is an exact copy of: the oldest with its SHA-256
    /// (`DocumentStore.existing`) whose file, another than `source`, still has it, as the trace's `dedupe` step records;
    /// nil when there is none, and for a file the user put into the archive (`adopt`), which is a document of its own.
    /// Its file is hashed again, as it may have been changed since it was filed: a file the archive no longer holds the
    /// same bytes of is no copy.
    func original(of source: URL, sha256: String, job: JobRecord, trace: TraceContext) async throws -> DocumentRecord? {
        // Only an arrival is a copy: a file the user put into the archive, and a document of it read again, are their own.
        guard job.kind == .ingest else { return nil }
        let documents = services.documents
        let archive = services.archive
        return try await trace.measure(.dedupe, input: ["sha256": sha256],
                                       output: { (d: DocumentRecord?) in ["copyOf": d?.id.map(String.init) ?? "none"] }) {
            guard let found = try await documents.existing(sha256: sha256, excluding: job.docId, archive: archive),
                  found.url.resolvingSymlinksInPath() != source.resolvingSymlinksInPath(),
                  FileManager.default.fileExists(atPath: found.path),
                  try await HashService.sha256Concurrently(of: found.url) == sha256 else { return nil }
            return found
        }
    }

    /// Hands a file that is an exact copy of `original` over to it, rather than making a second document of the same
    /// bytes: the file goes to the Trash, never deleted, and the original is read again from the start, as the file
    /// would have been, queued in the write that finds it still in the archive as itself
    /// (`PipelineServices.queueReadingAgain(forCopyOf:)`), so a copy put into Incoming reads its document again with the
    /// profile in use; then it is given the tags the file was queued with (`PipelineServices.giveTags`). History records
    /// this once, under the original. The original is kept with the job first, so a stop part way finishes the rest at
    /// the next start, the copy in the Trash already or not; a copy the Trash refuses fails the job before its original
    /// is read, and stays where it is. Whether it was handed over: one whose original the user undid, or that left the
    /// archive, since it was found is not, and is read in as a document of its own, taken back from the Trash when it
    /// went there meanwhile.
    func handOver(_ copy: URL, to original: DocumentRecord, job: inout JobRecord, payload: inout JobPayload,
                  trace: TraceContext) async throws -> Bool {
        guard let originalID = original.id else { throw IngestError.documentNotPersisted }
        guard try await services.takesCopy(of: originalID) else { return false }
        payload.copyOf = originalID
        try await save(&job, &payload, state: .hashing, trace: trace)
        var trashed: URL?
        if FileManager.default.fileExists(atPath: copy.path) {
            do { trashed = try services.trash.trash(copy) } catch {
                throw IngestError.notTrashed(copy.path, reason: error.localizedDescription)
            }
        }
        // Undone as the copy went to the Trash: the copy comes back where it was, a document of its own.
        guard try await services.queueReadingAgain(forCopyOf: originalID) else {
            if let trashed { try FileManager.default.moveItem(at: trashed, to: copy) }
            payload.copyOf = nil
            try await save(&job, &payload, state: .hashing, trace: trace)
            return false
        }
        if let given = payload.tags { payload.tags = try await services.giveTags(given, docID: originalID, trace: trace) }
        // A file that was a document of its own, as one left in Incoming or one that changed into this copy, ends as one.
        try await end(job.docId, as: .duplicate, of: originalID)
        let tags = payload.tags ?? []
        let summary = ["\(copy.lastPathComponent) is a copy of \(original.filename), which is read again",
                       trashed.map { _ in "the copy is in the Trash" }, GivenTag.note(tags)].compactMap { $0 }.joined(separator: "; ")
        try await services.history.record(.duplicate, doc: originalID, job: job.id, trace: trace.traceID, summary: summary,
                                          payload: CopyPayload(copy: copy.path, trashed: trashed?.path, tags: tags.isEmpty ? nil : tags))
        try await save(&job, &payload, state: .duplicate, trace: trace)
        Log.info(.ingest, "A copy of a document in the archive; its original is read again",
                 ["copy": copy.path, "doc": String(originalID), "trashed": trashed?.path ?? "-"])
        return true
    }
}

/// What History keeps of a file that was an exact copy of a document in the archive, whose event is the original's: where
/// the copy was and where the Trash put it, and the tags it gave the original. Its keys are none that the events of
/// copies kept before (`original` and `path`, or `from`, `to` and `problems`) were written under.
public struct CopyPayload: Sendable, Codable, Hashable {
    /// The copy's path in Incoming.
    public var copy: String
    /// Where the Trash put it; absent when that cannot be told, as when a stop came after it went.
    public var trashed: String?
    /// The tags the copy gave its original, and what gave each; absent when it gave none.
    public var tags: [GivenTag]?

    public init(copy: String, trashed: String?, tags: [GivenTag]?) {
        self.copy = copy
        self.trashed = trashed
        self.tags = tags
    }

    /// Whether this copy was the file at `url`, however that path is spelled: a copy's path is recorded as the queue
    /// spells it (`URL.spelledOnDisk`), and so is compared.
    public func isCopy(at url: URL) -> Bool { copy == url.spelledOnDisk.path }
}
