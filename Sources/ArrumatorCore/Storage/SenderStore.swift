import Foundation
import GRDB

/// The senders the app has learned, and what their documents show about them.
public struct SenderStore: Sendable {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func correspondents() async throws -> [Correspondent] {
        try await database.reader.read { db in
            try CorrespondentRecord.order(Column("canonical_name")).fetchAll(db).map(\.correspondent)
        }
    }

    /// Saves a sender; a new one named like a known one is that one.
    @discardableResult
    public func saveCorrespondent(_ correspondent: Correspondent) async throws -> Correspondent {
        try await database.writer.write { db in
            var r = CorrespondentRecord(correspondent)
            if let existing = try CorrespondentRecord.filter(Column("canonical_name") == correspondent.canonicalName).fetchOne(db),
               r.id == nil {
                r.id = existing.id
                r.createdAt = existing.createdAt
            }
            try r.save(db)
            return r.correspondent
        }
    }

    public func linkCorrespondent(documentID: Int64, correspondentID: Int64, name: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET correspondent_id = ?, correspondent = ?, updated_at = ? WHERE id = ?",
                           arguments: [correspondentID, name, Date().unixSeconds, documentID])
        }
    }

    /// Forgets a sender; its documents keep the name they were filed under.
    public func deleteCorrespondent(id: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET correspondent_id = NULL WHERE correspondent_id = ?", arguments: [id])
            _ = try CorrespondentRecord.deleteOne(db, key: id)
        }
    }

    /// Identifiers (`StableKey.token`) on the filed documents of each sender, by sender: how many of the sender's
    /// documents show each one. Read from what was extracted from each document.
    public func identifiersBySender() async throws -> [Int64: [String: Int]] {
        try await database.reader.read { db in
            var counts: [Int64: [String: Int]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT d.correspondent_id AS sender, json_extract(k.value, '$.kind') || ':' || json_extract(k.value, '$.value') AS token,
                       COUNT(DISTINCT d.id) AS n
                FROM documents d, json_each(d.content_json, '$.entities.stableKeys') k
                WHERE d.correspondent_id IS NOT NULL AND d.status = ?
                GROUP BY 1, 2
                """, arguments: [DocumentStatus.filed.rawValue]) {
                counts[row["sender"], default: [:]][row["token"]] = row["n"]
            }
            return counts
        }
    }

    /// How many filed documents are the sender's.
    public func filedCount(correspondentID: Int64) async throws -> Int {
        try await database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents WHERE correspondent_id = ? AND status = ?",
                             arguments: [correspondentID, DocumentStatus.filed.rawValue]) ?? 0
        }
    }

    /// Which of these facts the app still knows.
    public func known(_ facts: [LearnedFact]) async throws -> Set<LearnedFact> {
        try await database.reader.read { db in
            let correspondents = try CorrespondentRecord.fetchAll(db).compactMap { r in r.id.map { ($0, r.correspondent) } }
            let byID = Dictionary(uniqueKeysWithValues: correspondents)
            return Set(facts.filter { fact in
                switch fact {
                case let .alias(correspondentID, alias): byID[correspondentID]?.aliases.contains(alias) ?? false
                case let .sender(correspondentID): byID[correspondentID] != nil
                }
            })
        }
    }
}
