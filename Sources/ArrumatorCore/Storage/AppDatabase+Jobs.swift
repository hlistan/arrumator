import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of the ingest queue, in the order they shipped, after `v20_queueWorkers`.
    static func registerJobMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v21_jobClaims", migrate: jobClaimsMigration)
        migrator.registerMigration("v22_jobsWaitForTheirModel", migrate: modelWaitMigration)
        migrator.registerMigration("v23_endedJobsKeepNoText", migrate: endedJobsMigration)
    }

    /// `v23_endedJobsKeepNoText`. A job that has ended keeps neither its document's text nor its embedding
    /// (`JobStore.withoutText`), which every job that ended before kept for ever. Written out as this release reads them.
    static func endedJobsMigration(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE jobs SET payload_json = json_remove(payload_json, '$.content', '$.outcome.embedding')
            WHERE json_valid(payload_json) AND state NOT IN ('pending', 'hashing', 'extracting', 'analysing', 'filing')
            """)
    }

    /// `v22_jobsWaitForTheirModel`. A job whose model was not installed was `held`, a state nothing took it out of; it
    /// now waits at its stage for the model, as one does now (`IngestCoordinator.handleFailure`). Each goes back to the
    /// stage after the last one its payload says it finished, due at once; one whose file a later job has been queued
    /// for, whatever became of that job (filed, held, waiting), or that another job waits for, stays ended
    /// (`jobs_active_path` allows one active job per path). The states are those of this release, written out, as
    /// every migration writes what it reads.
    static func modelWaitMigration(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE jobs SET state = 'cancelled' WHERE state = 'held' AND (
              EXISTS (SELECT 1 FROM jobs a WHERE a.source_path = jobs.source_path
                AND a.state IN ('pending', 'hashing', 'extracting', 'analysing', 'filing'))
              OR EXISTS (SELECT 1 FROM jobs l WHERE l.source_path = jobs.source_path AND l.id > jobs.id));
            UPDATE jobs SET next_run_at = updated_at, state = CASE
              WHEN kind = 'reindex' THEN 'pending'
              WHEN json_extract(payload_json, '$.outcome') IS NOT NULL THEN 'filing'
              WHEN json_extract(payload_json, '$.content') IS NOT NULL THEN 'analysing'
              WHEN doc_id IS NOT NULL THEN 'extracting'
              ELSE 'pending' END
            WHERE state = 'held';
            """)
    }

    /// `v21_jobClaims`. A job is taken by the write that claims it (`JobStore.nextDue`): the worker's claim and its
    /// process (`JobClaims`). A job queued before has none, and is taken as any job no worker has.
    static func jobClaimsMigration(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE jobs ADD COLUMN claim TEXT;
            ALTER TABLE jobs ADD COLUMN claimed_by TEXT;
            """)
    }
}
