// swiftlint:disable line_length - migration SQL is kept as written when it shipped
import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of what is kept of a document beside it, in the order they shipped, after
    /// `v27_readingAgain`.
    static func registerSidecarMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v28_sidecars", migrate: sidecarsMigration)
    }

    /// `v28_sidecars`. A document's reading tells what it is in the model's words (`DocumentAnalysis.interpretation`),
    /// which is a field of the search: `document_text.interpretation`, kept equal to what `documents.analysis_json`
    /// holds by a trigger in the transaction that changes it, as `document_labels` follows `labels_json`, and filled
    /// where the text's row is written (`IndexStore.writeText`); the full-text index is made again with a column for it,
    /// its last, and fills itself from `document_text`, whose rows are given what their documents hold (none of them
    /// yet, as no reading gave one before). Beside each document of the archive whose text was read is its sidecar
    /// (`ArchiveRecords.renderSidecar`): what the model read it as and its text as it was recognised, written from the
    /// index as a record file is, marked by triggers in the transaction of every change to what it holds or where it
    /// goes. `sidecar_files` keeps, by document, the path and checksum of the sidecar the index last wrote, one path to one
    /// document, so a sidecar that went is cleaned up where it was and one changed by hand is never written over or
    /// removed unread. It is the index's own: no record file holds it. Every document whose text was read is marked, so
    /// the archive's documents are given their sidecars once the index is opened.
    static func sidecarsMigration(_ db: Database) throws {
        try db.dropFTS5SynchronizationTriggers(forTable: "document_fts")
        try db.drop(table: "document_fts")
        try db.execute(sql: """
        ALTER TABLE document_text ADD COLUMN interpretation TEXT NOT NULL DEFAULT '';
        UPDATE document_text SET interpretation = COALESCE((SELECT CASE WHEN json_valid(d.analysis_json) THEN json_extract(d.analysis_json, '$.interpretation') END FROM documents d WHERE d.id = document_text.doc_id), '');
        CREATE TRIGGER documents_interpretation AFTER UPDATE OF analysis_json ON documents
        WHEN OLD.analysis_json IS NOT NEW.analysis_json BEGIN
          UPDATE document_text SET interpretation = COALESCE(CASE WHEN json_valid(NEW.analysis_json) THEN json_extract(NEW.analysis_json, '$.interpretation') END, '')
          WHERE doc_id = NEW.id;
        END;
        CREATE TABLE sidecar_files (doc_id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, hash TEXT NOT NULL);
        CREATE TRIGGER documents_sidecar_insert AFTER INSERT ON documents BEGIN
          INSERT INTO record_dirty(key, version) VALUES ('sidecar:' || NEW.id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1;
        END;
        CREATE TRIGGER documents_sidecar_update AFTER UPDATE OF id, path, status, analysis_json, extracted_at ON documents
        WHEN OLD.id IS NOT NEW.id OR OLD.path IS NOT NEW.path OR OLD.status IS NOT NEW.status OR OLD.analysis_json IS NOT NEW.analysis_json OR OLD.extracted_at IS NOT NEW.extracted_at BEGIN
          INSERT INTO record_dirty(key, version) VALUES ('sidecar:' || OLD.id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1;
          INSERT INTO record_dirty(key, version) VALUES ('sidecar:' || NEW.id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1;
        END;
        CREATE TRIGGER documents_sidecar_delete AFTER DELETE ON documents BEGIN
          INSERT INTO record_dirty(key, version) VALUES ('sidecar:' || OLD.id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1;
        END;
        CREATE TRIGGER document_text_sidecar_insert AFTER INSERT ON document_text BEGIN
          INSERT INTO record_dirty(key, version) VALUES ('sidecar:' || NEW.doc_id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1;
        END;
        CREATE TRIGGER document_text_sidecar_update AFTER UPDATE OF body ON document_text WHEN OLD.body IS NOT NEW.body BEGIN
          INSERT INTO record_dirty(key, version) VALUES ('sidecar:' || NEW.doc_id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1;
        END;
        CREATE TRIGGER document_text_sidecar_delete AFTER DELETE ON document_text BEGIN
          INSERT INTO record_dirty(key, version) VALUES ('sidecar:' || OLD.doc_id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1;
        END;
        INSERT INTO record_dirty(key, version) SELECT 'sidecar:' || id, 1 FROM documents WHERE extracted_at IS NOT NULL
          ON CONFLICT(key) DO UPDATE SET version = version + 1;
        """)
        try db.create(virtualTable: "document_fts", using: FTS5()) { t in
            t.synchronize(withTable: "document_text")
            t.tokenizer = .unicode61(diacritics: .remove)
            t.prefixes = [2, 3]
            for column in ["filename", "body", "sender", "party", "type", "topic", "object", "reference", "date", "period", "deadline",
                           "amount", "jurisdiction", "language", "tag", "interpretation"] {
                t.column(column)
            }
        }
    }
}
// swiftlint:enable line_length
