// swiftlint:disable line_length - migration SQL is kept as written when it shipped
import Foundation
import GRDB

extension AppDatabase {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        // A migration is what an installed database once ran: it names tables, columns and values as they were then,
        // never through today's types, which may no longer have them.
        m.registerMigration("v1_initial") { db in
            try db.execute(sql: """
            CREATE TABLE folders (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              uid TEXT NOT NULL UNIQUE,
              parent_id INTEGER REFERENCES folders(id) ON DELETE SET NULL,
              code TEXT NOT NULL,
              name TEXT NOT NULL,
              rel_path TEXT NOT NULL,
              kind TEXT NOT NULL,
              role TEXT,
              auto_file INTEGER NOT NULL DEFAULT 1,
              year_subfolders INTEGER NOT NULL DEFAULT 0,
              year_rule TEXT NOT NULL DEFAULT 'document_date',
              origin TEXT NOT NULL DEFAULT 'learned',
              description TEXT NOT NULL DEFAULT '',
              about_json TEXT NOT NULL DEFAULT '{}',
              description_hash TEXT NOT NULL DEFAULT '',
              generated_hash TEXT,
              user_edited INTEGER NOT NULL DEFAULT 0,
              inode INTEGER,
              sort INTEGER NOT NULL DEFAULT 0,
              is_archived INTEGER NOT NULL DEFAULT 0,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL);
            CREATE UNIQUE INDEX folders_code_active ON folders(code) WHERE is_archived = 0;
            CREATE INDEX folders_parent ON folders(parent_id, sort);

            CREATE TABLE correspondents (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              canonical_name TEXT NOT NULL UNIQUE COLLATE NOCASE,
              country TEXT,
              aliases_json TEXT NOT NULL DEFAULT '[]',
              stable_keys_json TEXT NOT NULL DEFAULT '[]',
              email_domains_json TEXT NOT NULL DEFAULT '[]',
              web_domains_json TEXT NOT NULL DEFAULT '[]',
              default_folder_code TEXT,
              filed_count INTEGER NOT NULL DEFAULT 0,
              origin TEXT NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL);

            CREATE TABLE documents (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              uid TEXT NOT NULL UNIQUE,
              path TEXT NOT NULL,
              original_filename TEXT NOT NULL,
              sha256 TEXT NOT NULL,
              size INTEGER NOT NULL,
              uttype TEXT NOT NULL,
              inode INTEGER,
              folder_id INTEGER REFERENCES folders(id) ON DELETE SET NULL,
              correspondent_id INTEGER REFERENCES correspondents(id) ON DELETE SET NULL,
              correspondent TEXT,
              doc_type TEXT,
              doc_date TEXT,
              period_year INTEGER,
              title TEXT,
              language TEXT,
              page_count INTEGER,
              status TEXT NOT NULL,
              band TEXT,
              confidence REAL,
              decided_by TEXT,
              rationale TEXT,
              decision_json TEXT,
              content_json TEXT,
              tags_json TEXT,
              duplicate_of INTEGER REFERENCES documents(id) ON DELETE SET NULL,
              last_trace_id INTEGER,
              added_at REAL NOT NULL,
              filed_at REAL,
              extracted_at REAL,
              embedded_at REAL,
              file_mtime REAL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL);
            CREATE INDEX documents_sha ON documents(sha256);
            CREATE INDEX documents_folder ON documents(folder_id, doc_date);
            CREATE INDEX documents_status ON documents(status);
            CREATE INDEX documents_added ON documents(added_at DESC);
            CREATE INDEX documents_corr ON documents(correspondent);
            CREATE INDEX documents_type ON documents(doc_type);
            CREATE INDEX documents_path ON documents(path);
            CREATE INDEX documents_inode ON documents(inode);

            CREATE TABLE document_text (
              doc_id INTEGER PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
              title TEXT NOT NULL DEFAULT '',
              correspondent TEXT NOT NULL DEFAULT '',
              filename TEXT NOT NULL DEFAULT '',
              body TEXT NOT NULL DEFAULT '',
              summary TEXT,
              metadata_json TEXT,
              extractor_version TEXT);

            CREATE TABLE embeddings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
              chunk_index INTEGER NOT NULL DEFAULT 0,
              model TEXT NOT NULL,
              dim INTEGER NOT NULL,
              vector BLOB NOT NULL,
              text_hash TEXT NOT NULL,
              created_at REAL NOT NULL,
              UNIQUE(doc_id, chunk_index, model));

            CREATE TABLE folder_embeddings (
              folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
              model TEXT NOT NULL,
              description_hash TEXT NOT NULL,
              vector BLOB NOT NULL,
              created_at REAL NOT NULL,
              PRIMARY KEY(folder_id, model));

            CREATE TABLE jobs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              kind TEXT NOT NULL,
              doc_id INTEGER REFERENCES documents(id) ON DELETE CASCADE,
              source_path TEXT NOT NULL,
              state TEXT NOT NULL,
              attempt INTEGER NOT NULL DEFAULT 0,
              next_run_at REAL,
              last_error TEXT,
              payload_json TEXT NOT NULL DEFAULT '{}',
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL);
            CREATE INDEX jobs_state ON jobs(state, next_run_at);
            CREATE UNIQUE INDEX jobs_active_path ON jobs(source_path)
              WHERE state IN ('pending','hashing','extracting','classifying','filing');

            CREATE TABLE traces (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              doc_id INTEGER REFERENCES documents(id) ON DELETE SET NULL,
              job_id INTEGER REFERENCES jobs(id) ON DELETE SET NULL,
              attempt INTEGER NOT NULL DEFAULT 0,
              source TEXT NOT NULL,
              started_at REAL NOT NULL,
              finished_at REAL,
              outcome TEXT,
              app_version TEXT NOT NULL,
              prompt_version INTEGER NOT NULL,
              taxonomy_version INTEGER NOT NULL,
              model_chat TEXT,
              model_vision TEXT,
              model_embed TEXT,
              settings_json TEXT NOT NULL,
              total_ms REAL);
            CREATE INDEX traces_doc ON traces(doc_id, started_at DESC);

            CREATE TABLE trace_steps (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              trace_id INTEGER NOT NULL REFERENCES traces(id) ON DELETE CASCADE,
              seq INTEGER NOT NULL,
              stage TEXT NOT NULL,
              status TEXT NOT NULL,
              started_at REAL NOT NULL,
              duration_ms REAL NOT NULL,
              input_json TEXT,
              output_json TEXT,
              error TEXT);
            CREATE INDEX trace_steps_trace ON trace_steps(trace_id, seq);
            CREATE INDEX trace_steps_stage ON trace_steps(stage);

            CREATE TABLE events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              at REAL NOT NULL,
              doc_id INTEGER REFERENCES documents(id) ON DELETE SET NULL,
              job_id INTEGER REFERENCES jobs(id) ON DELETE SET NULL,
              trace_id INTEGER REFERENCES traces(id) ON DELETE SET NULL,
              kind TEXT NOT NULL,
              actor TEXT NOT NULL,
              summary TEXT NOT NULL DEFAULT '',
              payload_json TEXT NOT NULL DEFAULT '{}');
            CREATE INDEX events_at ON events(at DESC);
            CREATE INDEX events_doc ON events(doc_id, at DESC);
            CREATE INDEX events_kind ON events(kind, at DESC);

            CREATE TABLE corrections (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
              at REAL NOT NULL,
              source TEXT NOT NULL,
              from_folder_id INTEGER REFERENCES folders(id) ON DELETE SET NULL,
              to_folder_id INTEGER REFERENCES folders(id) ON DELETE SET NULL,
              from_filename TEXT,
              to_filename TEXT,
              proposed_json TEXT,
              edited_fields_json TEXT,
              trace_id INTEGER REFERENCES traces(id) ON DELETE SET NULL);
            CREATE INDEX corrections_doc ON corrections(doc_id);
            CREATE INDEX corrections_to ON corrections(to_folder_id);
            CREATE INDEX corrections_at ON corrections(at DESC);

            CREATE TABLE memories (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
              folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
              folder_code TEXT NOT NULL,
              embedding BLOB NOT NULL,
              model TEXT NOT NULL,
              summary_line TEXT NOT NULL,
              correspondent_id INTEGER REFERENCES correspondents(id) ON DELETE SET NULL,
              doc_type TEXT NOT NULL,
              language TEXT NOT NULL,
              stable_keys_json TEXT NOT NULL DEFAULT '[]',
              weight REAL NOT NULL,
              source TEXT NOT NULL,
              orphaned INTEGER NOT NULL DEFAULT 0,
              created_at REAL NOT NULL);
            CREATE INDEX memories_folder ON memories(folder_id, created_at DESC);
            CREATE INDEX memories_doc ON memories(doc_id);

            CREATE TABLE rules (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              enabled INTEGER NOT NULL DEFAULT 1,
              priority INTEGER NOT NULL DEFAULT 100,
              origin TEXT NOT NULL,
              confirmed INTEGER NOT NULL DEFAULT 0,
              predicates_json TEXT NOT NULL,
              action_json TEXT NOT NULL,
              support INTEGER NOT NULL DEFAULT 0,
              hits INTEGER NOT NULL DEFAULT 0,
              contradictions INTEGER NOT NULL DEFAULT 0,
              last_hit_at REAL,
              explanation TEXT NOT NULL DEFAULT '',
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL);

            CREATE TABLE proposals (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              kind TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending',
              title TEXT NOT NULL,
              folder_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
              payload_json TEXT NOT NULL,
              created_at REAL NOT NULL,
              resolved_at REAL);
            CREATE INDEX proposals_status ON proposals(status, created_at DESC);

            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)

            try db.create(virtualTable: "document_fts", using: FTS5()) { t in
                t.synchronize(withTable: "document_text")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2, 3]
                t.column("title")
                t.column("correspondent")
                t.column("filename")
                t.column("body")
            }
        }
        /// Releases before this one stored dates through GRDB's default strategy, which writes text, although every
        /// date column is declared REAL. Converting in place keeps existing archives readable.
        m.registerMigration("v2_datesAsUnixSeconds") { db in
            try db.execute(sql: """
            UPDATE folders SET created_at = (julianday(created_at) - 2440587.5) * 86400.0 WHERE typeof(created_at) = 'text';
            UPDATE folders SET updated_at = (julianday(updated_at) - 2440587.5) * 86400.0 WHERE typeof(updated_at) = 'text';
            UPDATE correspondents SET created_at = (julianday(created_at) - 2440587.5) * 86400.0 WHERE typeof(created_at) = 'text';
            UPDATE correspondents SET updated_at = (julianday(updated_at) - 2440587.5) * 86400.0 WHERE typeof(updated_at) = 'text';
            UPDATE documents SET added_at = (julianday(added_at) - 2440587.5) * 86400.0 WHERE typeof(added_at) = 'text';
            UPDATE documents SET filed_at = (julianday(filed_at) - 2440587.5) * 86400.0 WHERE typeof(filed_at) = 'text';
            UPDATE documents SET extracted_at = (julianday(extracted_at) - 2440587.5) * 86400.0 WHERE typeof(extracted_at) = 'text';
            UPDATE documents SET embedded_at = (julianday(embedded_at) - 2440587.5) * 86400.0 WHERE typeof(embedded_at) = 'text';
            UPDATE documents SET file_mtime = (julianday(file_mtime) - 2440587.5) * 86400.0 WHERE typeof(file_mtime) = 'text';
            UPDATE documents SET created_at = (julianday(created_at) - 2440587.5) * 86400.0 WHERE typeof(created_at) = 'text';
            UPDATE documents SET updated_at = (julianday(updated_at) - 2440587.5) * 86400.0 WHERE typeof(updated_at) = 'text';
            UPDATE embeddings SET created_at = (julianday(created_at) - 2440587.5) * 86400.0 WHERE typeof(created_at) = 'text';
            UPDATE folder_embeddings SET created_at = (julianday(created_at) - 2440587.5) * 86400.0 WHERE typeof(created_at) = 'text';
            UPDATE jobs SET next_run_at = (julianday(next_run_at) - 2440587.5) * 86400.0 WHERE typeof(next_run_at) = 'text';
            UPDATE jobs SET created_at = (julianday(created_at) - 2440587.5) * 86400.0 WHERE typeof(created_at) = 'text';
            UPDATE jobs SET updated_at = (julianday(updated_at) - 2440587.5) * 86400.0 WHERE typeof(updated_at) = 'text';
            UPDATE traces SET started_at = (julianday(started_at) - 2440587.5) * 86400.0 WHERE typeof(started_at) = 'text';
            UPDATE traces SET finished_at = (julianday(finished_at) - 2440587.5) * 86400.0 WHERE typeof(finished_at) = 'text';
            UPDATE trace_steps SET started_at = (julianday(started_at) - 2440587.5) * 86400.0 WHERE typeof(started_at) = 'text';
            UPDATE events SET at = (julianday(at) - 2440587.5) * 86400.0 WHERE typeof(at) = 'text';
            UPDATE corrections SET at = (julianday(at) - 2440587.5) * 86400.0 WHERE typeof(at) = 'text';
            UPDATE memories SET created_at = (julianday(created_at) - 2440587.5) * 86400.0 WHERE typeof(created_at) = 'text';
            UPDATE rules SET last_hit_at = (julianday(last_hit_at) - 2440587.5) * 86400.0 WHERE typeof(last_hit_at) = 'text';
            UPDATE rules SET created_at = (julianday(created_at) - 2440587.5) * 86400.0 WHERE typeof(created_at) = 'text';
            UPDATE rules SET updated_at = (julianday(updated_at) - 2440587.5) * 86400.0 WHERE typeof(updated_at) = 'text';
            UPDATE proposals SET created_at = (julianday(created_at) - 2440587.5) * 86400.0 WHERE typeof(created_at) = 'text';
            UPDATE proposals SET resolved_at = (julianday(resolved_at) - 2440587.5) * 86400.0 WHERE typeof(resolved_at) = 'text';
            """)
        }

        // Logic: the prompts the model follows when placing documents, exactly one of them active. Rethink runs:
        // processed documents decided again (a trial on a few, or all of them), planned first and applied on request.
        // Identifiers are the key GRDB stores in `grdb_migrations`, so they are frozen once shipped. Renaming one
        // makes every installed database try to apply it again. `MigrationTests` pins the list.
        m.registerMigration("v3_brainsAndRethink") { db in
            try db.execute(sql: """
            CREATE TABLE brains (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              builtin_key TEXT UNIQUE,
              name TEXT NOT NULL,
              body TEXT NOT NULL,
              active INTEGER NOT NULL DEFAULT 0,
              position INTEGER NOT NULL,
              edited INTEGER NOT NULL DEFAULT 0,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL);
            CREATE UNIQUE INDEX brains_one_active ON brains(active) WHERE active = 1;

            CREATE TABLE rethink_runs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              status TEXT NOT NULL,
              scope TEXT NOT NULL,
              include_user_placed INTEGER NOT NULL,
              brains_version TEXT NOT NULL,
              planned_folders_json TEXT NOT NULL DEFAULT '[]',
              summary TEXT,
              started_at REAL NOT NULL,
              finished_at REAL);
            CREATE INDEX rethink_runs_status ON rethink_runs(status, started_at DESC);

            CREATE TABLE rethink_items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              run_id INTEGER NOT NULL REFERENCES rethink_runs(id) ON DELETE CASCADE,
              doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
              status TEXT NOT NULL,
              selected INTEGER NOT NULL DEFAULT 1,
              from_folder_id INTEGER,
              from_path TEXT NOT NULL,
              target_code TEXT,
              target_path TEXT,
              decision_json TEXT,
              trace_id INTEGER,
              error TEXT,
              updated_at REAL NOT NULL);
            CREATE INDEX rethink_items_run ON rethink_items(run_id, status);

            ALTER TABLE traces ADD COLUMN brains_version TEXT;
            """)
        }

        /// "Brains" became "logic" everywhere in the app, so the schema follows. Renaming in place keeps the filing
        /// logic the user has written and every past decision that refers to it.
        m.registerMigration("v4_renameBrainsToLogic") { db in
            try db.execute(sql: """
            ALTER TABLE brains RENAME TO logic;
            DROP INDEX brains_one_active;
            CREATE UNIQUE INDEX logic_one_active ON logic(active) WHERE active = 1;
            ALTER TABLE rethink_runs RENAME COLUMN brains_version TO logic_version;
            ALTER TABLE traces RENAME COLUMN brains_version TO logic_version;
            ALTER TABLE rules ADD COLUMN forgotten INTEGER NOT NULL DEFAULT 0;
            """)
        }

        /// Events recorded before "brains" became "logic" carry the old kind, which no longer decodes; any read of a
        /// history that holds one failed.
        m.registerMigration("v5_logicEvents") { db in
            try db.execute(sql: "UPDATE events SET kind = ? WHERE kind = 'brainChanged'", arguments: ["logicChanged"])
        }

        /// The archive becomes the record and the database its index (docs/storage.md). `record_files` holds the
        /// checksum of each record file as last written or read, `record_dirty` the files a change has made stale.
        /// Triggers mark them in the same transaction as the change, so no write path can miss one and a mark
        /// survives a crash. What already exists is marked too, so the first run writes every file.
        m.registerMigration("v6_archiveRecords") { db in
            try db.execute(sql: """
            CREATE TABLE record_files (path TEXT PRIMARY KEY, hash TEXT NOT NULL);
            CREATE TABLE record_dirty (key TEXT PRIMARY KEY, version INTEGER NOT NULL);
            CREATE TRIGGER documents_record_insert AFTER INSERT ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(NEW.path, replace(NEW.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER documents_record_update AFTER UPDATE OF path, original_filename, sha256, size, uttype, status, correspondent_id, correspondent, doc_type, doc_date, period_year, title, language, page_count, band, confidence, decided_by, rationale, decision_json, tags_json, duplicate_of, added_at, filed_at, uid ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(OLD.path, replace(OLD.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(NEW.path, replace(NEW.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER documents_record_delete AFTER DELETE ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(OLD.path, replace(OLD.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER correspondents_record_insert AFTER INSERT ON correspondents BEGIN INSERT INTO record_dirty(key, version) VALUES ('senders', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER correspondents_record_update AFTER UPDATE ON correspondents BEGIN INSERT INTO record_dirty(key, version) VALUES ('senders', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER correspondents_record_delete AFTER DELETE ON correspondents BEGIN INSERT INTO record_dirty(key, version) VALUES ('senders', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER rules_record_insert AFTER INSERT ON rules BEGIN INSERT INTO record_dirty(key, version) VALUES ('rules', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER rules_record_update AFTER UPDATE ON rules BEGIN INSERT INTO record_dirty(key, version) VALUES ('rules', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER rules_record_delete AFTER DELETE ON rules BEGIN INSERT INTO record_dirty(key, version) VALUES ('rules', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER corrections_record_insert AFTER INSERT ON corrections BEGIN INSERT INTO record_dirty(key, version) VALUES ('corrections', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER corrections_record_update AFTER UPDATE ON corrections BEGIN INSERT INTO record_dirty(key, version) VALUES ('corrections', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER corrections_record_delete AFTER DELETE ON corrections BEGIN INSERT INTO record_dirty(key, version) VALUES ('corrections', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER logic_record_insert AFTER INSERT ON logic BEGIN INSERT INTO record_dirty(key, version) VALUES ('logic', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER logic_record_update AFTER UPDATE ON logic BEGIN INSERT INTO record_dirty(key, version) VALUES ('logic', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER logic_record_delete AFTER DELETE ON logic BEGIN INSERT INTO record_dirty(key, version) VALUES ('logic', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER memories_record_insert AFTER INSERT ON memories BEGIN INSERT INTO record_dirty(key, version) VALUES ('memories', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER memories_record_update AFTER UPDATE OF doc_id, folder_id, folder_code, summary_line, correspondent_id, doc_type, language, stable_keys_json, weight, source, orphaned ON memories BEGIN INSERT INTO record_dirty(key, version) VALUES ('memories', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER memories_record_delete AFTER DELETE ON memories BEGIN INSERT INTO record_dirty(key, version) VALUES ('memories', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER events_record_insert AFTER INSERT ON events BEGIN INSERT INTO record_dirty(key, version) VALUES ('history:' || strftime('%Y-%m', NEW.at, 'unixepoch'), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER events_record_update AFTER UPDATE ON events BEGIN INSERT INTO record_dirty(key, version) VALUES ('history:' || strftime('%Y-%m', OLD.at, 'unixepoch'), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; INSERT INTO record_dirty(key, version) VALUES ('history:' || strftime('%Y-%m', NEW.at, 'unixepoch'), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER events_record_delete AFTER DELETE ON events BEGIN INSERT INTO record_dirty(key, version) VALUES ('history:' || strftime('%Y-%m', OLD.at, 'unixepoch'), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            INSERT OR IGNORE INTO record_dirty(key, version)
              SELECT DISTINCT 'documents:' || rtrim(path, replace(path, '/', '')), 1 FROM documents;
            INSERT OR IGNORE INTO record_dirty(key, version) SELECT 'senders', 1 WHERE EXISTS (SELECT 1 FROM correspondents);
            INSERT OR IGNORE INTO record_dirty(key, version) SELECT 'rules', 1 WHERE EXISTS (SELECT 1 FROM rules);
            INSERT OR IGNORE INTO record_dirty(key, version) SELECT 'corrections', 1 WHERE EXISTS (SELECT 1 FROM corrections);
            INSERT OR IGNORE INTO record_dirty(key, version) SELECT 'memories', 1 WHERE EXISTS (SELECT 1 FROM memories);
            INSERT OR IGNORE INTO record_dirty(key, version) SELECT 'logic', 1 WHERE EXISTS (SELECT 1 FROM logic);
            INSERT OR IGNORE INTO record_dirty(key, version)
              SELECT DISTINCT 'history:' || strftime('%Y-%m', at, 'unixepoch'), 1 FROM events;
            """)
        }

        /// An archive has one logic, kept in the archive, and an index of its own (docs/storage.md). The active logic
        /// stays, and built-in logic nobody changed keeps following the app. Logic the user wrote but had not
        /// activated has no place any more, so its text is kept in the history rather than lost.
        m.registerMigration("v7_oneLogicPerArchive") { db in
            let now = Date().unixSeconds
            for row in try Row.fetchAll(db, sql: "SELECT name, body FROM logic WHERE active = 0 AND (builtin_key IS NULL OR edited = 1)") {
                let name: String = row["name"]
                let body: String = row["body"]
                try db.execute(sql: "INSERT INTO events (at, kind, actor, summary, payload_json) VALUES (?, ?, ?, ?, ?)",
                               arguments: [now, "logicChanged", EventActor.system.rawValue,
                                           "Logic “\(name)” set aside, as an archive now has one logic; its text is kept here",
                                           JSON.string(["name": name, "body": body])])
            }
            let active = try Row.fetchOne(db, sql: "SELECT body, builtin_key IS NOT NULL AND edited = 0 AS follows FROM logic WHERE active = 1")
            try db.execute(sql: """
            DROP TABLE logic;
            CREATE TABLE logic (id INTEGER PRIMARY KEY CHECK (id = 1), body TEXT NOT NULL, builtin_hash TEXT);
            CREATE TRIGGER logic_record_insert AFTER INSERT ON logic BEGIN INSERT INTO record_dirty(key, version) VALUES ('logic', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER logic_record_update AFTER UPDATE ON logic BEGIN INSERT INTO record_dirty(key, version) VALUES ('logic', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER logic_record_delete AFTER DELETE ON logic BEGIN INSERT INTO record_dirty(key, version) VALUES ('logic', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            """)
            if let active {
                let body = (active["body"] as String).trimmingCharacters(in: .whitespacesAndNewlines)
                let follows: Bool = active["follows"]
                try db.execute(sql: "INSERT INTO logic (id, body, builtin_hash) VALUES (1, ?, ?)",
                               arguments: [body, follows ? FrontMatter.sha256(body) : nil])
            }
        }

        /// Undoing a filing forgets where it was filed, which was recorded as something learned, so it showed among
        /// the lessons. It is forgetting. The summary is the one the app wrote until then.
        m.registerMigration("v8_undoForgets") { db in
            try db.execute(sql: "UPDATE events SET kind = ? WHERE kind = ? AND summary = ?",
                           arguments: ["forgot", "learned", "Forgot where this was filed"])
        }

        /// The folder tree takes the shape the logic describes, at any depth, so a folder is no longer an area or a
        /// category; where it sits is its parent.
        m.registerMigration("v9_foldersOfAnyDepth") { db in
            try db.execute(sql: "ALTER TABLE folders DROP COLUMN kind")
        }
        /// What a folder stands for in the logic that made it (a sender, a subject or a topic) and which logic that was,
        /// so a sender's folder is recognised by its sender, not its name. Read from each folder's `_about.md`.
        m.registerMigration("v10_folderKinds") { db in
            try db.execute(sql: """
            ALTER TABLE folders ADD COLUMN level_kind TEXT;
            ALTER TABLE folders ADD COLUMN logic_version TEXT;
            """)
        }

        /// Documents are labelled, not filed into folders (docs/how-it-works.md). The local model reads each one for its
        /// labels, what it is and its name, and files it at the top of the archive; the folder tree, the logic, rules,
        /// filing memories, corrections, proposals and rethink runs are gone, with what they learned. A document keeps
        /// its place and its details: its filing decision becomes its analysis, and its labels, until the model gives
        /// them, are NULL. Each kind of label is a column of the full-text index, which is made again with them. Events
        /// of kinds that no longer exist are dropped, and every record file is written again.
        m.registerMigration("v11_labelsNotFolders") { db in
            try db.execute(sql: """
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
              correspondent_id INTEGER REFERENCES correspondents(id) ON DELETE SET NULL,
              correspondent TEXT,
              doc_type TEXT,
              doc_date TEXT,
              period_year INTEGER,
              title TEXT,
              language TEXT,
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
              SELECT id, uid, path, original_filename, sha256, size, uttype, inode, correspondent_id, correspondent, doc_type,
                     doc_date, period_year, title, language, page_count, status,
                     CASE WHEN decision_json IS NULL THEN NULL ELSE json_object(
                       'correspondent', json_extract(decision_json, '$.correspondent'),
                       'correspondentID', json_extract(decision_json, '$.correspondentID'),
                       'documentType', COALESCE(json_extract(decision_json, '$.documentType'), 'other'),
                       'documentDate', json_extract(decision_json, '$.documentDate'),
                       'dateSource', COALESCE(json_extract(decision_json, '$.dateSource'), 'none'),
                       'periodYear', json_extract(decision_json, '$.periodYear'),
                       'title', COALESCE(json_extract(decision_json, '$.title'), original_filename),
                       'fileName', json_extract(decision_json, '$.fileName'),
                       'language', COALESCE(json_extract(decision_json, '$.language'), 'und'),
                       'model', json_extract(decision_json, '$.modelInfo'),
                       'problems', CASE WHEN status IN ('needsReview', 'failed')
                         THEN json(COALESCE(json_extract(decision_json, '$.reviewReasons'), '[]')) ELSE json('[]') END) END,
                     content_json, NULL, duplicate_of, last_trace_id, added_at, filed_at, extracted_at, embedded_at, file_mtime,
                     created_at, updated_at
              FROM documents;
            DROP TABLE documents;
            ALTER TABLE documents_new RENAME TO documents;
            CREATE INDEX documents_sha ON documents(sha256);
            CREATE INDEX documents_status ON documents(status);
            CREATE INDEX documents_added ON documents(added_at DESC);
            CREATE INDEX documents_corr ON documents(correspondent);
            CREATE INDEX documents_type ON documents(doc_type);
            CREATE INDEX documents_path ON documents(path);
            CREATE INDEX documents_inode ON documents(inode);
            CREATE TRIGGER documents_record_insert AFTER INSERT ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(NEW.path, replace(NEW.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER documents_record_update AFTER UPDATE OF path, original_filename, sha256, size, uttype, status, correspondent_id, correspondent, doc_type, doc_date, period_year, title, language, page_count, analysis_json, labels_json, duplicate_of, added_at, filed_at, uid ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(OLD.path, replace(OLD.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(NEW.path, replace(NEW.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            CREATE TRIGGER documents_record_delete AFTER DELETE ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(OLD.path, replace(OLD.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
            DROP TABLE folders;

            ALTER TABLE correspondents DROP COLUMN default_folder_code;
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
              'logicChanged', 'rethink', 'rethought');

            ALTER TABLE document_text ADD COLUMN subject TEXT NOT NULL DEFAULT '';
            ALTER TABLE document_text ADD COLUMN object TEXT NOT NULL DEFAULT '';
            ALTER TABLE document_text ADD COLUMN jurisdiction TEXT NOT NULL DEFAULT '';
            ALTER TABLE document_text ADD COLUMN language TEXT NOT NULL DEFAULT '';

            DELETE FROM record_dirty;
            INSERT INTO record_dirty(key, version) SELECT DISTINCT 'documents:' || rtrim(path, replace(path, '/', '')), 1 FROM documents;
            INSERT INTO record_dirty(key, version) SELECT 'senders', 1 WHERE EXISTS (SELECT 1 FROM correspondents);
            INSERT OR IGNORE INTO record_dirty(key, version)
              SELECT DISTINCT 'history:' || strftime('%Y-%m', at, 'unixepoch'), 1 FROM events;
            """)
            // FTS5 cannot add a column: the index is made again with them, and fills itself from document_text.
            try db.dropFTS5SynchronizationTriggers(forTable: "document_fts")
            try db.drop(table: "document_fts")
            try db.create(virtualTable: "document_fts", using: FTS5()) { t in
                t.synchronize(withTable: "document_text")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2, 3]
                for column in ["title", "correspondent", "filename", "body", "subject", "object", "jurisdiction", "language"] {
                    t.column(column)
                }
            }
        }

        return m
    }
}
// swiftlint:enable line_length
