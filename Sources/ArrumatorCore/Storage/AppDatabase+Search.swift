import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of the search, in the order they shipped, after `v29_labelsByHand`.
    static func registerSearchMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v30_foldedSearch", migrate: foldedSearchMigration)
    }

    /// `v30_foldedSearch`. The full-text index is made again with a tokenizer that folds each word to one spelling in
    /// every script (`FoldingTokenizer`), and fills itself from `document_text`, which it is synchronised with and whose
    /// text is not changed: the same sixteen columns, the same prefixes, nothing learned is touched.
    static func foldedSearchMigration(_ db: Database) throws {
        try register(db)
        try db.dropFTS5SynchronizationTriggers(forTable: "document_fts")
        try db.drop(table: "document_fts")
        try db.create(virtualTable: "document_fts", using: FTS5()) { t in
            t.synchronize(withTable: "document_text")
            t.tokenizer = FoldingTokenizer.descriptor
            t.prefixes = [2, 3]
            for column in ["filename", "body", "sender", "party", "type", "topic", "object", "reference", "date", "period", "deadline",
                           "amount", "jurisdiction", "language", "tag", "interpretation"] {
                t.column(column)
            }
        }
    }
}
