// swiftlint:disable line_length - migration SQL is kept as written when it shipped
import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of the user's own labels, tags, in the order they shipped, after `v16_taskProfile`.
    static func registerTagMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17_tags", migrate: tagsMigration)
    }

    /// `v17_tags`. A kind of label of the user's own, `tag` (docs/how-it-works.md#folders-in-incoming). It is a field of
    /// the search, so the full-text index is made again with a column for it, its last, and fills itself from
    /// `document_text` with what every document already had indexed; no document has a tag before this, so the column
    /// starts empty. `tags_only` says a document's labels are only its tags because the model has not labelled it yet;
    /// every document already there has labels of the model's or none, so it starts false and each keeps what it was,
    /// labelled or not. The trigger that marks a document's record file follows the new column, and no record file
    /// needs writing again.
    static func tagsMigration(_ db: Database) throws {
        try db.dropFTS5SynchronizationTriggers(forTable: "document_fts")
        try db.drop(table: "document_fts")
        try db.execute(sql: """
        ALTER TABLE document_text ADD COLUMN tag TEXT NOT NULL DEFAULT '';
        ALTER TABLE documents ADD COLUMN tags_only INTEGER NOT NULL DEFAULT 0;
        DROP TRIGGER documents_record_update;
        CREATE TRIGGER documents_record_update AFTER UPDATE OF path, original_filename, sha256, size, uttype, status, page_count, analysis_json, labels_json, tags_only, duplicate_of, added_at, filed_at, uid ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(OLD.path, replace(OLD.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(NEW.path, replace(NEW.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        """)
        try db.create(virtualTable: "document_fts", using: FTS5()) { t in
            t.synchronize(withTable: "document_text")
            t.tokenizer = .unicode61(diacritics: .remove)
            t.prefixes = [2, 3]
            for column in ["filename", "body", "sender", "party", "type", "topic", "object", "reference", "date", "period", "deadline",
                           "amount", "jurisdiction", "language", "tag"] {
                t.column(column)
            }
        }
    }
}
// swiftlint:enable line_length
