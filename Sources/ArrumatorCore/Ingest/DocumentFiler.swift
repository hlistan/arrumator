import Foundation
import GRDB

/// Moves a document to where it belongs, names it, and records the outcome in one place (ingest and review).
public struct DocumentFiler: Sendable {
    public let database: AppDatabase
    public let placer: Placer
    public let index: IndexStore
    public let registry: SelfChangeRegistry
    public let time: any TimeSource

    public init(database: AppDatabase, placer: Placer, index: IndexStore, registry: SelfChangeRegistry, time: any TimeSource) {
        self.database = database
        self.placer = placer
        self.index = index
        self.registry = registry
        self.time = time
    }

    /// - Parameters:
    ///   - directory: where the document goes: the top of the archive for a new arrival, its own directory for one
    ///     already in the archive, which is renamed where it is.
    ///   - inPlace: adopt the file where it is (the user put it there), without moving or renaming it.
    ///   - event: the history kind to record; nil follows `status` (filed, or waiting for the user).
    ///   - recording: runs in the transaction that records the filing, with the document as filed, so what the caller
    ///     keeps of it (a job's destination) commits with it or not at all.
    ///
    /// Filing, once begun, is finished, whatever the caller is asked meanwhile. A stop of the caller's task (the worker's,
    /// when the app quits) cancels the database accesses it makes after it ("`CancellationError` if the task is
    /// cancelled", GRDB's `DatabaseWriter.write`), so one that came between the move and its record would leave the file
    /// in the archive with its record still saying where it was, where the job that moved it could no longer find it.
    /// The move and its record therefore run as a task of their own: "an unstructured task doesn't have a parent task"
    /// (The Swift Programming Language › Concurrency › Unstructured Concurrency), and cancelling a task reaches only its
    /// children. A stop asked for before filing begins leaves the file where it is.
    public func file(_ document: DocumentRecord, source: SourceFile, analysis: DocumentAnalysis, status: DocumentStatus,
                     directory: URL, inPlace: Bool, actor: EventActor, settings: AppSettings, trace: TraceContext,
                     event: EventKind?, recording: (@Sendable (Database, DocumentRecord) throws -> Void)?) async throws -> DocumentRecord {
        guard let docID = document.id else { throw IngestError.documentNotPersisted }
        try Task.checkCancellation()
        return try await Task {
            try await place(document, docID: docID, source: source, analysis: analysis, status: status, directory: directory,
                            inPlace: inPlace, actor: actor, settings: settings, trace: trace, event: event, recording: recording)
        }.value
    }

    /// Moves the document and records where it went, as `file` describes.
    private func place(_ document: DocumentRecord, docID: Int64, source: SourceFile, analysis: DocumentAnalysis, status: DocumentStatus,
                       directory: URL, inPlace: Bool, actor: EventActor, settings: AppSettings, trace: TraceContext,
                       event: EventKind?, recording: (@Sendable (Database, DocumentRecord) throws -> Void)?) async throws -> DocumentRecord {
        var newPath = document.path
        if inPlace {
            do { try Xattr.set(Xattr.documentID, document.uid, on: document.url) } catch {
                // Without its identity the file is still filed; a move in Finder then reads as a new file.
                Log.warning(.fileops, "Could not tag adopted document", ["path": document.path, "error": error.localizedDescription])
            }
        } else {
            let plan = await trace.measure(.name, input: ["modelName": analysis.fileName ?? ""], output: { (p: PlacementPlan) in p }) {
                placer.plan(analysis: analysis, source: source, directory: directory, settings: settings)
            }
            let planned = URL(fileURLWithPath: plan.directory).appendingPathComponent(plan.filename).path
            if planned != document.path {
                await registry.expect([planned, document.path])
                let result = try await trace.measure(.place, input: plan, output: { (m: MoveResult) in m }) {
                    try placer.execute(plan, source: document.url, sha256: document.sha256, documentUID: document.uid,
                                       originalName: document.originalFilename, filedAt: time.now())
                }
                await registry.expect([result.to])
                newPath = result.to
            }
        }
        let filedName = (newPath as NSString).lastPathComponent
        let finalPath = newPath
        let now = time.now()
        let updated: DocumentRecord = try await database.writer.write { db in
            guard var d = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
            d.path = finalPath
            d.status = status
            d.inode = FileFingerprint.inode(of: URL(fileURLWithPath: finalPath))
            d.analysisJson = JSON.string(analysis)
            d.filedAt = now
            d.updatedAt = now
            try d.update(db)
            let kind = event ?? (status == .needsReview ? .needsReview : .filed)
            try HistoryStore.insert(db, kind, at: now, actor: actor, doc: docID, trace: trace.traceID,
                                    summary: "\(document.originalFilename) → \(filedName)",
                                    payload: FiledPayload(from: document.path, to: finalPath, problems: analysis.problems))
            try recording?(db, d)
            return d
        }
        try await index.updateFilename(docID: docID, filename: filedName)
        return updated
    }
}

public struct FiledPayload: Sendable, Codable, Hashable {
    public var from: String
    public var to: String
    /// Why the document waits for the user, when it does.
    public var problems: [String]
}

extension DocumentRecord {
    /// The file as it is known before it is read: what filing a document the pipeline could not process, parked after
    /// failing, names it from.
    var unreadSource: SourceFile {
        SourceFile(path: path, originalFilename: originalFilename, fileExtension: (originalFilename as NSString).pathExtension,
                   utType: uttype, byteSize: size, createdAt: nil, modifiedAt: fileMtime, sha256: sha256)
    }
}
