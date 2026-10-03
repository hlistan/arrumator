// swiftlint:disable line_length - migration SQL is kept as written when it shipped
import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of the release that described documents by labels, `v11_labelsNotFolders` to
    /// `v13_traceExchanges`, in the order they shipped, after `v10_folderKinds`.
    static func registerLabelMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v11_labelsNotFolders", migrate: labelsNotFoldersMigration)
        migrator.registerMigration("v12_labelRules", migrate: labelRulesMigration)
        migrator.registerMigration("v13_traceExchanges", migrate: traceExchangesMigration)
    }

    /// Documents are described by labels alone (docs/how-it-works.md). The local model reads each one for its labels
    /// and its name and files it at the top of the archive; the folder tree, the logic, rules, filing memories,
    /// corrections, proposals, rethink runs and senders are gone, with what they learned. A document keeps its place:
    /// what its filing decision said of it (its sender, type, date, period, topics and language) becomes its labels,
    /// and the rest of the decision, its name and the model that read it, its analysis. Each kind of label is a
    /// column of the full-text index, which is made again with them. Events of kinds that no longer exist are dropped,
    /// and every record file is written again.
    static func labelsNotFoldersMigration(_ db: Database) throws {
        try db.dropFTS5SynchronizationTriggers(forTable: "document_fts")
        try db.drop(table: "document_fts")
        try db.execute(sql: labelsNotFoldersSchema)
        // The full-text index is made again with a column for each kind of label, and fills itself from document_text.
        try db.create(virtualTable: "document_fts", using: FTS5()) { t in
            t.synchronize(withTable: "document_text")
            t.tokenizer = .unicode61(diacritics: .remove)
            t.prefixes = [2, 3]
            for column in ["filename", "body", "sender", "party", "type", "topic", "object", "reference", "date", "period", "deadline",
                           "amount", "jurisdiction", "language"] {
                t.column(column)
            }
        }
    }

    /// What `v11_labelsNotFolders` drops, makes and carries over, as it shipped.
    static let labelsNotFoldersSchema = """
        DROP TABLE memories;
        DROP TABLE rules;
        DROP TABLE corrections;
        DROP TABLE proposals;
        DROP TABLE rethink_items;
        DROP TABLE rethink_runs;
        DROP TABLE logic;
        DROP TABLE folder_embeddings;

        CREATE TABLE documents_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          uid TEXT NOT NULL UNIQUE,
          path TEXT NOT NULL,
          original_filename TEXT NOT NULL,
          sha256 TEXT NOT NULL,
          size INTEGER NOT NULL,
          uttype TEXT NOT NULL,
          inode INTEGER,
          page_count INTEGER,
          status TEXT NOT NULL,
          analysis_json TEXT,
          content_json TEXT,
          labels_json TEXT,
          duplicate_of INTEGER REFERENCES documents(id) ON DELETE SET NULL,
          last_trace_id INTEGER,
          added_at REAL NOT NULL,
          filed_at REAL,
          extracted_at REAL,
          embedded_at REAL,
          file_mtime REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL);
        INSERT INTO documents_new
          SELECT id, uid, path, original_filename, sha256, size, uttype, inode, page_count, status,
                 CASE WHEN decision_json IS NULL THEN NULL ELSE json_object(
                   'fileName', json_extract(decision_json, '$.fileName'),
                   'model', json_extract(decision_json, '$.modelInfo'),
                   'problems', CASE WHEN status IN ('needsReview', 'failed')
                     THEN json(COALESCE(json_extract(decision_json, '$.reviewReasons'), '[]')) ELSE json('[]') END) END,
                 content_json,
                 CASE WHEN decision_json IS NULL THEN NULL ELSE (
                   SELECT json_group_array(json_object('kind', kind, 'value', value)) FROM (
                     SELECT 'sender' AS kind, correspondent AS value WHERE COALESCE(correspondent, '') != ''
                     UNION ALL SELECT 'type', doc_type WHERE doc_type IS NOT NULL AND doc_type != 'other'
                     UNION ALL SELECT 'topic', t.value FROM json_each(COALESCE(tags_json, '[]')) t
                     UNION ALL SELECT 'date', doc_date WHERE doc_date IS NOT NULL
                     UNION ALL SELECT 'period', CAST(period_year AS TEXT) WHERE period_year IS NOT NULL
                     UNION ALL SELECT 'language', language WHERE length(language) = 2)) END,
                 duplicate_of, last_trace_id, added_at, filed_at, extracted_at, embedded_at, file_mtime, created_at, updated_at
          FROM documents;
        DROP TABLE documents;
        ALTER TABLE documents_new RENAME TO documents;
        CREATE INDEX documents_sha ON documents(sha256);
        CREATE INDEX documents_status ON documents(status);
        CREATE INDEX documents_added ON documents(added_at DESC);
        CREATE INDEX documents_path ON documents(path);
        CREATE INDEX documents_inode ON documents(inode);
        CREATE TRIGGER documents_record_insert AFTER INSERT ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(NEW.path, replace(NEW.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER documents_record_update AFTER UPDATE OF path, original_filename, sha256, size, uttype, status, page_count, analysis_json, labels_json, duplicate_of, added_at, filed_at, uid ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(OLD.path, replace(OLD.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(NEW.path, replace(NEW.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER documents_record_delete AFTER DELETE ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(OLD.path, replace(OLD.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        DROP TABLE folders;
        DROP TABLE correspondents;

        ALTER TABLE traces DROP COLUMN logic_version;
        ALTER TABLE traces DROP COLUMN taxonomy_version;
        UPDATE trace_steps SET stage = 'analyse' WHERE stage IN ('llm', 'label');

        UPDATE jobs SET state = 'analysing' WHERE state IN ('labeling', 'classifying', 'filing');
        UPDATE jobs SET kind = 'reanalyse' WHERE kind = 'reclassify';
        DROP INDEX jobs_active_path;
        CREATE UNIQUE INDEX jobs_active_path ON jobs(source_path)
          WHERE state IN ('pending','hashing','extracting','analysing','filing');

        DELETE FROM events WHERE kind IN ('classified', 'refiled', 'folderCreated', 'folderRenamed', 'folderRemoved',
          'descriptionChanged', 'ruleInduced', 'ruleDisabled', 'ruleChanged', 'proposalCreated', 'proposalResolved',
          'logicChanged', 'rethink', 'rethought', 'learned', 'forgot');

        ALTER TABLE document_text DROP COLUMN title;
        ALTER TABLE document_text DROP COLUMN correspondent;
        ALTER TABLE document_text ADD COLUMN sender TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN party TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN type TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN topic TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN object TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN reference TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN date TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN period TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN deadline TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN amount TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN jurisdiction TEXT NOT NULL DEFAULT '';
        ALTER TABLE document_text ADD COLUMN language TEXT NOT NULL DEFAULT '';
        UPDATE document_text SET
          sender = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'sender'), ''),
          party = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'party'), ''),
          type = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'type'), ''),
          topic = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'topic'), ''),
          object = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'object'), ''),
          reference = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'reference'), ''),
          date = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'date'), ''),
          period = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'period'), ''),
          deadline = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'deadline'), ''),
          amount = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'amount'), ''),
          jurisdiction = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'jurisdiction'), ''),
          language = COALESCE((SELECT group_concat(json_extract(l.value, '$.value'), char(10)) FROM documents d, json_each(d.labels_json) l
            WHERE d.id = document_text.doc_id AND json_extract(l.value, '$.kind') = 'language'), '');

        DELETE FROM record_dirty;
        INSERT INTO record_dirty(key, version) SELECT DISTINCT 'documents:' || rtrim(path, replace(path, '/', '')), 1 FROM documents;
        INSERT OR IGNORE INTO record_dirty(key, version)
          SELECT DISTINCT 'history:' || strftime('%Y-%m', at, 'unixepoch'), 1 FROM events;
        """

    /// The user's decisions about labels (docs/how-it-works.md#keeping-labels-one-vocabulary): a label merged into
    /// another, one not wanted, two kept apart. They are the user's, so a change marks the archive's
    /// `System/_labels.md`, which a rebuild reads back.
    static func labelRulesMigration(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE label_rules (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          kind TEXT NOT NULL,
          value TEXT NOT NULL,
          action TEXT NOT NULL,
          target TEXT,
          created_at REAL NOT NULL);
        CREATE TRIGGER label_rules_record_insert AFTER INSERT ON label_rules BEGIN INSERT INTO record_dirty(key, version) VALUES ('labels', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER label_rules_record_update AFTER UPDATE ON label_rules BEGIN INSERT INTO record_dirty(key, version) VALUES ('labels', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER label_rules_record_delete AFTER DELETE ON label_rules BEGIN INSERT INTO record_dirty(key, version) VALUES ('labels', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        """)
    }

    /// A step that exchanged the document with a model keeps the prompts and raw answers under one key,
    /// `TraceStep.exchangeKey`, which retention clears after `traceRawRetentionDays` (docs/using-arrumator.md). They
    /// were `calls` for a reading and `raw` for an image description.
    static func traceExchangesMigration(_ db: Database) throws {
        try db.execute(sql: """
        UPDATE trace_steps SET output_json = json_set(json_remove(output_json, '$.calls'), '$.exchange', json(output_json -> '$.calls'))
          WHERE stage = 'analyse' AND json_valid(output_json) AND json_type(output_json, '$.calls') IS NOT NULL;
        UPDATE trace_steps SET output_json = json_set(json_remove(output_json, '$.raw'), '$.exchange', output_json ->> '$.raw')
          WHERE stage = 'vlm' AND json_valid(output_json) AND json_type(output_json, '$.raw') IS NOT NULL;
        """)
    }
}
// swiftlint:enable line_length
