import Foundation
import GRDB
import Testing
@testable import ArrumatorCore

/// Installed databases record which migrations they have applied by identifier, and every one of them must still
/// reach today's schema with its documents intact.
@Suite struct MigrationTests {
    /// Every identifier that has ever shipped, in order. Append new migrations; never rename or remove one.
    static let shipped = ["v1_initial", "v2_datesAsUnixSeconds", "v3_brainsAndRethink", "v4_renameBrainsToLogic",
                          "v5_logicEvents", "v6_archiveRecords", "v7_oneLogicPerArchive",
                          "v8_undoForgets", "v9_foldersOfAnyDepth", "v10_folderKinds", "v11_labelsNotFolders",
                          "v12_labelRules"]

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
        #expect(columns[SearchService.bodyColumn] == "body", "snippets are cut from the text")
    }

    @Test func aDatabaseFromTheBrainsReleaseReachesTodaysSchema() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3_brainsAndRethink")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO brains (builtin_key, name, body, active, position, edited, created_at, updated_at)
                VALUES (NULL, 'Mine', 'File tax papers by year.', 1, 0, 1, 0, 0);
                INSERT INTO events (at, kind, actor, summary, payload_json) VALUES (0, 'arrived', 'system', 'bill.pdf', '{}');
                """)
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.read { db in
            let gone = try !db.tableExists("logic") && !(try db.tableExists("brains"))
            #expect(gone, "an archive has no logic any more")
            let kinds = try EventRecord.fetchAll(db).map(\.kind)
            #expect(kinds == [.arrived], "events of kinds that still exist still read")
        }
    }

    /// A database as the release that filed into folders left it: a folder, a document filed there with its decision,
    /// what was learned about it, events and a job half way through.
    @Test func aDatabaseThatFiledIntoFoldersKeepsItsDocumentsWithTheirDetailsAsLabels() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v10_folderKinds")
        let decision = #"""
        {"folderCode":"F12","alternatives":[],"correspondent":"EDP Comercial","correspondentID":1,"documentType":"invoice",
         "documentDate":"2026-07-05","dateSource":"label","title":"Fatura eletricidade","fileName":"2026-07-05 EDP - Fatura",
         "tags":["energy"],"language":"pt","confidence":{"modifiers":{},"final":0.4,"band":"review","thresholds":{"auto":0.85,"review":0.5}},
         "decidedBy":"llm","rationale":"EDP","modelInfo":"ministral-3:14b","reviewReasons":["low confidence"]}
        """#
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO correspondents (id, canonical_name, default_folder_code, origin, created_at, updated_at)
                VALUES (1, 'EDP Comercial', 'F12', 'learned', 0, 0);
                INSERT INTO folders (id, uid, code, name, rel_path, created_at, updated_at) VALUES (12, 'f', 'F12', 'Utilities', 'Home/Utilities', 0, 0);
                INSERT INTO documents (id, uid, path, original_filename, sha256, size, uttype, folder_id, correspondent_id, correspondent,
                                       doc_type, doc_date, title, language, status, band, confidence, decided_by, rationale, decision_json,
                                       tags_json, added_at, created_at, updated_at)
                VALUES (1, 'u1', '/archive/Home/Utilities/bill.pdf', 'bill.pdf', 'h', 1, 'com.adobe.pdf', 12, 1, 'EDP Comercial', 'invoice',
                        '2026-07-05', 'Fatura eletricidade', 'pt', 'needsReview', 'review', 0.4, 'llm', 'EDP', ?, '["energy"]', 0, 0, 0);
                INSERT INTO document_text (doc_id, title, correspondent, filename, body) VALUES (1, 'Fatura', 'EDP', 'bill.pdf', 'eletricidade julho');
                INSERT INTO rules (name, predicates_json, action_json, origin, created_at, updated_at) VALUES ('EDP', '[]', '{}', 'induced', 0, 0);
                INSERT INTO events (at, kind, actor, summary, payload_json) VALUES (0, 'filed', 'system', 'bill.pdf', '{}'),
                    (0, 'ruleInduced', 'system', 'EDP', '{}'), (0, 'classified', 'system', 'Home', '{}'),
                    (0, 'learned', 'system', 'Remembered EDP', '{}');
                INSERT INTO jobs (kind, source_path, state, created_at, updated_at) VALUES ('reclassify', '/incoming/a.pdf', 'classifying', 0, 0);
                INSERT INTO traces (id, doc_id, attempt, source, started_at, app_version, prompt_version, taxonomy_version, settings_json,
                                    logic_version) VALUES (1, 1, 0, 'ingest', 0, 'old', 2, 3, '{}', 'mine-1');
                INSERT INTO trace_steps (trace_id, seq, stage, status, started_at, duration_ms, output_json)
                VALUES (1, 1, 'llm', 'ok', 0, 1, '[{"user":"text"}]');
                DELETE FROM record_dirty;
                """, arguments: [decision])
        }

        // What the app does at launch.
        try AppDatabase.migrator.migrate(queue)

        try queue.write { db in
            let doc = try #require(try DocumentRecord.fetchOne(db, key: 1))
            #expect(doc.path == "/archive/Home/Utilities/bill.pdf" && doc.status == .needsReview, "a document stays where it is")
            #expect(doc.labels == [DocumentLabel(kind: .sender, value: "EDP Comercial"), DocumentLabel(kind: .type, value: "invoice"),
                                   DocumentLabel(kind: .topic, value: "energy"), DocumentLabel(kind: .date, value: "2026-07-05"),
                                   DocumentLabel(kind: .language, value: "pt")],
                    "what its decision said of it becomes its labels")
            #expect(doc.analysis == DocumentAnalysis(fileName: "2026-07-05 EDP - Fatura", model: "ministral-3:14b", problems: ["low confidence"]),
                    "and the rest how it was read: its name, the model, what it waits for the user about")
            for table in ["folders", "rules", "memories", "corrections", "proposals", "logic", "rethink_runs", "folder_embeddings",
                          "correspondents"] {
                #expect(try !db.tableExists(table), "\(table) is gone")
            }
            #expect(try !db.columns(in: "traces").contains { $0.name == "logic_version" })
            #expect(try String.fetchAll(db, sql: "SELECT stage FROM trace_steps") == [TraceStage.analyse.rawValue],
                    "an old model exchange is kept out of diagnostics like a new one")
            #expect(try EventRecord.order(Column("id")).fetchAll(db).map(\.kind) == [.filed], "events of kinds that are gone are dropped")
            let job = try #require(try JobRecord.fetchOne(db))
            #expect(job.state == .analysing && job.kind == .reanalyse, "a job half way through is read again")
            #expect(try String.fetchAll(db, sql: "SELECT key FROM record_dirty WHERE key LIKE 'documents:%'") == ["documents:/archive/Home/Utilities/"],
                    "every record file is written again in today's shape")
            let match = "SELECT rowid FROM document_fts WHERE document_fts MATCH ?"
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["eletricidade"]) == [1], "what was indexed before is still found")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["sender : edp"]) == [1], "and its labels are, kind by kind")
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: "UPDATE documents SET labels_json = '[]' WHERE id = 1")
            #expect(try String.fetchAll(db, sql: "SELECT key FROM record_dirty") == ["documents:/archive/Home/Utilities/"],
                    "a change to the labels rewrites the document's record file")
            try db.execute(sql: "UPDATE document_text SET jurisdiction = 'Portugal' WHERE doc_id = 1")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["jurisdiction : portugal"]) == [1], "labels are indexed by kind")
            #expect(throws: DatabaseError.self, "a file has one active job, while it is read too") {
                try db.execute(sql: "INSERT INTO jobs (kind, source_path, state, created_at, updated_at) VALUES ('ingest', '/incoming/a.pdf', 'pending', 0, 0)")
            }
        }
    }
}
