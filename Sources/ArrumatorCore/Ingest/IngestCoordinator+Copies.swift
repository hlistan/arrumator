import Foundation

/// Exact copies: a file in Incoming whose bytes a document of the archive holds is handed over to it, never a second
/// document of it.
extension IngestCoordinator {
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
    /// bytes. It is decided while the original is in the archive as itself (`PipelineServices.takesCopy`), and kept with
    /// the job (`copyOf`); from then on it is done whatever the user does to the original meanwhile, as though the user
    /// did it after (`finishHandingOver`), but for a stop before the copy is in the Trash, after which the copy is looked
    /// at again, by its original as it is then (`original(of:)`). Whether it was handed over: not when the original no
    /// longer takes a copy as it is decided, and the copy is then a document of its own.
    func handOver(_ copy: URL, to original: DocumentRecord, job: inout JobRecord, payload: inout JobPayload,
                  trace: TraceContext) async throws -> Bool {
        guard let originalID = original.id else { throw IngestError.documentNotPersisted }
        guard try await services.takesCopy(of: originalID) else { return false }
        payload.copyOf = originalID
        try await save(&job, &payload, state: .hashing, trace: trace)
        try await finishHandingOver(copy, to: original, job: &job, payload: &payload, trace: trace)
        return true
    }

    /// Does what is left of handing a copy over to `original`, decided and kept with the job (`copyOf`): the copy goes to
    /// the Trash, never deleted, and the original, still in the archive as itself, is read again from the start, as the
    /// file would have been, so a copy put into Incoming reads its document again with the profile in use
    /// (`PipelineServices.queueReadingAgain(forCopyOf:)`); one undone, or gone from the archive, meanwhile is not read
    /// again, and nothing comes back from the Trash. Then the original is given the tags the file was queued with
    /// (`PipelineServices.giveTags`). History records this once, under the original. A stop part way finishes the rest
    /// at the next start, the copy in the Trash already or not, and another file put at its path meanwhile, as its
    /// original undone back into Incoming, is never taken for it (`isStill`); a copy the Trash refuses fails the job
    /// before its original is read, and stays where it is.
    func finishHandingOver(_ copy: URL, to original: DocumentRecord, job: inout JobRecord, payload: inout JobPayload,
                           trace: TraceContext) async throws {
        guard let originalID = original.id else { throw IngestError.documentNotPersisted }
        var trashed: URL?
        if try await isStill(copy, payload: payload) {
            do { trashed = try services.trash.trash(copy) } catch {
                throw IngestError.notTrashed(copy.path, reason: error.localizedDescription)
            }
        }
        let readAgain = try await services.queueReadingAgain(forCopyOf: originalID)
        if let given = payload.tags { payload.tags = try await services.giveTags(given, docID: originalID, trace: trace) }
        // A file that was a document of its own, as one left in Incoming or one that changed into this copy, ends as one.
        try await end(job.docId, as: .duplicate, of: originalID)
        let tags = payload.tags ?? []
        let summary = ["\(copy.lastPathComponent) is a copy of \(original.filename), "
                       + (readAgain ? "which is read again" : "which has left the archive since, and is not read again"),
                       trashed.map { _ in "the copy is in the Trash" }, GivenTag.note(tags)].compactMap { $0 }.joined(separator: "; ")
        try await services.history.record(.duplicate, doc: originalID, job: job.id, trace: trace.traceID, summary: summary,
                                          payload: CopyPayload(copy: copy.path, trashed: trashed?.path, tags: tags.isEmpty ? nil : tags))
        try await save(&job, &payload, state: .duplicate, trace: trace)
        Log.info(.ingest, "A copy of a document in the archive; its original is read again",
                 ["copy": copy.path, "doc": String(originalID), "trashed": trashed?.path ?? "-", "readAgain": String(readAgain)])
        // Another file put at the copy's path once it was in the Trash, which a request for it found this job for, is
        // queued as it came: one the user put there is read, an undone original left where it is (`stays`).
        if FileManager.default.fileExists(atPath: copy.path) { await enqueue(copy) }
    }

    /// Whether the file at `copy` is still the copy the job hashed (`JobPayload.fingerprint`, kept with `copyOf`), not
    /// another put at its path once the copy went to the Trash: one that is not that file, or the file of a document the
    /// user set aside recorded there (`DocumentStatus.isSetAside`), as its original undone back into Incoming, which a
    /// volume that keeps no file numbers would not tell from a copy that kept its date. Every document recorded there is
    /// looked at, as a copy that was a document of its own is recorded there too. A document set aside has its file at
    /// its path: another file put there ends, as it arrives (`enqueue`), every one set aside there whose file it is not
    /// (`replaced`); and no job of a copy is one set aside, as the queue takes none for a file set aside (`stays`), and
    /// the user sets none aside while it is read in.
    func isStill(_ copy: URL, payload: JobPayload) async throws -> Bool {
        guard let hashed = payload.fingerprint, let now = try? FileFingerprint.of(copy), now.matches(hashed) else { return false }
        return try await !services.documents.documents(path: copy.path).contains { $0.status.isSetAside }
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
