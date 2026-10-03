import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of the queues the model works through for search tasks and conversations, in the order
    /// they shipped, after `v19_unreadIndexRefusesRecords`.
    static func registerQueueMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v20_queueWorkers", migrate: queueWorkersMigration)
    }

    /// `v20_queueWorkers`. A task whose request is being read, and a question being answered, keep the process that works
    /// on it (`worker`, a `ProcessTag`), as the app and each `arrumatorcli` command share the index: one a process that
    /// ended left behind goes back into the queue, one another process still works on is left to it, and what a reading or
    /// an answer keeps depends on its process still holding the item (`ModelQueue`). The column is the index's own: no
    /// record file holds it, so no trigger marks one. An item being read or answered when this ships was left by a
    /// process that has ended, as an upgrade restarts the app: it has no worker, and goes back into the queue.
    static func queueWorkersMigration(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE search_tasks ADD COLUMN worker TEXT;
        ALTER TABLE search_task_turns ADD COLUMN worker TEXT;
        """)
    }
}
