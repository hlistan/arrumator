import Foundation
import GRDB
import Testing
@testable import ArrumatorCore
import ArrumatorTesting

/// Migrations of the labels the user gives by hand.
extension MigrationTests {
    @Test func theLabelsHistorySaysTheUserAddedAreGivenByHandAndOnlyTheirRecordFilesAreWrittenAgain() throws {
        let queue = try Self.installed(upTo: "v28_sidecars")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO documents (id, uid, path, original_filename, sha256, size, uttype, status, labels_json, added_at, created_at,
                                       updated_at)
                VALUES (1, 'u1', '/archive/Bills/bill.pdf', 'bill.pdf', 'h1', 1, 'com.adobe.pdf', 'filed', ?, 0, 0, 0),
                       (2, 'u2', '/archive/Bank/statement.pdf', 'statement.pdf', 'h2', 1, 'com.adobe.pdf', 'filed',
                        '[{"kind":"sender","value":"Banco"}]', 0, 0, 0),
                       (3, 'u3', '/archive/Other/note.pdf', 'note.pdf', 'h3', 1, 'com.adobe.pdf', 'filed',
                        '[{"kind":"sender","value":"EDP"}]', 0, 0, 0);
                INSERT INTO events (at, doc_id, kind, actor, summary) VALUES
                  (1, 1, 'corrected', 'user', 'added sender “EDP”, topic “car”, tag “Mine”, object “car AA-12-BB”'),
                  (2, 1, 'corrected', 'user', 'Renamed to “bill.pdf”; added topic “household”, date “2026-07-01”; removed date “2026-07-05”'),
                  (3, 1, 'corrected', 'user', 'removed topic “car”'),
                  (4, 1, 'analysed', 'system', 'added sender “EDP Comercial”'),
                  (5, 2, 'corrected', 'user', 'Corrected labels'),
                  (6, NULL, 'corrected', 'user', 'added sender “EDP”');
                DELETE FROM record_dirty;
                """, arguments: [#"[{"kind":"sender","value":"EDP Comercial"},{"kind":"sender","value":"EDP"},"#
                    + #"{"kind":"topic","value":"household"},{"kind":"topic","value":"car"},"#
                    + #"{"kind":"date","value":"2026-07-01"},{"kind":"tag","value":"Mine"}]"#])
        }

        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: "v29_labelsByHand")

        try queue.write { db in
            let marked = try Row.fetchAll(db, sql: "SELECT id, by_hand_json FROM documents ORDER BY id")
                .map { (row: Row) -> [DocumentLabel]? in JSON.decode([DocumentLabel].self, from: row["by_hand_json"] as String?) }
            #expect(marked[0] == [DocumentLabel(kind: .sender, value: "EDP"), DocumentLabel(kind: .topic, value: "household"),
                                  DocumentLabel(kind: .date, value: "2026-07-01")],
                    "what corrections say they added and it still has is given by hand; not one taken off since, one it lost, nor a tag")
            #expect(marked[1] == nil && marked[2] == nil,
                    "a correction that says nothing of its labels, as earlier versions wrote, marks none, and nor does a document never corrected")
            #expect(try String.fetchAll(db, sql: "SELECT key FROM record_dirty") == ["documents:/archive/Bills/"],
                    "the record file of the document marked is written again with its labels given by hand, and no other")
            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: #"UPDATE documents SET by_hand_json = '[{"kind":"sender","value":"EDP"}]' WHERE id = 3"#)
            #expect(try String.fetchAll(db, sql: "SELECT key FROM record_dirty") == ["documents:/archive/Other/"],
                    "a label given by hand marks the record file of the document's folder, which holds it")
        }
    }
}
