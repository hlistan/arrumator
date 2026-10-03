import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of the index of the labels documents have, in the order they shipped, after
    /// `v23_endedJobsKeepNoText`.
    static func registerLabelIndexMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v24_documentLabels", migrate: documentLabelsMigration)
    }

    /// `v24_documentLabels`. Each label a document has is a row of `document_labels`, by its kind and value, kept in step
    /// with `documents.labels_json` by triggers in the transaction that changes it, so no write path can miss one: which
    /// labels are in use and how often (`LabelStore.usage`), and which documents have a label (`DocumentFilter.labels`),
    /// are answered by its primary key instead of reading every document's labels as JSON. An entry that is not a label of
    /// a kind and a value, or labels that are not JSON, index nothing, as they count for nothing. It is the index's own:
    /// no record file holds it, and a rebuild fills it as it fills `documents`. What the index already holds is indexed.
    /// The triggers are on `documents`: a later migration that makes that table again (a new table copied in and renamed,
    /// as `v11_labelsNotFolders` did) drops them with it, and must create them again and fill `document_labels` anew.
    static func documentLabelsMigration(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE document_labels (
          kind TEXT NOT NULL,
          value TEXT NOT NULL,
          doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          PRIMARY KEY (kind, value, doc_id)) WITHOUT ROWID;
        CREATE INDEX document_labels_doc ON document_labels(doc_id);
        CREATE TRIGGER documents_labels_insert AFTER INSERT ON documents BEGIN
          INSERT OR IGNORE INTO document_labels (kind, value, doc_id)
            SELECT json_extract(NEW.labels_json, l.fullkey || '.kind'), json_extract(NEW.labels_json, l.fullkey || '.value'), NEW.id
            FROM json_each(CASE WHEN json_valid(NEW.labels_json) THEN NEW.labels_json END) l
            WHERE json_type(NEW.labels_json, l.fullkey || '.kind') = 'text' AND json_type(NEW.labels_json, l.fullkey || '.value') = 'text';
        END;
        CREATE TRIGGER documents_labels_update AFTER UPDATE OF id, labels_json ON documents
        WHEN OLD.id IS NOT NEW.id OR OLD.labels_json IS NOT NEW.labels_json BEGIN
          DELETE FROM document_labels WHERE doc_id = OLD.id;
          INSERT OR IGNORE INTO document_labels (kind, value, doc_id)
            SELECT json_extract(NEW.labels_json, l.fullkey || '.kind'), json_extract(NEW.labels_json, l.fullkey || '.value'), NEW.id
            FROM json_each(CASE WHEN json_valid(NEW.labels_json) THEN NEW.labels_json END) l
            WHERE json_type(NEW.labels_json, l.fullkey || '.kind') = 'text' AND json_type(NEW.labels_json, l.fullkey || '.value') = 'text';
        END;
        INSERT OR IGNORE INTO document_labels (kind, value, doc_id)
          SELECT json_extract(d.labels_json, l.fullkey || '.kind'), json_extract(d.labels_json, l.fullkey || '.value'), d.id
          FROM documents d, json_each(CASE WHEN json_valid(d.labels_json) THEN d.labels_json END) l
          WHERE json_type(d.labels_json, l.fullkey || '.kind') = 'text' AND json_type(d.labels_json, l.fullkey || '.value') = 'text';
        """)
    }
}
