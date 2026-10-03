import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of how an index keeps to its archive's record files, in the order they shipped, after
    /// `v18_taskConversations`.
    static func registerRecordMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v19_unreadIndexRefusesRecords", migrate: unreadIndexMigration)
    }

    /// `v19_unreadIndexRefusesRecords`. An index that has read nothing of its archive yet (`meta.rebuild_pending` is
    /// `unread`: one just made, which `v1_initial` marks so in the transaction that makes it, or one whose rebuild was
    /// refused) takes no change to what the record files hold, from any writer in any process: every table they hold
    /// refuses an insert, an update or a delete, raising `notRebuiltMessage`, until its rebuild moves it to `unfinished`
    /// in the transaction that replaces it. What was done to it meanwhile would otherwise be dropped by the rebuild, or
    /// written over the files. An event that concerns nothing the index holds, such as a setting changed, is held in
    /// `meta` instead, which no trigger guards, and recorded once the index is rebuilt (`HistoryStore.insert`). The
    /// triggers are per row: an unread index holds none, so a migration changes none.
    static func unreadIndexMigration(_ db: Database) throws {
        for table in ["documents", "events", "label_rules", "search_tasks", "search_task_documents", "search_task_exports", "search_task_turns"] {
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                try db.execute(sql: """
                CREATE TRIGGER \(table)_unread_\(operation.lowercased()) BEFORE \(operation) ON \(table)
                WHEN EXISTS (SELECT 1 FROM meta WHERE key = 'rebuild_pending' AND value = 'unread')
                BEGIN SELECT RAISE(ABORT, 'arrumator: the index has not been rebuilt from the archive'); END
                """)
            }
        }
    }

    /// What the triggers of `v19_unreadIndexRefusesRecords` raise, as its SQL writes it.
    static let notRebuiltMessage = "arrumator: the index has not been rebuilt from the archive"
}
