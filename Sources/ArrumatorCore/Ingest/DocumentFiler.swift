import Foundation
import GRDB

/// Moves a document to its folder and records the outcome in one place (used by ingest, review and Move to…).
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
    ///   - inPlace: adopt the file where it is (user put it there), without moving or renaming.
    ///   - event: the history kind to record; by default it follows `status` (filed, or waiting for review).
    public func file(_ document: DocumentRecord, source: SourceFile, decision: FilingDecision, folderCode: String,
                     status: DocumentStatus, userChosen: Bool, inPlace: Bool, taxonomy: TaxonomySnapshot,
                     settings: AppSettings, trace: TraceContext, event: EventKind? = nil) async throws -> DocumentRecord {
        guard let docID = document.id else { throw IngestError.documentNotPersisted }
        var plan = try await trace.measure(.name, input: ["folder": folderCode, "modelName": decision.fileName ?? ""],
                                           output: { (p: PlacementPlan) in p }) {
            try placer.plan(decision: decision, folderCode: folderCode, source: source, taxonomy: taxonomy,
                            settings: settings, userChosen: userChosen)
        }
        var newPath = document.path
        if inPlace {
            plan.directory = document.url.deletingLastPathComponent().path
            plan.filename = document.filename
        } else {
            let planned = URL(fileURLWithPath: plan.directory).appendingPathComponent(plan.filename).path
            await registry.expect([planned, document.path])
            let result = try await trace.measure(.place, input: plan, output: { (m: MoveResult) in m }) {
                try placer.execute(plan, source: document.url, sha256: document.sha256, documentUID: document.uid,
                                   originalName: document.originalFilename)
            }
            await registry.expect([result.to])
            newPath = result.to
        }
        if inPlace {
            try? Xattr.set(Xattr.documentID, document.uid, on: document.url)
        }
        let filedName = (newPath as NSString).lastPathComponent
        let finalPlan = plan
        let finalPath = newPath
        let updated: DocumentRecord = try await database.writer.write { db in
            guard var d = try DocumentRecord.fetchOne(db, key: docID) else { throw IngestError.documentNotFound(docID) }
            let now = Date()
            d.path = finalPath
            d.folderId = finalPlan.folderID
            d.status = status
            d.inode = FileFingerprint.inode(of: URL(fileURLWithPath: finalPath))
            d.correspondent = decision.correspondent
            d.correspondentId = decision.correspondentID
            d.docType = decision.documentType.rawValue
            d.docDate = decision.documentDate
            d.periodYear = decision.periodYear
            d.title = decision.title
            d.language = decision.language
            d.band = decision.band.rawValue
            d.confidence = decision.confidence.final
            d.decidedBy = decision.decidedBy.rawValue
            d.rationale = decision.rationale
            d.decisionJson = JSON.string(decision)
            d.tagsJson = JSON.string(decision.tags)
            d.filedAt = now
            d.updatedAt = now
            try d.update(db)
            let kind = event ?? (status == .needsReview ? .needsReview : .filed)
            try HistoryStore.insert(db, kind, actor: userChosen ? .user : .system, doc: docID, trace: trace.traceID,
                                    summary: "\(document.originalFilename) → \(finalPlan.folderCode)\(finalPlan.yearFolder.map { "/\($0)" } ?? "")/\(filedName)",
                                    payload: FiledPayload(from: document.path, to: finalPath, folder: finalPlan.folderCode,
                                                          band: decision.band.rawValue, confidence: decision.confidence.final,
                                                          decidedBy: decision.decidedBy.rawValue, rationale: decision.rationale))
            return d
        }
        try await index.updateHeader(docID: docID, title: decision.title, correspondent: decision.correspondent ?? "",
                                     filename: filedName)
        return updated
    }
}

public struct FiledPayload: Sendable, Codable, Hashable {
    public var from: String
    public var to: String
    public var folder: String
    public var band: String
    public var confidence: Double
    public var decidedBy: String
    public var rationale: String
}
