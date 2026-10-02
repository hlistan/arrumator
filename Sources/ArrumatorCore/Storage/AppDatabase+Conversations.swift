// swiftlint:disable line_length - migration SQL is kept as written when it shipped
import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of conversations about search tasks' documents, in the order they shipped, after
    /// `v17_tags`.
    static func registerConversationMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v18_taskConversations", migrate: conversationsMigration)
    }

    /// `v18_taskConversations`. Questions about a search task's documents and their answers
    /// (docs/how-it-works.md#talking-with-a-tasks-documents), in the order they were asked, each waiting in a queue of
    /// its own until it is answered. They are the user's, so a change marks the task's file in the archive's
    /// `System/Conversations`, which a rebuild reads back; renaming a task, or its request being read as another name,
    /// marks it too, as the file is headed with the task's name. No task has a conversation before this.
    static func conversationsMigration(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE search_task_turns (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          task_id INTEGER NOT NULL REFERENCES search_tasks(id) ON DELETE CASCADE,
          question TEXT NOT NULL,
          state TEXT NOT NULL,
          answer TEXT,
          sources_json TEXT,
          finding_json TEXT,
          model TEXT,
          problem TEXT,
          last_trace_id INTEGER,
          next_run_at REAL,
          asked_at REAL NOT NULL,
          answered_at REAL);
        CREATE INDEX search_task_turns_task ON search_task_turns(task_id, id);
        CREATE INDEX search_task_turns_state ON search_task_turns(state, next_run_at);
        CREATE TRIGGER search_task_turns_record_insert AFTER INSERT ON search_task_turns BEGIN INSERT INTO record_dirty(key, version) VALUES ('conversation:' || NEW.task_id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_task_turns_record_update AFTER UPDATE OF question, state, answer, sources_json, finding_json, model, problem, asked_at, answered_at ON search_task_turns BEGIN INSERT INTO record_dirty(key, version) VALUES ('conversation:' || NEW.task_id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_task_turns_record_delete AFTER DELETE ON search_task_turns BEGIN INSERT INTO record_dirty(key, version) VALUES ('conversation:' || OLD.task_id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        CREATE TRIGGER search_tasks_conversation_name AFTER UPDATE OF prompt, title, plan_json ON search_tasks WHEN EXISTS (SELECT 1 FROM search_task_turns WHERE task_id = NEW.id) BEGIN INSERT INTO record_dirty(key, version) VALUES ('conversation:' || NEW.id, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        """)
    }
}
// swiftlint:enable line_length
