import Foundation
import GRDB

extension AppDatabase {
    /// Every migration of the index, in the order they shipped, each registered by the file of the change it belongs to.
    /// A migration is what an installed database once ran: it names tables, columns and values as they were then, as
    /// literals, never through today's types, which may no longer have them or write them otherwise, and it reads the
    /// time, when it records one, from `time`, the clock the index is opened with.
    static func migrator(time: any TimeSource) -> DatabaseMigrator {
        var m = DatabaseMigrator()
        registerFolderMigrations(&m, time: time)
        for register in [registerLabelMigrations, registerSearchTaskMigrations, registerTagMigrations, registerConversationMigrations,
                         registerRecordMigrations, registerQueueMigrations, registerJobMigrations, registerLabelIndexMigrations,
                         registerTwoPlacesMigrations, registerSplitLabelMigrations, registerReadingAgainMigrations, registerSidecarMigrations] {
            register(&m)
        }
        return m
    }
}
