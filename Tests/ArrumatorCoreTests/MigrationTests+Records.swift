import Foundation
import GRDB
import Testing
@testable import ArrumatorCore
import ArrumatorTesting

/// Migrations that record when they ran, and the index of the labels documents have.
extension MigrationTests {
    @Test func logicSetAsideWhenAnArchiveCameToHaveOneIsKeptInTheHistoryAtTheTimeOfTheIndexsClock() throws {
        let queue = try Self.installed(upTo: "v6_archiveRecords")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO logic (builtin_key, name, body, active, position, edited, created_at, updated_at) VALUES
                  (NULL, 'Mine', 'File bills/by sender', 0, 1, 0, 0, 0),
                  ('default', 'Default', '  By year\n', 1, 0, 0, 0, 0);
                """)
        }
        let migratedAt = TestTime.start.addingTimeInterval(-86_400)
        try AppDatabase.migrator(time: TestTime(.advances, at: migratedAt)).migrate(queue, upTo: "v7_oneLogicPerArchive")
        try queue.read { db in
            let event = try #require(try Row.fetchOne(db, sql: "SELECT at, kind, actor, summary, payload_json FROM events"))
            #expect(event["at"] as Double == migratedAt.timeIntervalSince1970,
                    "the event is dated by the clock the index is opened with, which a test or a replay sets")
            #expect(event["kind"] as String == "logicChanged" && event["actor"] as String == "system",
                    "and is of the kind and by the actor the release that ran it wrote")
            #expect(event["payload_json"] as String == #"{"body":"File bills/by sender","name":"Mine"}"#,
                    "its text is kept, written as that release wrote it, whatever today's encoder writes")
            let logic = try #require(try Row.fetchOne(db, sql: "SELECT body, builtin_hash FROM logic"))
            #expect(logic["body"] as String == "By year"
                        && logic["builtin_hash"] as String == "sha256:090dc468e82e6caa05a5ab8e058644b9f784abfaa0514039c98d57f3577e4b5a",
                    "the active logic stays, and built-in logic nobody changed is known by the checksum of its text")
        }
    }

    @Test func theLabelsDocumentsHaveAreIndexedWhenTheIndexIsMigratedAndKeptInStepAfter() throws {
        let queue = try Self.installed(upTo: "v23_endedJobsKeepNoText")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO documents (id, uid, path, original_filename, sha256, size, uttype, status, labels_json, added_at, created_at, updated_at)
                VALUES (1, 'u1', '/archive/bill.pdf', 'bill.pdf', 'h1', 1, 'com.adobe.pdf', 'filed',
                        '[{"kind":"sender","value":"EDP"},{"kind":"type","value":"invoice"},{"kind":"sender","value":"EDP"}]', 0, 0, 0),
                       (2, 'u2', '/archive/scan.pdf', 'scan.pdf', 'h2', 1, 'com.adobe.pdf', 'needsReview', NULL, 0, 0, 0),
                       (3, 'u3', '/archive/note.pdf', 'note.pdf', 'h3', 1, 'com.adobe.pdf', 'filed', '[{"kind":"type"},"invoice"]', 0, 0, 0),
                       (4, 'u4', '/archive/odd.pdf', 'odd.pdf', 'h4', 1, 'com.adobe.pdf', 'filed', 'not JSON', 0, 0, 0);
                DELETE FROM record_dirty;
                """)
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)
        func indexed(_ db: Database) throws -> [String] {
            try String.fetchAll(db, sql: "SELECT doc_id || ' ' || kind || ' ' || value FROM document_labels ORDER BY doc_id, kind, value")
        }
        try queue.write { db in
            #expect(try indexed(db) == ["1 sender EDP", "1 type invoice"],
                    "each label a document has is indexed once; no labels, entries that are no label and labels that are not JSON index none")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty") == 0, "and no record file needs writing again")
            try db.execute(sql: #"UPDATE documents SET labels_json = '[{"kind":"sender","value":"MEO"}]' WHERE id = 1"#)
            try db.execute(sql: #"UPDATE documents SET labels_json = '[{"kind":"tag","value":"Taxes"}]' WHERE id = 2"#)
            try db.execute(sql: "INSERT INTO documents (id, uid, path, original_filename, sha256, size, uttype, status, labels_json, added_at, created_at, updated_at) "
                               + #"VALUES (5, 'u5', '/archive/new.pdf', 'new.pdf', 'h5', 1, 'com.adobe.pdf', 'filed', '[{"kind":"type","value":"receipt"}]', 0, 0, 0)"#)
            try db.execute(sql: "UPDATE documents SET status = 'missing' WHERE id = 5")
            #expect(try indexed(db) == ["1 sender MEO", "2 tag Taxes", "5 type receipt"],
                    "a document's labels changed, given or added are indexed as they are now, and another change leaves them be")
            try db.execute(sql: "DELETE FROM documents WHERE id = 1")
            #expect(try indexed(db) == ["2 tag Taxes", "5 type receipt"], "and a document gone takes its labels with it")
        }
    }
}
