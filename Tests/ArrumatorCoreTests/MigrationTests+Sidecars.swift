import Foundation
import GRDB
import Testing
@testable import ArrumatorCore
import ArrumatorTesting

/// Migrations of what is kept of a document beside it: what the model read it as, searched by its words, and its
/// sidecar.
extension MigrationTests {
    @Test func whatTheModelReadADocumentAsIsAFieldOfTheSearchKeptWithItsAnalysisAndEveryReadDocumentGetsASidecar() throws {
        let queue = try Self.installed(upTo: "v27_readingAgain")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO documents (id, uid, path, original_filename, sha256, size, uttype, status, analysis_json, content_json,
                                       extracted_at, added_at, created_at, updated_at)
                VALUES (1, 'u1', '/archive/bill.pdf', 'bill.pdf', 'h1', 1, 'com.adobe.pdf', 'filed',
                        '{"interpretation":"Fatura de eletricidade","problems":[]}', '{}', 5, 0, 0, 0),
                       (2, 'u2', '/archive/scan.pdf', 'scan.pdf', 'h2', 1, 'com.adobe.pdf', 'filed', '{"problems":[]}', '{}', 5, 0, 0, 0),
                       (3, 'u3', '/archive/new.pdf', 'new.pdf', 'h3', 1, 'com.adobe.pdf', 'filed', 'not json', NULL, NULL, 0, 0, 0);
                INSERT INTO document_text (doc_id, filename, body) VALUES (1, 'bill.pdf', 'EDP julho'), (2, 'scan.pdf', 'recibo'),
                    (3, 'new.pdf', '');
                DELETE FROM record_dirty;
                """)
        }

        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: "v28_sidecars")

        try queue.write { db in
            #expect(try db.columns(in: "document_fts").map(\.name) == SearchService.columns && SearchService.columns.last == "interpretation",
                    "what the model read a document as is a field of the search, the full-text index's last column")
            #expect(try String.fetchAll(db, sql: "SELECT interpretation FROM document_text ORDER BY doc_id") == ["Fatura de eletricidade", "", ""],
                    "taken from each document's analysis, none where it has none or the analysis is no JSON")
            let match = "SELECT rowid FROM document_fts WHERE document_fts MATCH ? ORDER BY rowid"
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["interpretation : eletricidade"]) == [1], "and found by its words")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["julho OR recibo"]) == [1, 2], "every document is still found by its text")
            #expect(try String.fetchAll(db, sql: "SELECT key FROM record_dirty ORDER BY key") == ["sidecar:1", "sidecar:2"],
                    "every document whose text was read is given its sidecar once the index is opened, and none whose text was not")

            try db.execute(sql: "DELETE FROM record_dirty")
            try db.execute(sql: #"UPDATE documents SET analysis_json = '{"interpretation":"Recibo da farmácia","problems":[]}' WHERE id = 2"#)
            #expect(try String.fetchOne(db, sql: "SELECT interpretation FROM document_text WHERE doc_id = 2") == "Recibo da farmácia",
                    "a new reading is searched by what it says, in the transaction that saves it")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["interpretation : farmacia"]) == [2], "its words found, accents aside")
            try db.execute(sql: "UPDATE documents SET status = 'filed', analysis_json = analysis_json WHERE id = 1")
            try db.execute(sql: "UPDATE document_text SET body = body, sender = 'EDP' WHERE doc_id = 1")
            let sidecars = "SELECT key FROM record_dirty WHERE key LIKE 'sidecar:%' ORDER BY key"
            #expect(try String.fetchAll(db, sql: sidecars) == ["sidecar:2"],
                    "a sidecar is marked by what changes what it holds or where it goes, never by a write that changes none of it")
            // Each change on its own marks the sidecar of the document it is a change of, and only that one.
            let changes: [(sql: String, marks: String, what: String)] = [
                ("UPDATE documents SET path = '/archive/Bills/bill.pdf' WHERE id = 1", "sidecar:1", "a document moved"),
                ("UPDATE documents SET status = 'missing' WHERE id = 1", "sidecar:1", "a document set aside as missing"),
                ("UPDATE documents SET extracted_at = NULL WHERE id = 1", "sidecar:1", "a reading taken back"),
                (#"UPDATE documents SET analysis_json = '{"problems":[]}' WHERE id = 1"#, "sidecar:1", "a reading saved"),
                ("UPDATE document_text SET body = 'EDP agosto' WHERE doc_id = 3", "sidecar:3", "a text read again"),
                ("DELETE FROM document_text WHERE doc_id = 3", "sidecar:3", "a text taken back"),
                ("INSERT INTO document_text (doc_id, filename, body) VALUES (3, 'new.pdf', 'lido')", "sidecar:3", "a text read"),
                ("""
                 INSERT INTO documents (id, uid, path, original_filename, sha256, size, uttype, status, added_at, created_at, updated_at)
                 VALUES (4, 'u4', '/archive/more.pdf', 'more.pdf', 'h4', 1, 'com.adobe.pdf', 'filed', 0, 0, 0)
                 """, "sidecar:4", "a document taken in"),
                ("DELETE FROM documents WHERE id = 2", "sidecar:2", "a document gone"),
            ]
            for change in changes {
                try db.execute(sql: "DELETE FROM record_dirty")
                try db.execute(sql: change.sql)
                #expect(try String.fetchAll(db, sql: sidecars) == [change.marks], "\(change.what) marks its sidecar, alone")
            }
        }
    }
}
