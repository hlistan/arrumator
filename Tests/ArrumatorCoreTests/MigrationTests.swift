import Foundation
import GRDB
import Testing
@testable import ArrumatorCore

/// Installed databases record which migrations they have applied by identifier. These tests stop a shipped
/// identifier from being renamed, which made every installed app fail to start.
@Suite struct MigrationTests {
    /// Every identifier that has ever shipped, in order. Append new migrations; never rename or remove one.
    static let shipped = ["v1_initial", "v2_datesAsUnixSeconds", "v3_brainsAndRethink", "v4_renameBrainsToLogic",
                          "v5_logicEvents", "v6_archiveRecords", "v7_oneLogicPerArchive",
                          "v8_undoForgets", "v9_foldersOfAnyDepth", "v10_folderKinds", "v11_documentLabels"]

    @Test func shippedIdentifiersNeverChange() {
        let registered = AppDatabase.migrator.migrations
        #expect(Array(registered.prefix(Self.shipped.count)) == Self.shipped,
                "a shipped migration was renamed, removed or reordered; installed databases would re-run it and fail")
    }

    @Test func theFullTextIndexHasTheColumnsSearchNames() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        let columns = try queue.read { db in try db.columns(in: "document_fts").map(\.name) }
        #expect(columns == SearchService.columns, "`column:term` and the BM25 weights address columns by these names, in this order")
    }

    @Test func aDatabaseFromBeforeLabelsKeepsWhatItIndexedAndTakesLabels() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v10_folderKinds")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO documents (id, uid, path, original_filename, sha256, size, uttype, status, added_at, created_at, updated_at)
                VALUES (1, 'u1', '/archive/Home/bill.pdf', 'bill.pdf', 'h', 1, 'com.adobe.pdf', 'filed', 0, 0, 0);
                INSERT INTO document_text (doc_id, title, correspondent, filename, body)
                VALUES (1, 'Fatura', 'EDP', 'bill.pdf', 'eletricidade julho');
                INSERT INTO jobs (kind, source_path, state, created_at, updated_at) VALUES ('ingest', '/incoming/a.pdf', 'pending', 0, 0);
                DELETE FROM record_dirty;
                """)
        }

        // What the app does at launch.
        try AppDatabase.migrator.migrate(queue)

        try queue.write { db in
            let match = "SELECT rowid FROM document_fts WHERE document_fts MATCH ?"
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["eletricidade"]) == [1], "what was indexed before is still found")
            #expect(try DocumentRecord.fetchOne(db, key: 1)?.labels == nil,
                    "a document filed before labels is unlabelled, not labelled with nothing")
            try db.execute(sql: "UPDATE documents SET labels_json = '[]' WHERE id = 1")
            #expect(try String.fetchAll(db, sql: "SELECT key FROM record_dirty") == ["documents:/archive/Home/"],
                    "a change to the labels rewrites the document's record file")
            try db.execute(sql: "UPDATE document_text SET jurisdiction = 'Portugal' WHERE doc_id = 1")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["jurisdiction : portugal"]) == [1], "labels are indexed by kind")
            try db.execute(sql: "UPDATE jobs SET state = 'labeling'")
            #expect(throws: DatabaseError.self, "a file has one active job, while it is labelled too") {
                try db.execute(sql: "INSERT INTO jobs (kind, source_path, state, created_at, updated_at) VALUES ('ingest', '/incoming/a.pdf', 'pending', 0, 0)")
            }
        }
    }

    @Test func aDatabaseFromTheBrainsReleaseOpensWithItsDataIntact() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3_brainsAndRethink")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO brains (builtin_key, name, body, active, position, edited, created_at, updated_at)
                VALUES (NULL, 'Mine', 'File tax papers by year.', 1, 0, 1, 0, 0),
                       ('organizing-principles', 'Organizing principles', 'Built in.', 0, 1, 0, 0, 0),
                       (NULL, 'Draft', 'Cars under Vehicles.', 0, 2, 0, 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO traces (doc_id, job_id, attempt, source, started_at, app_version, prompt_version,
                                    taxonomy_version, settings_json, brains_version)
                VALUES (NULL, NULL, 0, 'ingest', 0, 'test', 1, 1, '{}', 'mine-1')
                """)
            try db.execute(sql: "INSERT INTO events (at, kind, actor, summary, payload_json) VALUES (0, 'brainChanged', 'user', 'Switched', '{}')")
        }

        // What the app does at launch.
        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let logic = try LogicRecord.fetchAll(db)
            #expect(logic.map(\.body) == ["File tax papers by year."], "the logic that was active is the archive's one logic")
            #expect(logic.first?.followsBuiltin == false, "logic the user wrote never follows the built-in text")
            #expect(try String.fetchOne(db, sql: "SELECT logic_version FROM traces") == "mine-1")
            #expect(try db.columns(in: "rules").contains { $0.name == "forgotten" })
            #expect(try !db.tableExists("brains"))
            let events = try EventRecord.order(Column("id")).fetchAll(db)
            #expect(events.map(\.kind) == [.logicChanged, .logicChanged], "events from then still read")
            #expect(events.last?.summary.contains("“Draft”") == true && events.last?.payloadJson.contains("Cars under Vehicles.") == true,
                    "logic the user wrote but never activated is kept in the history, not lost")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty WHERE key = 'logic'") == 1,
                    "the logic is written into the archive at the next start")
        }
    }
}
