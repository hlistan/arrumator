import Foundation
import GRDB

/// Moves a document to where it belongs, names it, and records the outcome in one place (ingest and review).
public struct DocumentFiler: Sendable {
    public let database: AppDatabase
    public let placer: Placer
    public let index: IndexStore
    public let registry: SelfChangeRegistry

    public init(database: AppDatabase, placer: Placer, index: IndexStore, registry: SelfChangeRegistry) {
        self.database = database
        self.placer = placer
        self.index = index
        self.registry = registry
    }

    /// - Parameters:
    ///   - directory: where the document goes: the top of the archive for a new arrival, its own directory for one
    ///     already in the archive, which is renamed where it is.
    ///   - inPlace: adopt the file where it is (the user put it there), without moving or renaming it.
    ///   - event: the history kind to record; by default it follows `status` (filed, or waiting for the user).
    public func file(_ document: DocumentRecord, source: SourceFile, analysis: DocumentAnalysis, status: DocumentStatus,
                     directory: URL, inPlace: Bool, actor: EventActor, settings: AppSettings, trace: TraceContext,
                     event: EventKind? = nil) async throws -> DocumentRecord {
        guard let docID = document.id else { throw IngestError.documentNotPersisted }
        var newPath = document.path
        if inPlace {
            try? Xattr.set(Xattr.documentID, document.uid, on: document.url)
        } else {
            let plan = await trace.measure(.name, input: ["modelName": analysis.fileName ?? ""], output: { (p: PlacementPlan) in p }) {
                placer.plan(analysis: analysis, source: source, directory: directory, settings: settings)
            }
            let planned = URL(fileURLWithPath: plan.directory).appendingPathComponent(plan.filename).path
            if planned != document.path {
                await registry.expect([planned, document.path])
                let result = try await trace.measure(.place, input: plan, output: { (m: MoveResult) in m }) {
                    try placer.execute(plan, source: document.url, sha256: document.sha256, documentUID: document.uid,
                                       originalName: document.originalFilename)
                }
                await registry.expect([result.to])
                newPath = result.to
            }
        }
        let filedName = (newPath as NSString).lastPathComponent
        let finalPath = newPath
        let updated: DocumentRecord = try await database.writer.write { db in
            guard var d = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
            let now = Date()
            d.path = finalPath
            d.status = status
            d.inode = FileFingerprint.inode(of: URL(fileURLWithPath: finalPath))
            d.correspondent = analysis.correspondent
            d.correspondentId = analysis.correspondentID
            d.docType = analysis.documentType.rawValue
            d.docDate = analysis.documentDate
            d.periodYear = analysis.periodYear
            d.title = analysis.title
            d.language = analysis.language
            d.analysisJson = JSON.string(analysis)
            d.filedAt = now
            d.updatedAt = now
            try d.update(db)
            let kind = event ?? (status == .needsReview ? .needsReview : .filed)
            try HistoryStore.insert(db, kind, actor: actor, doc: docID, trace: trace.traceID,
                                    summary: "\(document.originalFilename) → \(filedName)",
                                    payload: FiledPayload(from: document.path, to: finalPath, problems: analysis.problems))
            return d
        }
        try await index.updateHeader(docID: docID, title: analysis.title, correspondent: analysis.correspondent ?? "",
                                     filename: filedName)
        return updated
    }
}

public struct FiledPayload: Sendable, Codable, Hashable {
    public var from: String
    public var to: String
    /// Why the document waits for the user, when it does.
    public var problems: [String]
}
