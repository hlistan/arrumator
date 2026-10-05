import Foundation
import GRDB
import Testing
@testable import ArrumatorCore
import ArrumatorTesting

/// Labels kept in a form an older version wrote, which the index and the record files hold in today's.
extension MigrationTests {
    /// A label an older reading joined with another ("banking; account statement", QA 2026-10-04, READ-3) is the labels
    /// it holds, each once, in its place, and a name without a letter is none; a tag, the user's own, stays as written; the
    /// label index follows, and the record
    /// file of a document changed is written again, and only that one.
    @Test func aLabelAnOlderReadingJoinedIsTheLabelsItHolds() throws {
        let queue = try Self.installed(upTo: "v25_documentsInTwoPlaces")
        let joined = #"[{"kind":"topic","value":"banking; account statement"},{"kind":"topic","value":"banking"},"#
            + #"{"kind":"party","value":"999999990"},{"kind":"tag","value":"Taxes; 2024"}]"#
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO documents (id, uid, path, original_filename, sha256, size, uttype, status, labels_json, content_json,
                                       added_at, created_at, updated_at)
                VALUES (1, 'u1', '/archive/Bank/statement.pdf', 'statement.pdf', 'h1', 1, 'com.adobe.pdf', 'filed', ?, '{}', 0, 0, 0),
                       (2, 'u2', '/archive/bill.pdf', 'bill.pdf', 'h2', 1, 'com.adobe.pdf', 'filed', '[{"kind":"sender","value":"EDP"}]', '{}', 0, 0, 0);
                DELETE FROM record_dirty;
                """, arguments: [joined])
        }

        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue)

        try queue.read { db in
            let documents = try DocumentRecord.order(Column("id")).fetchAll(db)
            #expect(documents.first?.labels == [DocumentLabel(kind: .topic, value: "banking"), DocumentLabel(kind: .topic, value: "account statement"),
                                                DocumentLabel(kind: .tag, value: "Taxes; 2024")],
                    "the joined topic is two, the repeat is kept once, a party without a letter is none, and the tag stays as written")
            #expect(try String.fetchAll(db, sql: "SELECT value FROM document_labels WHERE doc_id = 1 AND kind = 'topic' ORDER BY value")
                        == ["account statement", "banking"], "the label index holds them split")
            #expect(documents.last?.labels == [DocumentLabel(kind: .sender, value: "EDP")], "a document without one is as it was")
            #expect(try String.fetchAll(db, sql: "SELECT key FROM record_dirty") == ["documents:/archive/Bank/"],
                    "the changed document's record file is written again, and no other")
        }
    }

    /// A record file an older version wrote may hold a joined label, or a name without a letter: the index rebuilt from it
    /// holds them as the migration leaves them (`DocumentLabel.split`).
    @Test func aRecordFileEntryWithAJoinedLabelIsReadAsTheLabelsItHolds() throws {
        let at = TestTime.start
        var entry = try #require(DocumentEntry(DocumentRecord(
            id: 1, uid: "u1", path: "/archive/Bank/statement.pdf", originalFilename: "statement.pdf", sha256: "h", size: 1,
            uttype: "com.adobe.pdf", inode: nil, pageCount: nil, status: .filed, analysisJson: nil, contentJson: nil, labelsJson: nil,
            tagsOnly: false, duplicateOf: nil, lastTraceId: nil, addedAt: at, filedAt: at, extractedAt: nil, embeddedAt: nil, fileMtime: nil,
            createdAt: at, updatedAt: at)))
        entry.labels = [DocumentLabel(kind: .topic, value: "banking; account statement"), DocumentLabel(kind: .party, value: "999999990"),
                        DocumentLabel(kind: .tag, value: "Taxes; 2024")]
        let record = try entry.record(directory: URL(fileURLWithPath: "/archive/Bank"), now: at)
        #expect(record.labels == [DocumentLabel(kind: .topic, value: "banking"), DocumentLabel(kind: .topic, value: "account statement"),
                                  DocumentLabel(kind: .tag, value: "Taxes; 2024")])
    }
}
