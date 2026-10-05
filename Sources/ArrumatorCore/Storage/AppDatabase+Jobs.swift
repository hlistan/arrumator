import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of the ingest queue, in the order they shipped, after `v20_queueWorkers`.
    static func registerJobMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v21_jobClaims", migrate: jobClaimsMigration)
        migrator.registerMigration("v22_jobsWaitForTheirModel", migrate: modelWaitMigration)
        migrator.registerMigration("v23_endedJobsKeepNoText", migrate: endedJobsMigration)
    }

    /// Registers the migrations of the ingest queue that shipped after `v26_storedLabelsInTheirForm`.
    static func registerReadingAgainMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v27_readingAgain", migrate: readingAgainMigration)
    }

    /// `v27_readingAgain`. A job may give way to every other (`JobRecord.givesWay`), as reading documents again after a
    /// rebuild (`reindex`) always did, by its kind. A job reading a document of the archive again is at the document's
    /// path as it moves (`jobs_follow_document`, by `jobs_doc`), as it reads the document where it is when its turn
    /// comes. And a document read again changes nothing until it is filed, when what it reads takes the place of
    /// everything it had at once (`IndexStore.replaceReading`), with what the job kept of when its reading began
    /// (`JobPayload.rereading`), which a job begun before kept nothing of. One that was filing it, its file moved or its
    /// filing recorded, is given what its document has now, as the earlier version had saved its reading already, and
    /// finishes; one that had read part way goes back to reading its file, what it had read dropped, and its document
    /// keeps what the earlier version saved of that reading until it is read again. The states and kinds are those of
    /// this release, written out, as every migration writes what it reads.
    static func readingAgainMigration(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE jobs ADD COLUMN gives_way BOOLEAN NOT NULL DEFAULT 0;
            UPDATE jobs SET gives_way = 1 WHERE kind = 'reindex';
            CREATE INDEX jobs_doc ON jobs(doc_id);
            CREATE TRIGGER jobs_follow_document AFTER UPDATE OF path ON documents WHEN NEW.path != OLD.path BEGIN
              UPDATE jobs SET source_path = NEW.path
              WHERE doc_id = NEW.id AND kind IN ('reanalyse', 'reindex') AND state IN ('pending','hashing','extracting','analysing','filing')
                AND NOT EXISTS (SELECT 1 FROM jobs a WHERE a.source_path = NEW.path
                                AND a.state IN ('pending','hashing','extracting','analysing','filing'));
            END;
            UPDATE jobs SET payload_json = json_set(payload_json, '$.rereading', json_object(
                'before', json(COALESCE((SELECT labels_json FROM documents WHERE id = jobs.doc_id), '[]')),
                'path', (SELECT path FROM documents WHERE id = jobs.doc_id), 'changes', json('[]')))
            WHERE kind = 'reanalyse' AND state = 'filing' AND json_valid(payload_json)
              AND json_extract(payload_json, '$.outcome') IS NOT NULL AND json_extract(payload_json, '$.content') IS NOT NULL
              AND (json_extract(payload_json, '$.plannedPath') IS NOT NULL OR json_extract(payload_json, '$.targetPath') IS NOT NULL)
              AND EXISTS (SELECT 1 FROM documents WHERE id = jobs.doc_id);
            UPDATE jobs SET state = 'extracting',
              payload_json = json_remove(payload_json, '$.content', '$.outcome', '$.plannedPath', '$.targetPath')
            WHERE kind = 'reanalyse' AND state IN ('analysing', 'filing') AND json_valid(payload_json)
              AND json_extract(payload_json, '$.rereading') IS NULL;
            """)
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
