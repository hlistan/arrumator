// swiftlint:disable line_length - migration SQL is kept as written when it shipped
import Foundation
import GRDB

extension AppDatabase {
    /// `v14_searchTasks`. Search tasks (docs/how-it-works.md#search-tasks): a prompt in the user's words, what the model read it as, the
    /// set of documents it found as the user edited it, and every export of that set. They are the user's, so a
    /// change marks the archive's `System/_tasks.md`, which a rebuild reads back.
    static func searchTasksMigration(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE search_tasks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          prompt TEXT NOT NULL,
          title TEXT,
          grouping_json TEXT,
          state TEXT NOT NULL,
          plan_json TEXT,
          model TEXT,
          problem TEXT,
          last_trace_id INTEGER,
          next_run_at REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL);
        CREATE INDEX search_tasks_state ON search_tasks(state, next_run_at);
        CREATE TABLE search_task_documents (
          task_id INTEGER NOT NULL REFERENCES search_tasks(id) ON DELETE CASCADE,
          doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          inclusion TEXT NOT NULL,
          seq INTEGER NOT NULL,
          PRIMARY KEY (task_id, doc_id));
        CREATE TABLE search_task_exports (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          task_id INTEGER NOT NULL REFERENCES search_tasks(id) ON DELETE CASCADE,
          at REAL NOT NULL,
          format TEXT NOT NULL,
          path TEXT NOT NULL,
          manifest_json TEXT NOT NULL);
        CREATE INDEX search_task_exports_task ON search_task_exports(task_id, at);
        CREATE TRIGGER search_tasks_record_insert AFTER INSERT ON search_tasks BEGIN INSERT INTO record_dirty(key, version) VALUES ('tasks', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_tasks_record_update AFTER UPDATE OF prompt, title, grouping_json, state, plan_json, model, problem, created_at, updated_at ON search_tasks BEGIN INSERT INTO record_dirty(key, version) VALUES ('tasks', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_tasks_record_delete AFTER DELETE ON search_tasks BEGIN INSERT INTO record_dirty(key, version) VALUES ('tasks', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_task_documents_record_insert AFTER INSERT ON search_task_documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('tasks', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_task_documents_record_update AFTER UPDATE ON search_task_documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('tasks', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_task_documents_record_delete AFTER DELETE ON search_task_documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('tasks', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_task_exports_record_insert AFTER INSERT ON search_task_exports BEGIN INSERT INTO record_dirty(key, version) VALUES ('tasks', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_task_exports_record_update AFTER UPDATE ON search_task_exports BEGIN INSERT INTO record_dirty(key, version) VALUES ('tasks', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_task_exports_record_delete AFTER DELETE ON search_task_exports BEGIN INSERT INTO record_dirty(key, version) VALUES ('tasks', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        """)
    }

    /// `v15_taskEffort`. Each task is read with an effort (`TaskEffort`) and, if the user gave it one, its own model
    /// (docs/how-it-works.md#search-tasks). Tasks asked before were read as `medium` reads them, with the profile's
    /// model, so that is what they keep. The archive's `System/_tasks.md` is marked to be written again with both, and
    /// the trigger that marks it follows them.
    static func taskEffortMigration(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE search_tasks ADD COLUMN effort TEXT NOT NULL DEFAULT 'medium';
        ALTER TABLE search_tasks ADD COLUMN assigned_model TEXT;
        DROP TRIGGER search_tasks_record_update;
        CREATE TRIGGER search_tasks_record_update AFTER UPDATE OF prompt, title, grouping_json, effort, assigned_model, state, plan_json, model, problem, created_at, updated_at ON search_tasks BEGIN INSERT INTO record_dirty(key, version) VALUES ('tasks', 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        INSERT INTO record_dirty(key, version) SELECT 'tasks', 1 WHERE EXISTS (SELECT 1 FROM search_tasks) ON CONFLICT(key) DO UPDATE SET version = version + 1;
        """)
    }
}
// swiftlint:enable line_length
