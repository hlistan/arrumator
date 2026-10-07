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
    ///   - archive: the archive the document is filed into, the runtime's own (`PipelineServices.archive`): its folder is
    ///     never made again where it is gone (`FileOperationError.folderMissing`).
    ///   - directory: where the document goes: the top of the archive for a new arrival, its own directory for one
    ///     already in the archive, which is renamed where it is.
    ///   - inPlace: adopt the file where it is (the user put it there), without moving or renaming it.
    ///   - fingerprint: what the file was when it was read, when that is known: one that has changed since is not
    ///     moved (`FileOperationError.sourceChanged`), as what was read of it is not what it holds.
    ///   - event: the history kind to record; nil follows `status` (filed, or waiting for the user).
    ///   - keeping: what the caller keeps of the filing, as a job its destination (`FilingKeeper`); nil for nothing.
    ///   - movedTo: where the document was moved already, by a filing whose record was cut off: it is recorded there and
    ///     moved no more.
    ///
    /// Filing, once begun, is finished, whatever the caller is asked meanwhile. A stop of the caller's task (the worker's,
    /// when the app quits) cancels the database accesses it makes after it ("`CancellationError` if the task is
    /// cancelled", GRDB's `DatabaseWriter.write`), so one that came between the move and its record would leave the file
    /// in the archive with its record still saying where it was, where the job that moved it could no longer find it.
    /// The move and its record therefore run as a task of their own: "an unstructured task doesn't have a parent task"
    /// (The Swift Programming Language › Concurrency › Unstructured Concurrency), and cancelling a task reaches only its
    /// children. A stop asked for before filing begins leaves the file where it is.
    public func file(_ document: DocumentRecord, archive: URL, analysis: DocumentAnalysis, status: DocumentStatus, directory: URL, inPlace: Bool,
                     fingerprint: FileFingerprint?, actor: EventActor, settings: AppSettings, trace: TraceContext,
                     event: EventKind?, keeping: FilingKeeper?, movedTo: String? = nil) async throws -> DocumentRecord {
        guard let docID = document.id else { throw IngestError.documentNotPersisted }
        try Task.checkCancellation()
        return try await Task {
            try await place(document, docID: docID, archive: archive, analysis: analysis, status: status, directory: directory, inPlace: inPlace,
                            fingerprint: fingerprint, actor: actor, settings: settings, trace: trace, event: event, keeping: keeping,
                            movedTo: movedTo)
        }.value
    }

    /// Moves the document and records where it went, as `file` describes. A document whose name stays its own where it
    /// is (`Placer.keeps`), as one read again whose reading names it as it is named, is not moved.
    private func place(_ document: DocumentRecord, docID: Int64, archive: URL, analysis: DocumentAnalysis, status: DocumentStatus, directory: URL,
                       inPlace: Bool, fingerprint: FileFingerprint?, actor: EventActor, settings: AppSettings, trace: TraceContext,
                       event: EventKind?, keeping: FilingKeeper?, movedTo: String?) async throws -> DocumentRecord {
        var newPath = document.path
        if let movedTo {
            newPath = movedTo
        } else if inPlace {
            do { try Xattr.set(Xattr.documentID, document.uid, on: document.url) } catch {
                // Without its identity the file is still filed; a move in Finder then reads as a new file.
                Log.warning(.fileops, "Could not tag adopted document", ["path": document.path, "error": error.localizedDescription])
            }
        } else {
            let plan = await trace.measure(.name, input: ["modelName": analysis.fileName ?? ""], output: { (p: PlacementPlan) in p }) {
                placer.plan(analysis: analysis, current: document.url, directory: directory, settings: settings)
            }
            if !placer.keeps(plan, at: document.url) {
                let planned = URL(fileURLWithPath: plan.directory).appendingPathComponent(plan.filename).path
                await registry.expect([planned, document.path])
                let destination = try placer.destination(of: plan)
                try await keeping?.planning(destination.url.path)
                let result = try await trace.measure(.place, input: plan, output: { (m: MoveResult) in m }) {
                    try placer.execute(to: destination, source: document.url, archive: archive, sha256: document.sha256,
                                       fingerprint: fingerprint, documentUID: document.uid, originalName: document.originalFilename,
                                       filedAt: time.now())
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
            let read = d
            d.path = finalPath
            d.status = status
            d.inode = FileFingerprint.inode(of: URL(fileURLWithPath: finalPath))
            d.analysisJson = try JSON.string(analysis)
            d.filedAt = now
            d.updatedAt = now
            try d.update(db)
            if try keeping?.recording(db, d) == .movedOnly {
                // The file is where it was moved; the rest is as the document was set aside meanwhile.
                var moved = read
                (moved.path, moved.inode, moved.updatedAt) = (finalPath, d.inode, now)
                try moved.update(db)
                try HistoryStore.insert(db, .filed, at: now, actor: actor, doc: docID, trace: trace.traceID,
                                        summary: Self.summary(named: document.filename, filedAs: filedName, problems: []) + Self.setAside,
                                        payload: FiledPayload(from: document.path, to: finalPath, problems: [], setAside: true))
                return moved
            }
            let kind = event ?? (status == .needsReview ? .needsReview : .filed)
            try HistoryStore.insert(db, kind, at: now, actor: actor, doc: docID, trace: trace.traceID,
                                    summary: Self.summary(named: document.filename, filedAs: filedName, problems: analysis.problems),
                                    payload: FiledPayload(from: document.path, to: finalPath, problems: analysis.problems))
            return d
        }
        try await index.updateFilename(docID: docID, filename: filedName)
        return updated
    }
}

extension DocumentFiler {
    /// What History adds to a move recorded alone (`FilingKept.movedOnly`).
    public static let setAside = "; set aside as it was renamed, it keeps the rest as it was"

    /// What History says of a filing: the name the file had when it was filed, as a document read again in the archive
    /// has its own, never the one it arrived under, and the name it was given, when that is another; that it kept its
    /// name, when it did; and why it waits for the user, when it does. Where it went is the event's payload
    /// (`FiledPayload`).
    static func summary(named name: String, filedAs filedName: String, problems: [String]) -> String {
        let waits = problems.isEmpty ? nil : "waits for you: " + DocumentAnalysis.said(problems)
        guard name != filedName else { return "\(filedName) " + (waits ?? "keeps its name") }
        return (["\(name) → \(filedName)"] + [waits].compactMap { $0 }).joined(separator: "; ")
    }
}

/// What the caller of a filing keeps of it, as a job keeps where its document went.
public struct FilingKeeper: Sendable {
    /// Runs with the path the document is moved to, before it is moved, so what the caller keeps of it (a job's planned
    /// destination) is there to find it by should the move not be recorded, as after a crash.
    public var planning: @Sendable (String) async throws -> Void
    /// Runs in the transaction that records the filing, with the document as filed, before the filing's event, so what
    /// the caller keeps of it (a job's destination, what a document read again was read as) commits with it or not at all;
    /// and says what of the filing stands (`FilingKept`).
    public var recording: @Sendable (Database, DocumentRecord) throws -> FilingKept

    public init(planning: @escaping @Sendable (String) async throws -> Void,
                recording: @escaping @Sendable (Database, DocumentRecord) throws -> FilingKept) {
        self.planning = planning
        self.recording = recording
    }
}

/// What of a filing stands, as its caller decides in the transaction that records it (`FilingKeeper.recording`).
public enum FilingKept: Sendable, Equatable {
    /// The filing, whole.
    case filed
    /// Where the file was moved, alone: the document was set aside meanwhile, as left for later while the move that
    /// filed it was made, and keeps the rest as the user left it.
    case movedOnly
}

public struct FiledPayload: Sendable, Codable, Hashable {
    public var from: String
    public var to: String
    /// Why the document waits for the user, when it does.
    public var problems: [String]
    /// Whether only the file's new place is recorded, the document set aside as its file was renamed, as when it was left
    /// for later in that instant (`FilingKept.movedOnly`): no filing to announce. Nil for a filing, as before it was
    /// written.
    public var setAside: Bool?

    public init(from: String, to: String, problems: [String], setAside: Bool? = nil) {
        self.from = from
        self.to = to
        self.problems = problems
        self.setAside = setAside
    }
}

extension EventRecord {
    /// Whether the event says a document was filed, to be announced as filed: a filing, not the new place of a file whose
    /// document was set aside as it was renamed (`FiledPayload.setAside`).
    public var announcesFiling: Bool {
        kind == .filed && JSON.decode(FiledPayload.self, from: payloadJson)?.setAside != true
    }
}
