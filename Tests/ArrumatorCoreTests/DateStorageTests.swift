@testable import ArrumatorCore
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
            var doc = DocumentRecord.arrived(path: "/tmp/a.pdf", sha256: "h", size: 1, uttype: "pdf", inode: nil, modified: nil)
            doc.filedAt = filed
            try doc.insert(db)
            #expect(try String.fetchOne(db, sql: "SELECT typeof(added_at) FROM documents") == "real")
            #expect(try String.fetchOne(db, sql: "SELECT typeof(filed_at) FROM documents") == "real")
            let reloaded = try #require(try DocumentRecord.fetchOne(db))
            #expect(reloaded.filedAt == filed)
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
            #expect(try String.fetchOne(db, sql: "SELECT typeof(added_at) FROM documents") == "real")
            let doc = try #require(try DocumentRecord.fetchOne(db))
            // 2026-09-22 18:23:10.902 UTC; julianday arithmetic keeps roughly millisecond precision.
            #expect(abs(doc.addedAt.timeIntervalSince1970 - 1_790_101_390.902) < 0.01)
            #expect(abs(try #require(doc.filedAt).timeIntervalSince1970 - 1_790_101_412.667) < 0.01)
        }
    }

    @Test func jobsScheduledForLaterAreNotDueYet() async throws {
        let database = try AppDatabase.inMemory()
        let jobs = JobStore(database: database)
        let id = try #require(try await jobs.enqueue(path: "/tmp/c.txt", kind: .ingest))
        var job = try #require(try await jobs.job(id: id))
        job.nextRunAt = Date().addingTimeInterval(30)
        try await jobs.update(job)
        #expect(try await jobs.nextDue(now: Date()) == nil)
        #expect(try await jobs.nextDue(now: Date().addingTimeInterval(31))?.id == id)
        let earliest = try #require(try await jobs.earliestPending())
        #expect(abs(earliest.timeIntervalSinceNow - 30) < 2)
    }
}
