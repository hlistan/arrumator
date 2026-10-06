@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// What a file that arrives is when the user changes a document recorded where it is as it arrives: decided in the
/// write that queues it, or decided once more as a pass after it would (the review of the fix of the final review of
/// #17).
extension IngestTests {
    /// Records a document at `path`, as an earlier run left it, with `status`.
    private func record(_ h: Harness, at path: String, status: DocumentStatus, sha256: String) async throws -> Int64 {
        var record = DocumentRecord.arrived(path: path, sha256: sha256, size: 1, uttype: "public.plain-text", inode: nil, modified: nil,
                                            now: h.env.time.now())
        record.status = status
        return try #require(try await h.services.documents.save(record).id)
    }

    /// A file saved again where a document was left in Incoming, which the user leaves for later as it arrives, is
    /// decided as a pass after it would decide it: a new arrival when the bytes are others, as the document left for
    /// later is the user's decision about the file it was, which this one does not inherit, and is ended; the document's
    /// own when they are its, which stays as the user left it.
    @Test(arguments: [false, true])
    func aDocumentLeftInIncomingLeftForLaterAsItsFileArrivesIsDecidedAsAfterwards(_ sameBytes: Bool) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let file = try h.env.drop("scan.txt", text: Self.bill)
        let path = file.spelledOnDisk.path
        // Undone there before, its file gone since, so its ending comes between the asking and the queueing; then left
        // in Incoming, its file saved again since, with other bytes or the same.
        let undone = try await record(h, at: path, status: .undone, sha256: "an earlier version")
        let left = try await record(h, at: path, status: .failed, sha256: sameBytes ? try HashService.sha256(of: file) : "an earlier version")
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER left_for_later_meanwhile AFTER UPDATE OF status ON documents
                WHEN NEW.status = 'missing' AND NEW.id != \(left) BEGIN
                  UPDATE documents SET status = 'held' WHERE id = \(left);
                END
                """)
        }
        let queued = await h.coordinator.enqueue(file)
        let ended = try await h.services.history.events(limit: 10, kinds: [.missing]).filter { $0.docId == left }
        if sameBytes {
            #expect(queued == nil, "its own file is not queued")
            #expect(try await h.services.documents.document(id: left)?.status == .held, "the document stays as the user left it")
            let jobs = try await h.jobs()
            #expect(ended.isEmpty && jobs.isEmpty, "never said to be gone, and nothing read")
            return
        }
        let id = try #require(queued, "the file is queued")
        #expect(try await h.services.jobs.job(id: id)?.docId == nil, "as a new arrival, not as the document left for later")
        #expect(try await h.services.documents.document(id: left)?.status == .missing, "which is ended")
        #expect(await h.coordinator.enqueue(file) == id, "a rescan finds the same job")
        let endedAfter = try await h.services.history.events(limit: 10, kinds: [.missing]).filter { $0.docId == left }
        #expect(endedAfter.count == 1, "and History says it ended once: \(endedAfter.map(\.summary))")
        await h.coordinator.drain()
        let read = try await h.services.documents.list(DocumentFilter(), limit: 5).filter { ![undone, left].contains($0.id ?? 0) }
        #expect(read.count == 1 && read.first?.status == .filed, "the file is filed, a document of its own: \(read.map(\.path))")
    }

    /// A file asked for where a document was left in Incoming, which the user has read again as it arrives, is that
    /// reading's: nothing is decided on the document as it was found, and asked once more, the request is found to be
    /// the reading's job, and gives it its tags.
    @Test func aFileAskedForAsItsDocumentIsReadAgainGivesThatReadingItsTags() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let file = try h.env.drop("scan.txt", text: Self.bill)
        let path = file.spelledOnDisk.path
        let id = try await record(h, at: path, status: .failed, sha256: "an earlier version")
        let found = try #require(try await h.services.documents.document(id: id))
        let reading = try await h.services.queueReadingAgain(id, settings: await h.services.settings.current)
        #expect(try await h.coordinator.queue(path, again: found, payload: JobPayload()) == nil, "nothing is decided on it as it was")
        #expect(await h.coordinator.enqueue(file, tags: ["Taxes 2024"]) == reading, "asked once more, it is the reading's job")
        let tags = try await h.services.jobs.job(id: reading)?.tags.map(\.value)
        #expect(tags == ["Taxes 2024"], "given the tags: \(tags ?? [])")
        #expect(try await h.services.documents.document(id: id)?.status == .processing, "the document is read as it is")
        #expect(try await h.services.history.events(limit: 10, kinds: [.missing]).isEmpty, "and is never said to be gone")
    }

    /// A document read again whose queueing fails changes nothing: its status and its job are written together, so a
    /// file arriving at its path never finds it being read with no job to read it.
    @Test func aReadingAgainWhoseQueueingFailsChangesNothing() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let file = try h.env.drop("scan.txt", text: Self.bill)
        let id = try await record(h, at: file.spelledOnDisk.path, status: .failed, sha256: "an earlier version")
        try await h.env.database.writer.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER queueing_fails BEFORE INSERT ON jobs BEGIN SELECT RAISE(ABORT, 'the queue is unavailable'); END")
        }
        await #expect(throws: (any Error).self) { try await h.services.queueReadingAgain(id, settings: await h.services.settings.current) }
        #expect(try await h.services.documents.document(id: id)?.status == .failed, "it is left as it was")
        #expect(try await h.services.history.events(limit: 10, kinds: [.retry]).isEmpty, "and nothing is said of it")
    }

    /// What becomes of a document between the user asking to read it again and that being queued: ended, as another
    /// file came where it was undone; its file removed, before the archive's watcher tells; filed into the archive, as
    /// one left in Incoming read meanwhile; given a tag; or left for later.
    enum BeforeItIsQueued: String, CaseIterable, Sendable { case ended, removed, filed, tagged, leftForLater }

    /// A reading again is decided on the document as the write that queues it finds it, never as the user's request
    /// found it: one ended meanwhile, or whose file is gone, is refused, and one changed is read as it is now, where it is,
    /// with its status and its tags.
    @Test(arguments: BeforeItIsQueued.allCases)
    func aReadingAgainIsDecidedOnTheDocumentAsItIsWhenQueued(_ meanwhile: BeforeItIsQueued) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let settings = await h.services.settings.current
        switch meanwhile {
        case .ended, .filed:
            let file = try h.env.drop("scan.txt", text: Self.bill)
            let id = try await record(h, at: file.spelledOnDisk.path, status: meanwhile == .ended ? .undone : .failed, sha256: "an earlier version")
            if meanwhile == .ended {
                try await h.services.documents.update(id) { $0.status = .missing }
                await #expect(throws: IngestError.cannotReadAgain(id), "one ended meanwhile is refused") {
                    try await h.services.queueReadingAgain(id, settings: settings)
                }
                #expect(try await h.services.documents.document(id: id)?.status == .missing, "and stays as it is")
                #expect(try await h.jobs().isEmpty, "nothing is queued")
                return
            }
            let filed = h.env.archive.appendingPathComponent("scan.txt")
            try FileManager.default.moveItem(at: file, to: filed)
            try await h.services.documents.update(id) { ($0.status, $0.path) = (.filed, filed.spelledOnDisk.path) }
            let job = try await h.services.queueReadingAgain(id, settings: settings)
            let reading = try #require(try await h.services.jobs.job(id: job))
            #expect(reading.kind == .reanalyse && reading.sourcePath == filed.spelledOnDisk.path,
                    "filed meanwhile, it is read again where it is in the archive: \(reading.kind) \(reading.sourcePath)")
            #expect(try await h.services.documents.document(id: id)?.status == .filed, "found as it is until it is filed again")
            return
        default: break
        }
        let asked = try await h.ingest("bill.txt", text: Self.bill)
        let id = try #require(asked.id)
        if meanwhile == .removed {
            try FileManager.default.removeItem(at: asked.url)
            await #expect(throws: IngestError.cannotReadAgain(id), "one whose file is gone is refused") {
                try await h.services.queueReadingAgain(id, settings: settings)
            }
            #expect(try await h.services.documents.document(id: id)?.status == asked.status, "and stays as it is")
            return
        }
        let tag = try #require(h.services.config.labels.label("Taxes 2024", kind: .tag))
        h.env.time.advance(by: 60)
        switch meanwhile {
        case .tagged: try await h.services.index.addLabels([tag], docID: id)
        default: try await h.services.documents.update(id) { $0.status = .held }
        }
        h.env.time.advance(by: 60)
        let job = try await h.services.queueReadingAgain(id, settings: settings)
        let read = try #require(try await h.services.documents.document(id: id))
        if meanwhile == .tagged {
            let reading = try #require(try await h.services.jobs.job(id: job))
            #expect(reading.tags == [tag], "read with the tag given meanwhile: \(reading.tags)")
            #expect(try reading.payload.rereading?.before.contains(tag) == true, "and kept as one it had when asked")
            #expect(read.labels?.contains(tag) == true, "which it keeps")
        } else {
            #expect(read.status == .processing && read.updatedAt == h.env.time.now(), "left for later meanwhile, it is read again from there")
        }
    }

    /// Read Again on a document left in Incoming whose file, saved again, is being read in, not filed yet, is read with
    /// that reading: it is not refused, and nothing more is queued or recorded.
    @Test func readAgainOnADocumentBeingReadInBeforeItIsFiledIsReadWithThatReading() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let file = try h.env.drop("scan.txt", text: Self.bill)
        let id = try await record(h, at: file.spelledOnDisk.path, status: .failed, sha256: "an earlier version")
        let reading = try #require(await h.coordinator.enqueue(file), "its file saved again is read in as it")
        try await h.review.retry(id)
        let jobs = try await h.jobs()
        #expect(jobs.compactMap(\.id) == [reading], "read with that reading: \(jobs.map(\.kind))")
        #expect(try await h.services.history.events(limit: 10, kinds: [.retry]).isEmpty, "and nothing more is recorded")
    }

    /// Read Again asked twice while the first waits queues one reading and is recorded in History once: asking again
    /// changes nothing, and records nothing.
    @Test func readAgainAskedTwiceIsQueuedAndRecordedOnce() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: Self.bill)
        let id = try #require(doc.id)
        try await h.review.retry(id)
        try await h.review.retry(id)
        let readings = try await h.jobs().filter { $0.kind == .reanalyse }
        #expect(readings.count == 1, "one reading: \(readings.map(\.state))")
        let said = try await h.services.history.events(limit: 10, kinds: [.retry], docID: id)
        #expect(said.map(\.summary) == ["Read again: \(doc.filename)"] && said.first?.actor == .user,
                "recorded once, under the document, as the user's: \(said.map(\.summary))")
    }

    /// Read Again on a document the user confirmed, queueing its reading, takes the confirmation back: the document is
    /// to be looked at again once it is read, and its card no longer says it was confirmed.
    @Test func readAgainTakesBackAConfirmation() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: Self.bill)
        let id = try #require(doc.id)
        try await h.review.confirm(id)
        #expect(try await h.review.choices(for: try #require(try await h.services.documents.document(id: id))).confirmed != nil, "confirmed")
        h.env.time.advance(by: 60)
        try await h.review.retry(id)
        let read = try #require(try await h.services.documents.document(id: id))
        #expect(try await h.review.choices(for: read).confirmed == nil, "and asked to be read again, no longer")
    }

    /// A document asked whose file a path holds, changed by the user before it is ended, as one left in Incoming then
    /// left for later, is left as the user changed it.
    @Test func aDocumentTheUserChangedSinceItWasAskedIsNotEnded() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try await record(h, at: h.env.incoming.appendingPathComponent("scan.txt").spelledOnDisk.path, status: .failed, sha256: "another")
        let asked = try #require(try await h.services.documents.document(id: id))
        try await h.services.documents.update(id) { $0.status = .held }
        try await h.coordinator.replaced(asked)
        #expect(try await h.services.documents.document(id: id)?.status == .held, "left for later, it stays so")
        #expect(try await h.services.history.events(limit: 10, kinds: [.missing]).isEmpty, "and nothing is said to be gone")
    }

    /// A document set aside, ended as another file comes in its place, is ended once, however many requests for its path
    /// come at once: one no longer set aside is left as it is.
    @Test func aDocumentSetAsideIsEndedOnceThoughTwoRequestsEndIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try await record(h, at: h.env.incoming.appendingPathComponent("scan.txt").spelledOnDisk.path, status: .undone, sha256: "another")
        let undone = try #require(try await h.services.documents.document(id: id))
        try await h.coordinator.replaced(undone)
        try await h.coordinator.replaced(undone)
        #expect(try await h.services.documents.document(id: id)?.status == .missing, "it is ended")
        #expect(try await h.services.history.events(limit: 10, kinds: [.missing]).count == 1, "once")
    }
}
