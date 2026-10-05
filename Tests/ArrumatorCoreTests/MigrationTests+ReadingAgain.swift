import Foundation
import GRDB
import Testing
@testable import ArrumatorCore
import ArrumatorTesting

/// Migrations of how documents are read again.
extension MigrationTests {
    @Test func readingAgainForSearchGivesWayAndAReadingAgainBegunBeforeReadsItsFileAgain() throws {
        let queue = try Self.installed(upTo: "v26_storedLabelsInTheirForm")
        let read = #"{"tags":[{"label":{"kind":"tag","value":"Taxes"},"source":"document"}],"content":{"text":"EDP"},"#
            + #""outcome":{"analysis":{"problems":[]},"labels":[]},"plannedPath":"/A/new.pdf","targetPath":"/A/new.pdf"}"#
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (id, kind, source_path, state, payload_json, created_at, updated_at) VALUES
                  (1, 'reindex', '/A/filed.pdf', 'pending', '{}', 0, 0), (2, 'reanalyse', '/A/read.pdf', 'filing', ?, 0, 0),
                  (3, 'reanalyse', '/A/begun.pdf', 'analysing', ?, 0, 0), (4, 'reanalyse', '/A/done.pdf', 'done', ?, 0, 0),
                  (5, 'ingest', '/Incoming/bill.pdf', 'filing', ?, 0, 0), (6, 'reanalyse', '/A/broken.pdf', 'filing', 'not json', 0, 0);
                """, arguments: [read, read, read, read])
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: "v27_readingAgain")
        let jobs = try queue.read { db in try JobRecord.order(Column("id")).fetchAll(db) }
        #expect(jobs.map(\.givesWay) == [true, false, false, false, false, false],
                "reading again for search gives way, as it always did by its kind; every other job comes in its turn")
        #expect(jobs.map(\.state) == [.pending, .extracting, .extracting, .done, .filing, .filing],
                "a document being read again goes back to reading its file; an ended job, an arrival and a payload no JSON stay")
        let begun = try #require(jobs.dropFirst().first)
        #expect(try begun.payload.content == nil && begun.payload.outcome == nil && begun.payload.plannedPath == nil
                    && begun.payload.targetPath == nil && begun.tags == [DocumentLabel(kind: .tag, value: "Taxes")],
                "what it had read is dropped, as a reading begun before kept nothing of the labels it began with, and its tags stay")
        #expect(jobs[4].payloadJson == read && jobs[3].payloadJson == read, "the arrival and the ended job keep what they had")
        let plan = try queue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM jobs WHERE doc_id = ? AND state IN (?, ?, ?, ?, ?)",
                             arguments: StatementArguments([Int64(1)] + JobState.allCases.filter(\.isActive).map(\.rawValue)))
                .map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("jobs_doc") }, "a document's active job is found by an index, not by reading the queue: \(plan)")
    }

    @Test func aReadingAgainCutOffWhileItWasFiledFinishesAndAJobFollowsItsDocument() throws {
        let queue = try Self.installed(upTo: "v26_storedLabelsInTheirForm")
        let labels = [DocumentLabel(kind: .sender, value: "EDP Comercial"), DocumentLabel(kind: .tag, value: "Taxes")]
        let filing = #"{"content":{"text":"EDP"},"outcome":{"analysis":{"problems":[]},"labels":[]},"plannedPath":"/A/new.pdf"}"#
        try queue.write { db in
            var document = DocumentRecord.arrived(path: "/A/bill.pdf", sha256: "a", size: 1, uttype: "public.data", inode: nil,
                                                  modified: nil, now: Date(timeIntervalSince1970: 0))
            document.status = .filed
            document.labelsJson = try JSON.string(labels)
            try document.insert(db)
            try db.execute(sql: """
                INSERT INTO jobs (id, kind, doc_id, source_path, state, payload_json, created_at, updated_at) VALUES
                  (1, 'reanalyse', ?, '/A/bill.pdf', 'filing', ?, 0, 0)
                """, arguments: [document.id, filing])
        }
        try AppDatabase.migrator(time: TestTime(.advances)).migrate(queue, upTo: "v27_readingAgain")
        let job = try #require(try queue.read { db in try JobRecord.fetchOne(db, key: 1) })
        let (planned, rereading) = try queue.read { db in
            let row = try #require(try Row.fetchOne(db, sql: """
                SELECT json_extract(payload_json, '$.plannedPath') AS planned, json_extract(payload_json, '$.rereading') AS rereading
                FROM jobs WHERE id = 1
                """))
            return (row["planned"] as String?, JSON.decode(Rereading.self, from: row["rereading"] as String?))
        }
        #expect(job.state == .filing && planned == "/A/new.pdf"
                    && rereading == Rereading(before: labels, path: "/A/bill.pdf", changes: [], tags: nil),
                "a reading again whose file may have moved finishes filing, with what its document has now, as the earlier version saved it")
        try queue.write { db in try db.execute(sql: "UPDATE documents SET path = '/A/renamed.pdf' WHERE id = ?", arguments: [job.docId]) }
        let moved = try queue.read { db in try String.fetchOne(db, sql: "SELECT source_path FROM jobs WHERE id = 1") }
        #expect(moved == "/A/renamed.pdf", "a job reading a document again is where the document is, as it moves")
    }
}
