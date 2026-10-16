import Foundation
import GRDB
import Testing
@testable import ArrumatorCore
import ArrumatorTesting

/// Migrations of the search.
extension MigrationTests {
    @Test func theFullTextIndexIsMadeAgainWithAFoldingTokenizerAndNothingLearnedOrStoredIsChanged() throws {
        let queue = try Self.installed(upTo: "v29_labelsByHand")
        let decomposed = "faturac\u{327}a\u{303}o de eletricidade"
        let greek = "λογαριασμός ρεύματος"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO documents (id, uid, path, original_filename, sha256, size, uttype, status, added_at, created_at, updated_at)
                VALUES (1, 'u1', '/archive/bill.pdf', 'bill.pdf', 'h1', 1, 'com.adobe.pdf', 'filed', 0, 0, 0),
                       (2, 'u2', '/archive/dei.pdf', 'dei.pdf', 'h2', 1, 'com.adobe.pdf', 'filed', 0, 0, 0),
                       (3, 'u3', '/archive/scan.pdf', 'scan.pdf', 'h3', 1, 'com.adobe.pdf', 'filed', 0, 0, 0);
                INSERT INTO document_text (doc_id, filename, body, sender) VALUES (1, 'bill.pdf', ?, 'EDP'), (2, 'dei.pdf', ?, 'ΔΕΗ'),
                    (3, 'scan.pdf', 'счёт за свет', 'Sber');
                INSERT INTO label_rules (kind, value, action, target, created_at) VALUES ('sender', 'EDP Comercial', 'merge', 'EDP', 0);
                """, arguments: [decomposed, greek])
        }
        try queue.read { db in
            let before = try Int64.fetchAll(db, sql: "SELECT rowid FROM document_fts WHERE document_fts MATCH ?", arguments: ["λογαριασμος"])
            #expect(before.isEmpty, "the index of v29 does not find a Greek word without its tonos: the defect this migration mends")
        }

        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: "v30_foldedSearch")

        try queue.read { db in
            let match = "SELECT rowid FROM document_fts WHERE document_fts MATCH ? ORDER BY rowid"
            #expect(try db.columns(in: "document_fts").map(\.name) == SearchService.columns, "the index has the columns search names")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["faturacao"]) == [1], "a decomposed text is found by its plain spelling")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["λογαριασμος"]) == [2], "a Greek word is found without its tonos")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["счет"]) == [3], "е finds ё")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["sender : edp"]) == [1], "a field is searched as before")
            #expect(try Int64.fetchAll(db, sql: match, arguments: ["\"elet\" *"]) == [1], "and a prefix")
            let bodies = try Row.fetchAll(db, sql: "SELECT body FROM document_text ORDER BY doc_id").map { Array(($0["body"] as String).utf8) }
            #expect(bodies == [Array(decomposed.utf8), Array(greek.utf8), Array("счёт за свет".utf8)], "the text kept is not changed, byte for byte")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM label_rules") == 1, "the user's decisions about labels are untouched")
        }
    }
}
