import Foundation

/// What a file that arrives in Incoming is to the documents recorded where it is (`IngestCoordinator.enqueue`).
extension IngestCoordinator {
    /// What became of a file that arrives (`arrive`).
    enum Arrival: Equatable {
        /// The file of a document recorded there, left where it is (`stays`).
        case stays
        /// Queued, or found queued already.
        case queued(JobStore.Queued)
        /// The document found left in Incoming changed before the write that would queue the file: nothing is decided.
        case changed
    }

    /// Decides what the file at `url` is. Whose file it is is asked of every document recorded there whose file it may
    /// be: one set aside, or left in Incoming. One whose file it is stays as it is, and the file with it; once all are
    /// asked, every one set aside whose file it is not is ended (`replaced`), another file having come in its place, so
    /// none is left recorded where its file is not (`isStill`). Otherwise the file is queued (`queue`): a file put where
    /// a document was left in Incoming, as an editor saving it, is that document arriving again.
    func arrive(_ url: URL, payload: JobPayload) async throws -> Arrival {
        let path = url.path
        let known = try await services.documents.document(path: path)
        var stayed = false
        var gone: [DocumentRecord] = []
        for document in try await services.documents.documents(path: path) where document.status.isSetAside || isLeftInIncoming(document) {
            if try await stays(document, at: url) { stayed = true } else { gone.append(document) }
        }
        for document in gone { try await replaced(document) }
        if stayed { return .stays }
        let again = known.flatMap { isLeftInIncoming($0) ? $0 : nil }
        return try await queue(path, again: again, payload: payload).map(Arrival.queued) ?? .changed
    }

    /// Queues the file at `path` to be read in, as document `again`, left in Incoming, arriving again (its reading
    /// forgotten, `IndexStore.forgetReading`), or as a new file, in one write: only while `again` is as it was found,
    /// as the user may leave it for later or read it again meanwhile; nil, and nothing queued, when it is not.
    func queue(_ path: String, again: DocumentRecord?, payload: JobPayload) async throws -> JobStore.Queued? {
        let now = services.time.now()
        return try await services.database.writer.write { db in
            if let again, let id = again.id {
                guard let read = try DocumentRecord.fetchOne(db, key: id), read.status == again.status else { return nil }
                try IndexStore.forgetReading(db, of: read, at: now)
            }
            return try JobStore.enqueue(db, path: path, kind: .ingest, docID: again?.id, payload: payload, givesWay: false, at: now)
        }
    }
}
