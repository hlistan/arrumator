import Foundation
import GRDB

public enum RethinkRunStatus: String, Sendable, Codable {
    /// Every filed document is being decided again.
    case planning
    /// Every document has been decided; the changes wait for the user to apply or discard them.
    case ready
    case applying
    case applied
    case discarded
    /// Every document has been decided and none of them would change, so there was nothing for the user to decide.
    case settled

    /// A run in one of these states blocks starting another.
    public var isActive: Bool { [.planning, .ready, .applying].contains(self) }
}

/// How much a rethink covers.
public enum RethinkScope: String, Sendable, Codable {
    /// A few documents from across the archive, to see what changed logic would do.
    case trial
    /// Every processed document.
    case all
}

public enum RethinkItemStatus: String, Sendable, Codable, CaseIterable {
    /// Not decided yet.
    case pending
    /// A different folder or name fits the logic better.
    case move
    /// Already where the logic would put it.
    case unchanged
    /// The model was not sure. The document stays where it is unless the user picks the place the logic suggested.
    case unsure
    case failed
    /// Moved when the plan was applied.
    case applied
    /// Left alone when applying: the user deselected it, or it changed after the plan was made.
    case skipped
    /// Planning was stopped before the document was decided; it stays where it is.
    case notDecided
}

/// One rethink: filed documents decided again from the archive's logic, planned first and applied on request.
public struct RethinkRunRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "rethink_runs"
    public var id: Int64?
    public var status: RethinkRunStatus
    public var scope: RethinkScope
    public var includeUserPlaced: Bool
    /// Fingerprint of the logic the plan was made with.
    public var logicVersion: String
    public var plannedFoldersJson: String
    public var summary: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// The folders the plan would create. A plan an earlier version wrote in another shape is reported, never read as
    /// planning no folders, which would move documents into folders that do not exist.
    public func plannedFolders() throws -> [PlannedFolder] {
        guard let folders = JSON.decode([PlannedFolder].self, from: plannedFoldersJson) else {
            throw RethinkError.unreadablePlan(id ?? 0)
        }
        return folders
    }
}

/// What a rethink decided for one document.
public struct RethinkItemRecord: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "rethink_items"
    public var id: Int64?
    public var runId: Int64
    public var docId: Int64
    public var status: RethinkItemStatus
    /// Whether applying the plan moves this document; the user can leave single documents where they are.
    public var selected: Bool
    public var fromFolderId: Int64?
    public var fromPath: String
    public var targetCode: String?
    public var targetPath: String?
    public var decisionJson: String?
    public var traceId: Int64?
    public var error: String?
    public var updatedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var decision: FilingDecision? { JSON.decode(FilingDecision.self, from: decisionJson) }

    /// Whether the plan can move this document: a move, or an unsure document the logic still suggested a place for.
    /// Everything else stays where it is whatever the user ticks.
    public var canMove: Bool {
        guard status == .move || status == .unsure, let targetPath else { return false }
        return targetPath != fromPath
    }

    /// The document moves only because the user picked it: the logic was not sure enough to move it by itself.
    public var isUserChoice: Bool { status == .unsure && canMove }
}

/// A folder a plan intends to create, with its code reserved: inside an existing folder, inside another planned one,
/// or at the top of the archive. Plans list them parents first.
public struct PlannedFolder: Sendable, Codable, Hashable {
    public var code: String
    public var name: String
    public var description: String
    /// Existing or planned; nil at the top of the archive.
    public var parentCode: String?
    public var yearSubfolders: Bool
    public var yearRule: YearRule?
    /// What the folder stands for in the logic the plan follows, and that logic's `LogicStore.version`.
    public var kind: LevelKind?
    public var logic: String?
    /// The senders and types of the documents the plan puts in it, so the plan's later documents from them join it.
    public var senders: Set<Int64>
    public var documentTypes: Set<DocumentType>
}

public enum RethinkError: Error, LocalizedError {
    case alreadyActive
    case noActiveRun
    case notReady(RethinkRunStatus)
    case notPlanning(RethinkRunStatus)
    case cannotMove(Int64)
    case unreadablePlan(Int64)

    public var errorDescription: String? {
        switch self {
        case .alreadyActive: "A rethink is already under way; apply or discard it first"
        case .noActiveRun: "There is no rethink to act on"
        case let .notReady(status): "The rethink is \(status.rawValue), not ready to apply"
        case let .notPlanning(status): "The rethink is \(status.rawValue); only a plan still being made can be stopped"
        case let .cannotMove(item): "Plan item #\(item) stays where it is; there is nowhere to move it"
        case let .unreadablePlan(run): "Rethink #\(run) was planned by an earlier version and cannot be read; discard it and plan again"
        }
    }
}

public struct RethinkStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    public func activeRun() async throws -> RethinkRunRecord? {
        try await database.reader.read { db in
            try RethinkRunRecord.filter([RethinkRunStatus.planning, .ready, .applying].map(\.rawValue).contains(Column("status")))
                .order(Column("started_at").desc).fetchOne(db)
        }
    }

    public func latestRun() async throws -> RethinkRunRecord? {
        try await database.reader.read { db in try RethinkRunRecord.order(Column("started_at").desc).fetchOne(db) }
    }

    /// Filed documents a rethink may move. Documents the user placed or confirmed where they are stay out unless
    /// `includeUserPlaced`.
    public func candidates(includeUserPlaced: Bool) async throws -> [DocumentRecord] {
        try await database.reader.read { db in
            try DocumentRecord.fetchAll(db, sql: """
                SELECT d.* FROM documents d JOIN folders f ON f.id = d.folder_id
                WHERE d.status = ? AND f.role IS NULL AND f.is_archived = 0
                  AND (? OR (COALESCE(d.decided_by, '') != ?
                       AND NOT EXISTS (SELECT 1 FROM corrections c WHERE c.doc_id = d.id AND c.to_folder_id = d.folder_id)))
                ORDER BY d.filed_at, d.id
                """, arguments: [DocumentStatus.filed.rawValue, includeUserPlaced, DecidedBy.user.rawValue])
        }
    }

    /// Starts a run with one pending item per document.
    public func createRun(scope: RethinkScope, includeUserPlaced: Bool, logicVersion: String,
                          documents: [DocumentRecord]) async throws -> RethinkRunRecord {
        try await database.writer.write { db in
            let now = Date()
            var run = RethinkRunRecord(id: nil, status: .planning, scope: scope, includeUserPlaced: includeUserPlaced,
                                       logicVersion: logicVersion,
                                       plannedFoldersJson: "[]", summary: nil, startedAt: now, finishedAt: nil)
            try run.insert(db)
            guard let runID = run.id else { throw RethinkError.noActiveRun }
            for document in documents {
                guard let docID = document.id else { continue }
                var item = RethinkItemRecord(id: nil, runId: runID, docId: docID, status: .pending, selected: true,
                                             fromFolderId: document.folderId, fromPath: document.path, targetCode: nil, targetPath: nil,
                                             decisionJson: nil, traceId: nil, error: nil, updatedAt: now)
                try item.insert(db)
            }
            let summary = scope == .trial ? "Trying the logic on \(Format.count(documents.count, "document"))"
                : "Reprocessing \(Format.count(documents.count, "document")) with the logic"
            try HistoryStore.insert(db, .rethink, actor: .user, summary: summary, payload: ["run": runID])
            return run
        }
    }

    public func items(runID: Int64, statuses: Set<RethinkItemStatus>? = nil) async throws -> [RethinkItemRecord] {
        try await database.reader.read { db in
            var request = RethinkItemRecord.filter(Column("run_id") == runID)
            if let statuses { request = request.filter(statuses.map(\.rawValue).contains(Column("status"))) }
            return try request.order(Column("id")).fetchAll(db)
        }
    }

    public func item(id: Int64) async throws -> RethinkItemRecord? {
        try await database.reader.read { db in try RethinkItemRecord.fetchOne(db, key: id) }
    }

    /// The planned folders that applying would create for the ticked documents that can move, and the planned folders
    /// they are in, in plan order.
    public static func folders(_ planned: [PlannedFolder], neededBy items: [RethinkItemRecord]) -> [PlannedFolder] {
        let byCode = Dictionary(planned.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        var needed = Set<String>()
        for target in items.filter({ $0.selected && $0.canMove }).compactMap(\.targetCode) {
            var code: String? = target
            while let current = code, let folder = byCode[current], needed.insert(current).inserted { code = folder.parentCode }
        }
        return planned.filter { needed.contains($0.code) }
    }

    /// Where a planned folder would be, by name from the top of the archive, through existing and planned folders.
    public static func path(of folder: PlannedFolder, planned: [PlannedFolder], taxonomy: TaxonomySnapshot?,
                            separator: String = TaxonomySnapshot.pathSeparator) -> String {
        var names = [folder.name]
        var code = folder.parentCode
        var seen: Set<String> = [folder.code]
        while let current = code, seen.insert(current).inserted {
            if let parent = planned.first(where: { $0.code == current }) {
                names.insert(parent.name, at: 0)
                code = parent.parentCode
            } else if let existing = taxonomy?.folder(code: current), let taxonomy {
                names.insert(taxonomy.path(of: existing, separator: separator), at: 0)
                code = nil
            } else {
                code = nil
            }
        }
        return names.joined(separator: separator)
    }

    public func nextPending(runID: Int64) async throws -> RethinkItemRecord? {
        try await database.reader.read { db in
            try RethinkItemRecord.filter(Column("run_id") == runID && Column("status") == RethinkItemStatus.pending.rawValue)
                .order(Column("id")).fetchOne(db)
        }
    }

    public func counts(runID: Int64) async throws -> [RethinkItemStatus: Int] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS n FROM rethink_items WHERE run_id = ? GROUP BY status",
                                        arguments: [runID])
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                RethinkItemStatus(rawValue: row["status"]).map { ($0, row["n"] as Int) }
            })
        }
    }

    /// Records a document's decision, unless planning was stopped meanwhile and left the document out: a decision
    /// that arrives late, from this process or another, never changes a plan the user has already seen finished.
    public func decide(_ item: RethinkItemRecord) async throws {
        try await database.writer.write { db in
            guard let id = item.id,
                  try RethinkItemRecord.filter(key: id).filter(Column("status") == RethinkItemStatus.pending.rawValue).fetchCount(db) > 0
            else { return }
            var i = item
            i.updatedAt = Date()
            try i.update(db)
        }
    }

    /// Leaves every document not decided yet out of the plan; returns how many there were.
    @discardableResult
    public func leaveUndecidedOut(runID: Int64) async throws -> Int {
        try await database.writer.write { db in
            try RethinkItemRecord.filter(Column("run_id") == runID && Column("status") == RethinkItemStatus.pending.rawValue)
                .updateAll(db, Column("status").set(to: RethinkItemStatus.notDecided.rawValue), Column("selected").set(to: false),
                           Column("updated_at").set(to: Date().unixSeconds))
        }
    }

    public func save(_ item: RethinkItemRecord) async throws {
        try await database.writer.write { db in
            var i = item
            i.updatedAt = Date()
            try i.save(db)
        }
    }

    /// Updates only the planned folders, so planning can never undo a discard made meanwhile.
    public func setPlannedFolders(runID: Int64, _ folders: [PlannedFolder]) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE rethink_runs SET planned_folders_json = ? WHERE id = ?", arguments: [JSON.string(folders), runID])
        }
    }

    public func setStatus(runID: Int64, _ status: RethinkRunStatus) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE rethink_runs SET status = ? WHERE id = ?", arguments: [status.rawValue, runID])
        }
    }

    /// Records the run's new state together with a history line, so the change shows up everywhere at once.
    public func finish(_ run: RethinkRunRecord, status: RethinkRunStatus, summary: String,
                       by actor: EventActor) async throws -> RethinkRunRecord {
        try await database.writer.write { db in
            var r = run
            r.status = status
            r.summary = summary
            r.finishedAt = status == .ready ? nil : Date()
            try r.save(db)
            try HistoryStore.insert(db, .rethink, actor: actor, summary: summary, payload: ["run": r.id])
            return r
        }
    }

    public func setSelected(itemID: Int64, _ selected: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE rethink_items SET selected = ?, updated_at = ? WHERE id = ?",
                           arguments: [selected, Date().unixSeconds, itemID])
        }
    }
}
