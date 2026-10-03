import Foundation
import GRDB
import Testing
@testable import ArrumatorCore
import ArrumatorTesting

/// Installed databases record which migrations they have applied by identifier, and every one of them must still
/// reach today's schema with its documents intact.
@Suite struct MigrationTests {
    /// Every identifier that has ever shipped, in order. Append new migrations; never rename or remove one.
    static let shipped = ["v1_initial", "v2_datesAsUnixSeconds", "v3_brainsAndRethink", "v4_renameBrainsToLogic",
                          "v5_logicEvents", "v6_archiveRecords", "v7_oneLogicPerArchive",
                          "v8_undoForgets", "v9_foldersOfAnyDepth", "v10_folderKinds", "v11_labelsNotFolders",
                          "v12_labelRules", "v13_traceExchanges", "v14_searchTasks", "v15_taskEffort",
                          "v16_taskProfile", "v17_tags", "v18_taskConversations", "v19_unreadIndexRefusesRecords",
                          "v20_queueWorkers", "v21_jobClaims", "v22_jobsWaitForTheirModel", "v23_endedJobsKeepNoText",
                          "v24_documentLabels", "v25_documentsInTwoPlaces"]

    /// An index as a release before this one made it, migrated up to `identifier`: its first migration ran before that
    /// one marked a new index as still to be rebuilt from its archive, so it is not.
    static func installed(upTo identifier: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: try #require(shipped.first))
        try queue.write { db in try AppDatabase.setPendingRebuild(db, nil) }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: identifier)
        return queue
    }

    @Test func shippedIdentifiersNeverChange() {
        let registered = AppDatabase.migrator(time: TestTime(.advances)).migrations
        #expect(Array(registered.prefix(Self.shipped.count)) == Self.shipped,
                "a shipped migration was renamed, removed or reordered; installed databases would re-run it and fail")
    }

    @Test func anIndexIsNewFromTheTransactionThatMakesItWhereverAStopCameWhileItWasMade() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = try PipelineConfig.bundledDefaults()
        func open(_ url: URL) throws -> (AppDatabase, AppDatabase.Opening) {
            try AppDatabase.open(at: url, config: config.database, setAsideSuffix: config.records.setAsideSuffix, time: TestTime(.advances)) { true }
        }
        // A stop came while the index was being made: after its file, and after its first migrations, each committed on
        // its own.
        let empty = dir.appendingPathComponent("empty.sqlite")
        #expect(FileManager.default.createFile(atPath: empty.path, contents: Data()))
        var stopped = [empty]
        for count in [1, 2] {
            let url = dir.appendingPathComponent("after-\(count).sqlite")
            let queue = try DatabaseQueue(path: url.path)
            try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: Self.shipped[count - 1])
            try queue.close()
            stopped.append(url)
        }
        for url in stopped {
            let (database, opening) = try open(url)
            let pending = try await database.pendingRebuild()
            #expect(opening == .existing && pending == .unread,
                    "\(url.lastPathComponent): its file was there, but it holds nothing of its archive yet, so it is still to be rebuilt")
        }
        let first = try #require(stopped.last)
        let (database, _) = try open(first)
        try await database.writer.write { db in try AppDatabase.setPendingRebuild(db, nil) }
        #expect(try await open(first).0.pendingRebuild() == nil, "an index that was rebuilt is not new again")
    }

    @Test func anIndexThatHasReadNothingOfItsArchiveRefusesEveryChangeToWhatTheRecordFilesHold() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)
        let changes = ["INSERT INTO events (at, kind, actor, summary, payload_json) VALUES (0, 'paused', 'user', 'Paused', '{}')",
                       "INSERT INTO label_rules (kind, value, action, created_at) VALUES ('topic', 'electricity', 'ignore', 0)",
                       "INSERT INTO search_tasks (prompt, state, effort, created_at, updated_at) VALUES ('bills', 'queued', 'medium', 0, 0)",
                       "INSERT INTO documents (uid, path, original_filename, sha256, size, uttype, status, added_at, created_at, updated_at) "
                           + "VALUES ('u', '/archive/a.pdf', 'a.pdf', 'h', 1, 'pdf', 'filed', 0, 0, 0)"]
        for sql in changes {
            #expect("a new index takes nothing a record file holds, from any writer: \(sql)") {
                try queue.write { db in try db.execute(sql: sql) }
            } throws: { error in
                (error as? DatabaseError)?.message == AppDatabase.notRebuiltMessage
            }
        }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO jobs (kind, source_path, state, created_at, updated_at) VALUES ('ingest', '/incoming/a.pdf', 'pending', 0, 0)")
            try AppDatabase.setPendingRebuild(db, .unfinished)
            for sql in changes { try db.execute(sql: sql) }
            try AppDatabase.setPendingRebuild(db, .unread)
        }
        #expect("nor are its rows changed or removed while it is unread") {
            try queue.write { db in try db.execute(sql: "DELETE FROM events") }
        } throws: { error in
            (error as? DatabaseError)?.message == AppDatabase.notRebuiltMessage
        }
        #expect(try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") } == 1,
                "what the rebuild wrote once the index was unfinished is kept, and its queue was never refused")
    }

    @Test func tracesOfEarlierReadingsKeepTheirExchangeWhereRetentionFindsIt() throws {
        let queue = try Self.installed(upTo: "v12_labelRules")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO traces (id, attempt, source, started_at, app_version, prompt_version, settings_json)
                  VALUES (1, 0, 'ingest', 0, 'old', 5, '{}');
                INSERT INTO trace_steps (trace_id, seq, stage, status, started_at, duration_ms, output_json) VALUES
                  (1, 1, 'analyse', 'ok', 0, 1, '{"answer":{"fileName":"EDP"},"calls":[{"user":"the text"}]}'),
                  (1, 2, 'vlm', 'ok', 0, 1, '{"raw":"a receipt","visual":{"imageKind":"receipt"}}'),
                  (1, 3, 'place', 'ok', 0, 1, '{"calls":"not a model exchange"}');
                """)
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)
        try queue.read { db in
            let outputs = try String.fetchAll(db, sql: "SELECT output_json FROM trace_steps ORDER BY seq")
            #expect(outputs[0] == #"{"answer":{"fileName":"EDP"},"exchange":[{"user":"the text"}]}"#,
                    "a reading's prompts and answers are under the key retention clears, its answer where it was")
            #expect(outputs[1] == #"{"visual":{"imageKind":"receipt"},"exchange":"a receipt"}"#, "and so is an image description's")
            #expect(outputs[2] == #"{"calls":"not a model exchange"}"#, "a step that talked to no model is left as it was")
        }
    }

    @Test func searchTasksAskedBeforeEffortsAreReadAsMediumReadsThemWithTheProfilesModel() throws {
        let queue = try Self.installed(upTo: "v14_searchTasks")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO search_tasks (id, prompt, state, created_at, updated_at) VALUES (1, 'water bills', 'ready', 0, 0);
                DELETE FROM record_dirty;
                """)
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: "v15_taskEffort")
        try queue.write { db in
            let task = try #require(try Row.fetchOne(db, sql: "SELECT effort, assigned_model FROM search_tasks WHERE id = 1"))
            #expect(task["effort"] as String? == "medium" && task["assigned_model"] as String? == nil,
                    "what reproduced how the task was read before, when efforts came")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty WHERE key = 'tasks'") == 1,
                    "System/_tasks.md is written again, with the effort, at the next flush")
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: "UPDATE search_tasks SET effort = 'high' WHERE id = 1")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty WHERE key = 'tasks'") == 1,
                    "and a change of effort reaches it as any other change does")
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: "UPDATE search_tasks SET assigned_model = 'qwen3.5:9b' WHERE id = 1")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty WHERE key = 'tasks'") == 1, "so does a change of model")
        }
        let empty = try DatabaseQueue()
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(empty, upTo: "v15_taskEffort")
        #expect(try empty.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty") } == 0,
                "an index without tasks has no record of them to write")
    }

    @Test func tasksGivenAModelFollowSettingsProfileOnceTheColumnIsGone() throws {
        let queue = try Self.installed(upTo: "v15_taskEffort")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO search_tasks (id, prompt, state, effort, assigned_model, created_at, updated_at)
                  VALUES (1, 'water bills', 'ready', 'high', 'qwen3.5:9b', 0, 0);
                INSERT INTO search_tasks (id, prompt, state, effort, created_at, updated_at) VALUES (2, 'phone bills', 'queued', 'low', 0, 0);
                DELETE FROM record_dirty;
                """)
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)
        let marks = "SELECT version FROM record_dirty WHERE key = 'tasks'"
        try queue.write { db in
            #expect(try !db.columns(in: "search_tasks").contains { $0.name == "assigned_model" },
                    "a model given to a task is no column any more, so nothing can read it as something else")
            let tasks = try Row.fetchAll(db, sql: "SELECT effort, profile FROM search_tasks ORDER BY id")
            #expect(tasks.map { $0["profile"] as String? } == [nil, nil],
                    "a task given a model, and one without, both follow the profile Settings uses: a model is not a profile")
            #expect(tasks.map { $0["effort"] as String? } == ["high", "low"], "and each keeps the effort it was asked with")
            #expect(try Int.fetchOne(db, sql: marks) == 1, "System/_tasks.md is marked once, to be written again without the model")
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: "UPDATE search_tasks SET profile = 'smart' WHERE id = 1")
            #expect(try Int.fetchOne(db, sql: marks) == 1, "a change of profile reaches it, as the trigger now follows the profile")
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: "UPDATE search_tasks SET effort = 'medium' WHERE id = 2")
            #expect(try Int.fetchOne(db, sql: marks) == 1, "and a change of effort still does")
        }
        let empty = try DatabaseQueue()
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(empty)
        #expect(try empty.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty") } == 0,
                "an index without tasks has no record of them to write")
    }

    @Test func tagsComeAsAFieldOfTheFullTextIndexAndEveryDocumentKeepsWhatItHad() throws {
        let queue = try Self.installed(upTo: "v16_taskProfile")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO documents (id, uid, path, original_filename, sha256, size, uttype, status, labels_json, content_json,
                                       added_at, created_at, updated_at)
                VALUES (1, 'u1', '/archive/bill.pdf', 'bill.pdf', 'h1', 1, 'com.adobe.pdf', 'filed', '[{"kind":"sender","value":"EDP"}]', '{}', 0, 0, 0),
                       (2, 'u2', '/archive/scan.pdf', 'scan.pdf', 'h2', 1, 'com.adobe.pdf', 'needsReview', NULL, '{}', 0, 0, 0),
                       (3, 'u3', '/archive/note.pdf', 'note.pdf', 'h3', 1, 'com.adobe.pdf', 'filed', '[]', '{}', 0, 0, 0);
                INSERT INTO document_text (doc_id, filename, body, sender) VALUES (1, 'bill.pdf', 'eletricidade julho', 'EDP'),
                    (2, 'scan.pdf', 'recibo', ''), (3, 'note.pdf', 'lembrete', '');
                DELETE FROM record_dirty;
                """)
        }

        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)

        try queue.write { db in
            #expect(try db.columns(in: "document_fts").map(\.name) == SearchService.columns && SearchService.columns.last == "tag",
                    "a tag is a field of the search, the full-text index's last column, where search.bm25Weights gives it its weight")
            let match = "SELECT rowid FROM document_fts WHERE document_fts MATCH ? ORDER BY rowid"
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["eletricidade OR recibo OR lembrete"]) == [1, 2, 3],
                    "every document indexed before is still found by its words")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["sender : edp"]) == [1], "and by its labels, kind by kind")
            let documents = try DocumentRecord.order(Column("id")).fetchAll(db)
            #expect(documents.map(\.tagsOnly) == [false, false, false] && documents.map(\.isLabelled) == [true, false, true],
                    "each keeps what it was: labelled, or not yet, or labelled with nothing")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty") == 0, "and no record file needs writing again")
            try db.execute(sql: "UPDATE document_text SET tag = 'Taxes 2024' WHERE doc_id = 2")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["tag : taxes"]) == [2], "a tag is found under its kind")
            try db.execute(sql: #"UPDATE documents SET labels_json = '[{"kind":"tag","value":"Taxes 2024"}]' WHERE id = 2"#)
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: "UPDATE documents SET tags_only = 1 WHERE id = 2")
            #expect(try String.fetchAll(db, sql: "SELECT key FROM record_dirty") == ["documents:/archive/"],
                    "whether a document's labels are only its tags reaches its record file, as its labels do")
        }
    }

    @Test func aTasksConversationMarksItsOwnFileAndGoesWithItsTask() throws {
        let queue = try Self.installed(upTo: "v17_tags")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO search_tasks (id, prompt, state, effort, created_at, updated_at) VALUES (4, 'water bills', 'ready', 'medium', 0, 0),
                    (5, 'phone bills', 'ready', 'medium', 0, 0);
                DELETE FROM record_dirty;
                """)
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)
        let marks = "SELECT key FROM record_dirty ORDER BY key"
        try queue.write { db in
            #expect(try String.fetchAll(db, sql: marks).isEmpty, "no task had a conversation before, so no file needs writing")
            try db.execute(sql: "UPDATE search_tasks SET title = 'Water' WHERE id = 4")
            #expect(try String.fetchAll(db, sql: marks) == ["tasks"], "renaming a task without a conversation marks only System/_tasks.md")
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: "INSERT INTO search_task_turns (id, task_id, question, state, asked_at) VALUES (1, 4, 'How much?', 'queued', 0)")
            #expect(try String.fetchAll(db, sql: marks) == ["conversation:4"], "a question marks its task's conversation, and only that")
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: "UPDATE search_task_turns SET state = 'answered', answer = 'Little' WHERE id = 1")
            #expect(try String.fetchAll(db, sql: marks) == ["conversation:4"], "and so does its answer")
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: "UPDATE search_task_turns SET last_trace_id = 9, next_run_at = 1 WHERE id = 1")
            #expect(try String.fetchAll(db, sql: marks).isEmpty, "what the index keeps of its own marks nothing")
            try db.execute(sql: "UPDATE search_tasks SET title = 'Water bills' WHERE id = 4")
            #expect(try String.fetchAll(db, sql: marks) == ["conversation:4", "tasks"],
                    "renaming a task with a conversation marks its file too, which is headed with the task's name")
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: "DELETE FROM search_tasks WHERE id = 4")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_task_turns") == 0, "a task's questions go with it")
            #expect(try String.fetchAll(db, sql: marks) == ["conversation:4", "tasks"], "and its conversation's file is marked, to be removed")
        }
    }

    @Test func aJobHeldForAMissingModelWaitsForItAtTheStageItReachedOneJobAPath() throws {
        let queue = try Self.installed(upTo: "v21_jobClaims")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (id, kind, source_path, state, payload_json, created_at, updated_at) VALUES
                  (1, 'ingest', '/Incoming/read.pdf', 'held', '{"sha256":"a","content":{}}', 0, 7),
                  (2, 'ingest', '/Incoming/twice.pdf', 'held', '{}', 0, 7),
                  (3, 'ingest', '/Incoming/twice.pdf', 'held', '{"sha256":"b"}', 0, 8),
                  (4, 'ingest', '/Incoming/again.pdf', 'held', '{}', 0, 7),
                  (5, 'ingest', '/Incoming/again.pdf', 'pending', '{}', 0, 9),
                  (6, 'reindex', '/Archive/filed.pdf', 'held', '{"content":{}}', 0, 7);
                """)
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: "v22_jobsWaitForTheirModel")
        let jobs = try queue.read { db in try Row.fetchAll(db, sql: "SELECT id, state, next_run_at FROM jobs ORDER BY id") }
        #expect(jobs.map { $0["state"] as String } == ["analysing", "cancelled", "pending", "cancelled", "pending", "pending"],
                "each waits again at the stage after the last it finished, and a path keeps one active job: \(jobs)")
        #expect(jobs.first?["next_run_at"] as Double? == 7, "due at once, as it was when it was held")
    }

    @Test func aJobHeldForAMissingModelWhoseFileALaterJobFiledStaysEnded() throws {
        let queue = try Self.installed(upTo: "v21_jobClaims")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (id, kind, source_path, state, payload_json, created_at, updated_at) VALUES
                  (1, 'ingest', '/Incoming/bill.pdf', 'held', '{"sha256":"a","content":{}}', 0, 7),
                  (2, 'ingest', '/Incoming/bill.pdf', 'done', '{"sha256":"a","targetPath":"/Archive/bill.pdf"}', 0, 9);
                """)
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: "v22_jobsWaitForTheirModel")
        let states = try queue.read { db in try String.fetchAll(db, sql: "SELECT state FROM jobs ORDER BY id") }
        #expect(states == ["cancelled", "done"], "a held job whose file a later job filed is not taken up again: \(states)")
    }

    @Test func jobsThatEndedBeforeKeepNoTextOrEmbeddingAndWaitingOnesKeepTheirs() throws {
        let queue = try Self.installed(upTo: "v22_jobsWaitForTheirModel")
        let read = #"{"sha256":"a","content":{"text":"EDP"},"outcome":{"embedding":[1,0],"embeddingModel":"m"},"targetPath":"/A/b.pdf"}"#
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (id, kind, source_path, state, payload_json, created_at, updated_at) VALUES
                  (1, 'ingest', '/Incoming/done.pdf', 'done', ?, 0, 0), (2, 'ingest', '/Incoming/waits.pdf', 'filing', ?, 0, 0),
                  (3, 'ingest', '/Incoming/broken.pdf', 'failed', 'not json', 0, 0);
                """, arguments: [read, read])
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: "v23_endedJobsKeepNoText")
        let payloads = try queue.read { db in try String.fetchAll(db, sql: "SELECT payload_json FROM jobs ORDER BY id") }
        #expect(payloads == [#"{"sha256":"a","outcome":{"embeddingModel":"m"},"targetPath":"/A/b.pdf"}"#, read, "not json"],
                "an ended job keeps what it did but no text or embedding; a waiting one keeps all; one no JSON is kept as it is")
    }

    @Test func anItemInHandWhenTheQueuesLearntTheirWorkersHasNoneAndGoesBackIntoTheQueue() throws {
        let queue = try Self.installed(upTo: "v19_unreadIndexRefusesRecords")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO search_tasks (id, prompt, state, effort, created_at, updated_at) VALUES (1, 'water bills', 'interpreting', 'medium', 0, 0);
                INSERT INTO search_task_turns (id, task_id, question, state, asked_at) VALUES (1, 1, 'How much?', 'answering', 0);
                DELETE FROM record_dirty;
                """)
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)
        try queue.write { db in
            #expect(try String.fetchAll(db, sql: "SELECT worker FROM search_tasks WHERE worker IS NOT NULL").isEmpty
                        && (try String.fetchAll(db, sql: "SELECT worker FROM search_task_turns WHERE worker IS NOT NULL")).isEmpty,
                    "what an earlier release had in hand names no process, so no process still works on it (ProcessWatching.hasLeft)")
            try db.execute(sql: "UPDATE search_tasks SET worker = '1:2'; UPDATE search_task_turns SET worker = '1:2'")
            #expect(try String.fetchAll(db, sql: "SELECT key FROM record_dirty").isEmpty, "the worker is the index's own, and marks no record file")
        }
        #expect(TestProcesses().hasLeft(nil), "an item in hand without a worker goes back into the queue")
    }

    @Test func theFullTextIndexHasTheColumnsSearchNames() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)
        let columns = try queue.read { db in try db.columns(in: "document_fts").map(\.name) }
        #expect(columns == SearchService.columns, "`column:term` and the BM25 weights address columns by these names, in this order")
        #expect(columns[SearchService.bodyColumn] == "body", "snippets are cut from the text")
    }

    @Test func aDatabaseFromTheBrainsReleaseReachesTodaysSchema() throws {
        let queue = try Self.installed(upTo: "v3_brainsAndRethink")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO brains (builtin_key, name, body, active, position, edited, created_at, updated_at)
                VALUES (NULL, 'Mine', 'File tax papers by year.', 1, 0, 1, 0, 0);
                INSERT INTO events (at, kind, actor, summary, payload_json) VALUES (0, 'arrived', 'system', 'bill.pdf', '{}');
                """)
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)
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
        let queue = try Self.installed(upTo: "v10_folderKinds")
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
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)

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
            #expect(try !db.columns(in: "traces").contains { $0.name == "logic_version" }, "traces no longer name a logic that is gone")
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
