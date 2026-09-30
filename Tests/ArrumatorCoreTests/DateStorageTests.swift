@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// Every date column is REAL (Unix seconds). GRDB encodes a bare `Date` as text, which compares wrongly against a
/// REAL column and fails to decode, so both the record strategy and SQL comparisons are pinned here.
@Suite struct DateStorageTests {
    @Test func recordsStoreDatesAsUnixSeconds() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        let filed = Date(timeIntervalSince1970: 1_800_000_000)
        try queue.write { db in
            var doc = DocumentRecord.arrived(path: "/tmp/a.pdf", sha256: "h", size: 1, uttype: "pdf", inode: nil, modified: nil,
                                             now: TestTime.start)
            doc.filedAt = filed
            try doc.insert(db)
            #expect(try String.fetchOne(db, sql: "SELECT typeof(added_at) FROM documents") == "real", "a date is stored as Unix seconds, so SQL compares it rightly")
            #expect(try String.fetchOne(db, sql: "SELECT typeof(filed_at) FROM documents") == "real", "an optional date too")
            let reloaded = try #require(try DocumentRecord.fetchOne(db))
            #expect(reloaded.filedAt == filed, "and reads back as the same moment")
        }
    }

    @Test func textDatesFromEarlierReleasesAreConverted() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1_initial")
        try queue.write { db in
            // A row as that release wrote it, with dates as GRDB's default strategy wrote them before the fix.
            try db.execute(sql: """
                INSERT INTO documents (uid, path, original_filename, sha256, size, uttype, status, added_at, filed_at, created_at, updated_at)
                VALUES ('b', '/tmp/b.pdf', 'b.pdf', 'h', 1, 'pdf', 'filed', '2026-09-22 18:23:10.902', '2026-09-22 18:23:32.667', 0, 0)
                """)
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.read { db in
            #expect(try String.fetchOne(db, sql: "SELECT typeof(added_at) FROM documents") == "real", "a date an earlier release wrote as text becomes Unix seconds")
            let doc = try #require(try DocumentRecord.fetchOne(db))
            // 2026-09-22 18:23:10.902 UTC; julianday arithmetic keeps roughly millisecond precision.
            #expect(abs(doc.addedAt.timeIntervalSince1970 - 1_790_101_390.902) < 0.01, "and keeps the moment it recorded")
            #expect(abs(try #require(doc.filedAt).timeIntervalSince1970 - 1_790_101_412.667) < 0.01, "an optional date too")
        }
    }

    @Test func jobsScheduledForLaterAreNotDueYet() async throws {
        let time = TestTime(.advances)
        let jobs = JobStore(database: try AppDatabase.inMemory(), time: time)
        let id = try #require(try await jobs.enqueue(path: "/tmp/c.txt", kind: .ingest))
        var job = try #require(try await jobs.job(id: id))
        job.nextRunAt = time.now().addingTimeInterval(30)
        try await jobs.update(job)
        #expect(try await jobs.nextDue() == nil, "a job waiting out its retry delay is not taken early")
        #expect(try await jobs.earliestPending() == TestTime.start.addingTimeInterval(30), "the worker sleeps until exactly then")
        time.advance(by: 31)
        #expect(try await jobs.nextDue()?.id == id, "once its time has come, it is taken")
    }

    @Test func aJobStuckInAStageIsFoundByTheWatchdog() async throws {
        let time = TestTime(.advances)
        let jobs = JobStore(database: try AppDatabase.inMemory(), time: time)
        let waiting = try #require(try await jobs.enqueue(path: "/tmp/waiting.txt", kind: .ingest))
        let stuck = try #require(try await jobs.enqueue(path: "/tmp/stuck.txt", kind: .ingest, state: .extracting))
        time.advance(by: 601)
        let fresh = try #require(try await jobs.enqueue(path: "/tmp/fresh.txt", kind: .ingest, state: .analysing))
        let found = try await jobs.stale(olderThan: 600).compactMap(\.id)
        #expect(found == [stuck], "only a job in a working stage, unchanged for longer than the watchdog allows, is stuck")
        #expect(!found.contains(waiting) && !found.contains(fresh), "a queued job waits its turn; a recent one is working")
    }

    @Test func aJobWaitingToRetryItsReadingIsScheduled() async throws {
        let jobs = JobStore(database: try AppDatabase.inMemory(), time: TestTime(.advances))
        let id = try #require(try await jobs.enqueue(path: "/tmp/d.txt", kind: .ingest, state: .analysing))
        var job = try #require(try await jobs.job(id: id))
        let retryAt = Date(timeIntervalSince1970: 1_900_000_000)
        job.nextRunAt = retryAt
        try await jobs.update(job)
        #expect(try await jobs.earliestPending() == retryAt,
                "a reading that failed while Ollama was down is retried when its delay is over, not at the next unrelated file")
    }
}
