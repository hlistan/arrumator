import Foundation
import GRDB

public struct GRDBLearningStore: LearningStore {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    // MARK: Memories

    public func memories(model: String) async throws -> [FilingMemory] {
        try await database.reader.read { db in
            try MemoryRecord.filter(Column("model") == model).filter(Column("orphaned") == false).fetchAll(db).map(\.memory)
        }
    }

    /// The documents the app files by as examples of their folders, most recently learned first, with the memory each
    /// is known by: what the Learned page lists, each one a thing the user can make the app forget.
    public func examples(limit: Int) async throws -> [LearnedExample] {
        try await database.reader.read { db in
            let memories = try MemoryRecord.fetchAll(db, sql: """
                SELECT * FROM memories WHERE orphaned = 0
                  AND id IN (SELECT MAX(id) FROM memories WHERE orphaned = 0 GROUP BY doc_id)
                ORDER BY created_at DESC, id DESC LIMIT ?
                """, arguments: [limit]).map(\.memory)
            let documents = Dictionary(
                try DocumentRecord.filter(keys: memories.map(\.documentID)).fetchAll(db).compactMap { d in d.id.map { ($0, d) } },
                uniquingKeysWith: { a, _ in a })
            return memories.compactMap { memory in documents[memory.documentID].map { LearnedExample(document: $0, memory: memory) } }
        }
    }

    public func memories(correspondentID: Int64) async throws -> [FilingMemory] {
        try await database.reader.read { db in
            try MemoryRecord.filter(Column("correspondent_id") == correspondentID).filter(Column("orphaned") == false)
                .order(Column("created_at").desc).fetchAll(db).map(\.memory)
        }
    }

    public func memories(folderID: Int64, limit: Int) async throws -> [FilingMemory] {
        try await database.reader.read { db in
            try MemoryRecord.filter(Column("folder_id") == folderID).filter(Column("orphaned") == false)
                .order(Column("created_at").desc).limit(limit).fetchAll(db).map(\.memory)
        }
    }

    @discardableResult
    public func insertMemory(_ memory: FilingMemory) async throws -> FilingMemory {
        try await database.writer.write { db in
            var r = MemoryRecord(id: nil, docId: memory.documentID, folderId: memory.folderID, folderCode: memory.folderCode,
                                 embedding: VectorCodec.encode(memory.embedding), model: memory.embeddingModel,
                                 summaryLine: memory.summaryLine, correspondentId: memory.correspondentID,
                                 docType: memory.documentType.rawValue, language: memory.language,
                                 stableKeysJson: JSON.string(memory.stableKeys), weight: memory.weight, source: memory.source,
                                 orphaned: false, createdAt: memory.createdAt)
            try r.insert(db)
            var m = memory
            m.id = r.id ?? 0
            return m
        }
    }

    @discardableResult
    public func deleteMemories(documentID: Int64) async throws -> [Int64] {
        try await database.writer.write { db in
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM memories WHERE doc_id = ?", arguments: [documentID])
            try db.execute(sql: "DELETE FROM memories WHERE doc_id = ?", arguments: [documentID])
            return ids
        }
    }

    @discardableResult
    public func confirmMemories(documentID: Int64, weight: Double, source: String) async throws -> [FilingMemory] {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE memories SET weight = MAX(weight, ?), source = ? WHERE doc_id = ?",
                           arguments: [weight, source, documentID])
            return try MemoryRecord.filter(Column("doc_id") == documentID).fetchAll(db).map(\.memory)
        }
    }

    @discardableResult
    public func settleMemories(before: Date, weight: Double, source: String) async throws -> [FilingMemory] {
        let moved = CorrectionSource.allCases.filter { $0 != .markCorrect }.map(\.rawValue)
        return try await database.writer.write { db in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT m.id FROM memories m
                JOIN documents d ON d.id = m.doc_id AND d.status = 'filed' AND d.folder_id = m.folder_id
                WHERE m.weight < ? AND m.created_at < ? AND m.orphaned = 0
                  AND NOT EXISTS (SELECT 1 FROM corrections c WHERE c.doc_id = m.doc_id
                                  AND c.source IN (\(databaseQuestionMarks(count: moved.count))))
                """, arguments: StatementArguments([weight, before.unixSeconds] as [any DatabaseValueConvertible] + moved))
            guard !ids.isEmpty else { return [] }
            try db.execute(sql: "UPDATE memories SET weight = ?, source = ? WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                           arguments: StatementArguments([weight, source] as [any DatabaseValueConvertible] + ids))
            return try MemoryRecord.filter(ids.contains(Column("id"))).fetchAll(db).map(\.memory)
        }
    }

    @discardableResult
    public func setMemoryEmbeddings(documentID: Int64, vector: [Float], model: String) async throws -> [FilingMemory] {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE memories SET embedding = ?, model = ? WHERE doc_id = ?",
                           arguments: [VectorCodec.encode(vector), model, documentID])
            return try MemoryRecord.filter(Column("doc_id") == documentID).fetchAll(db).map(\.memory)
        }
    }

    @discardableResult
    public func pruneMemories(folderID: Int64, keep: Int) async throws -> [Int64] {
        try await database.writer.write { db in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT id FROM memories WHERE folder_id = ? ORDER BY weight DESC, created_at DESC LIMIT -1 OFFSET ?
                """, arguments: [folderID, keep])
            if !ids.isEmpty {
                try db.execute(sql: "DELETE FROM memories WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                               arguments: StatementArguments(ids))
            }
            return ids
        }
    }

    public func setMemoriesOrphaned(folderID: Int64, orphaned: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE memories SET orphaned = ? WHERE folder_id = ?", arguments: [orphaned, folderID])
        }
    }

    // MARK: Rules

    public func rules() async throws -> [FilingRule] {
        try await database.reader.read { db in
            try RuleRecord.order(Column("priority"), Column("created_at").desc).fetchAll(db).compactMap(\.rule)
        }
    }

    @discardableResult
    public func saveRule(_ rule: FilingRule) async throws -> FilingRule {
        try await database.writer.write { db in
            var r = RuleRecord(rule)
            try r.save(db)
            return r.rule ?? rule
        }
    }

    public func recordRuleHit(ruleID: Int64, at: Date) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE rules SET hits = hits + 1, last_hit_at = ?, updated_at = ? WHERE id = ?",
                           arguments: [at.timeIntervalSince1970, at.timeIntervalSince1970, ruleID])
        }
    }

    // MARK: Correspondents

    public func correspondents() async throws -> [Correspondent] {
        try await database.reader.read { db in
            try CorrespondentRecord.order(Column("canonical_name")).fetchAll(db).map(\.correspondent)
        }
    }

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

    // MARK: Corrections

    @discardableResult
    public func insertCorrection(_ correction: CorrectionEvent) async throws -> Int64 {
        try await database.writer.write { db in
            var r = CorrectionRecord(id: nil, docId: correction.documentID, at: correction.at, source: correction.source.rawValue,
                                     fromFolderId: correction.fromFolderID, toFolderId: correction.toFolderID,
                                     fromFilename: correction.fromFilename, toFilename: correction.toFilename,
                                     proposedJson: correction.proposed.map { JSON.string($0) },
                                     editedFieldsJson: JSON.string(correction.editedFields), traceId: correction.traceID)
            try r.insert(db)
            return r.id ?? 0
        }
    }

    public func linkCorrespondent(documentID: Int64, correspondentID: Int64, name: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET correspondent_id = ?, correspondent = ?, updated_at = ? WHERE id = ?",
                           arguments: [correspondentID, name, Date().timeIntervalSince1970, documentID])
        }
    }

    public func stableKeyOwners(minWeight: Double) async throws -> [String: Set<Int64>] {
        try await database.reader.read { db in
            var owners: [String: Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT correspondent_id, stable_keys_json FROM memories
                WHERE correspondent_id IS NOT NULL AND weight >= ? AND orphaned = 0
                """, arguments: [minWeight]) {
                let id: Int64 = row["correspondent_id"]
                for key in JSON.decode([String].self, from: row["stable_keys_json"]) ?? [] { owners[key, default: []].insert(id) }
            }
            return owners
        }
    }

    public func deleteCorrespondent(id: Int64) async throws {
        try await database.writer.write { db in _ = try CorrespondentRecord.deleteOne(db, key: id) }
    }

    public func known(_ facts: [LearnedFact]) async throws -> Set<LearnedFact> {
        try await database.reader.read { db in
            let rules = Set(try Int64.fetchAll(db, sql: "SELECT id FROM rules WHERE forgotten = 0"))
            let correspondents = try CorrespondentRecord.fetchAll(db).compactMap { r in r.id.map { ($0, r.correspondent) } }
            let byID = Dictionary(uniqueKeysWithValues: correspondents)
            let examples = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT doc_id FROM memories"))
            return Set(facts.filter { fact in
                switch fact {
                case let .example(documentID): examples.contains(documentID)
                case let .rule(id): rules.contains(id)
                case let .alias(correspondentID, alias): byID[correspondentID]?.aliases.contains(alias) ?? false
                case let .sender(correspondentID): byID[correspondentID] != nil
                }
            })
        }
    }

    public func documentCount(folderID: Int64, correspondentID: Int64?, documentType: DocumentType?) async throws -> Int {
        try await database.reader.read { db in
            var request = DocumentRecord.filter(Column("folder_id") == folderID && Column("status") == DocumentStatus.filed.rawValue)
            if let correspondentID { request = request.filter(Column("correspondent_id") == correspondentID) }
            if let documentType { request = request.filter(Column("doc_type") == documentType.rawValue) }
            return try request.fetchCount(db)
        }
    }

    public func folderProfile(folderID: Int64, examples: Int, correspondents: Int) async throws -> LearnedBlock {
        try await database.reader.read { db in
            let names = try String.fetchAll(db, sql: """
                SELECT path FROM documents WHERE folder_id = ? AND status = 'filed' ORDER BY filed_at DESC LIMIT ?
                """, arguments: [folderID, examples]).map { ($0 as NSString).lastPathComponent }
            let senders = try String.fetchAll(db, sql: """
                SELECT correspondent FROM documents WHERE folder_id = ? AND status = 'filed' AND correspondent IS NOT NULL
                GROUP BY correspondent ORDER BY COUNT(*) DESC, MAX(filed_at) DESC LIMIT ?
                """, arguments: [folderID, correspondents])
            return LearnedBlock(examples: names, correspondents: senders, updated: Date().formatted(.iso8601.year().month().day()))
        }
    }

    public func excerpts(documentIDs: [Int64], maxChars: Int) async throws -> [Int64: String] {
        guard !documentIDs.isEmpty else { return [:] }
        return try await database.reader.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                SELECT doc_id, substr(body, 1, ?) AS b FROM document_text
                WHERE doc_id IN (\(documentIDs.map { _ in "?" }.joined(separator: ",")))
                """, arguments: [maxChars] + StatementArguments(documentIDs)).map { ($0["doc_id"] as Int64, $0["b"] as String? ?? "") })
        }
    }

    public func meta(_ key: String) async throws -> String? { try await database.meta(key) }
    public func setMeta(_ key: String, _ value: String) async throws { try await database.setMeta(key, value) }

    // MARK: Folder embeddings

    public func folderEmbedding(folderID: Int64, model: String, descriptionHash: String) async throws -> [Float]? {
        try await database.reader.read { db in
            try FolderEmbeddingRecord.filter(Column("folder_id") == folderID).filter(Column("model") == model)
                .filter(Column("description_hash") == descriptionHash).fetchOne(db).map { VectorCodec.decode($0.vector) }
        }
    }

    public func saveFolderEmbedding(folderID: Int64, model: String, descriptionHash: String, vector: [Float]) async throws {
        try await database.writer.write { db in
            try FolderEmbeddingRecord(folderId: folderID, model: model, descriptionHash: descriptionHash,
                                      vector: VectorCodec.encode(vector), createdAt: Date()).upsert(db)
        }
    }

    // MARK: Proposals

    @discardableResult
    public func createProposal(kind: ProposalKind, title: String, folderID: Int64?, payload: String) async throws -> Int64 {
        try await database.writer.write { db in
            var r = ProposalRecord(id: nil, kind: kind.rawValue, status: ProposalStatus.pending.rawValue, title: title,
                                   folderId: folderID, payloadJson: payload, createdAt: Date(), resolvedAt: nil)
            try r.insert(db)
            try HistoryStore.insert(db, .proposalCreated, summary: title, payload: ["kind": kind.rawValue, "id": String(r.id ?? 0)])
            return r.id ?? 0
        }
    }

    public func hasPendingProposal(kind: ProposalKind, folderID: Int64?, title: String) async throws -> Bool {
        try await database.reader.read { db in
            var r = ProposalRecord.filter(Column("kind") == kind.rawValue).filter(Column("status") == ProposalStatus.pending.rawValue)
                .filter(Column("title") == title)
            if let folderID { r = r.filter(Column("folder_id") == folderID) }
            return try r.fetchCount(db) > 0
        }
    }

    public func proposals(status: ProposalStatus?) async throws -> [ProposalRecord] {
        try await database.reader.read { db in
            var r = ProposalRecord.order(Column("created_at").desc)
            if let status { r = r.filter(Column("status") == status.rawValue) }
            return try r.fetchAll(db)
        }
    }

    public func resolveProposal(id: Int64, status: ProposalStatus) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE proposals SET status = ?, resolved_at = ? WHERE id = ?",
                           arguments: [status.rawValue, Date().timeIntervalSince1970, id])
            try HistoryStore.insert(db, .proposalResolved, actor: .user, summary: "Proposal \(id) \(status.rawValue)")
        }
    }

    public func corrections(limit: Int) async throws -> [CorrectionRecord] {
        try await database.reader.read { db in
            try CorrectionRecord.order(Column("at").desc).limit(limit).fetchAll(db)
        }
    }
}
