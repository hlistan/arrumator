import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// What the ingest queue keeps of a document and of its job, and how a file is known again: a file left in Incoming
/// by the user's choice is that file while it is, a job keeps only what it still needs, and a document's row is changed
/// column by column.
@Suite struct IngestKeepingTests {
    static let bill = IngestTests.bill

    @Test func anUndoneOrHeldFileIsLeftInIncomingByARescanAndAnotherPutInItsPlaceIsFiled() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let undone = try await h.ingest("Scan.txt", text: Self.bill)
        let id = try #require(undone.id)
        try await h.review.undo(id)
        let inIncoming = try #require(try await h.services.documents.document(id: id)).url
        for status in ["undone", "left for later"] {
            if status == "left for later" { try await h.review.hold(id) }
            await h.coordinator.enqueue(inIncoming)
            #expect(try await h.services.jobs.active().isEmpty, "a rescan leaves the \(status) file where it is, unqueued")
        }

        // The user puts the file in the Trash, and the scanner saves another under the same name.
        try FileManager.default.removeItem(at: inIncoming)
        try Data("MEO contract".utf8).write(to: inIncoming)
        await h.coordinator.enqueue(inIncoming)
        await h.coordinator.drain()
        let documents = try await h.services.documents.list(DocumentFilter(), limit: 5)
        let new = try #require(documents.first { $0.id != id })
        #expect(new.status == .filed && new.originalFilename == "Scan.txt", "the file in its place is taken, and filed as a document of its own")
        let gone = try #require(try await h.services.documents.document(id: id))
        #expect(gone.status == .missing, "and the one left for later, whose file is gone, is missing, no longer waiting in Needs You")
        let said = try await h.services.history.events(limit: 5, kinds: [.missing], docID: id).map(\.summary)
        #expect(said == ["Scan.txt is no longer in Incoming; the file there now is another"], "History says so: \(said)")
    }

    @Test func aFileInTheArchiveQueuedAsAnArrivalInAnotherCaseIsNoCopyOfItself() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let filed = try await h.ingest("bill.txt", text: Self.bill)
        let otherCase = filed.url.deletingLastPathComponent().appendingPathComponent(filed.filename.uppercased())
        try await h.services.jobs.enqueue(path: otherCase.path, kind: .ingest)
        await h.coordinator.drain()
        #expect(FileManager.default.fileExists(atPath: filed.path) && h.env.trashed().isEmpty,
                "the archive's file, named in another case, is the same file, never put in the Trash as a copy of itself")
    }

    @Test func aJobThatHasEndedKeepsNeitherTheTextNorTheEmbeddingOfItsDocument() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let filed = try await h.ingest("Taxes 2024/bill.txt", text: Self.bill)
        let job = try #require(try await h.jobs().first)
        let payload = try job.payload
        #expect(payload.content == nil && payload.outcome?.embedding == nil && !job.payloadJson.contains(Self.bill),
                "the document's text and embedding are the document's row's and the index's to keep, not the ended job's")
        #expect(payload.targetPath == filed.path && payload.tags?.map(\.label.value) == ["Taxes 2024"] && payload.outcome?.analysis != nil,
                "while what it did is kept with it")
    }

    /// A payload that cannot be read: JSON that is no payload, or no JSON at all.
    @Test(arguments: ["{\"tags\":7}", "not JSON"])
    func aJobWhosePayloadCannotBeReadFailsSayingWhyAndTheFileIsQueuedAfreshByARescan(_ garbled: String) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let url = try h.env.drop("bill.txt", text: Self.bill)
        let id = try #require(await h.coordinator.enqueue(url, tags: ["Taxes"]))
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET payload_json = ? WHERE id = ?", arguments: [garbled, id])
        }
        await h.coordinator.drain()
        let failed = try #require(try await h.services.jobs.job(id: id))
        #expect(failed.state == .failed && failed.lastError?.hasPrefix("What job \(id) was queued with cannot be read") == true,
                "the job fails, saying why, rather than going on as if it had been queued with nothing: \(failed.lastError ?? "")")
        #expect(failed.payloadJson == garbled && FileManager.default.fileExists(atPath: url.path),
                "its payload is kept as it is, and nothing is filed")
        let said = try await h.services.history.events(limit: 5, kinds: [.failed]).map(\.summary)
        #expect(said == [failed.lastError], "History says why: \(said)")
        let again = try #require(await h.coordinator.enqueue(url))
        #expect(again != id, "a rescan queues the file afresh")
    }

    @Test func whatTheUserDoesWithADocumentWritesOnlyWhatItChangesOfItsRow() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: Self.bill).id)
        // The labels are another's to change meanwhile, as the worker's reading or a correction in another window: a
        // change that does not change them must not write them back as it read them.
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER labels_are_not_ours BEFORE UPDATE OF labels_json ON documents
                BEGIN SELECT RAISE(ABORT, 'the labels were written back as they were read'); END
                """)
        }
        try await h.review.confirm(id)
        try await h.review.hold(id)
        try await h.review.undo(id)
        let undone = try #require(try await h.services.documents.document(id: id))
        #expect(undone.status == .undone && FileManager.default.fileExists(atPath: undone.path),
                "confirming, leaving for later and undoing each wrote the columns it changed, and only those")
    }

    @Test func aSenderCorrectedWhileTheModelReadsAgainIsKeptAndTheReadingFillsInTheRest() async throws {
        let holding = Holding()
        let h = try await Harness.make(analyzer: StubAnalyzer(during: { try await holding.read($0) }))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: Self.bill)
        let id = try #require(doc.id)
        let had = (doc.labels ?? []).filter { $0.kind == .sender }
        await holding.hold(doc.filename)
        try await h.services.queueReadingAgain(try #require(doc.id), settings: await h.services.settings.current)
        let worker = Task { await h.coordinator.drain() }
        #expect(await Patience.until { await holding.held == doc.filename }, "the model reads the document again")
        let mine = DocumentLabel(kind: .sender, value: "Mine Lda")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [mine], removing: had))
        await holding.letGo()
        _ = await worker.value
        let after = try #require(try await h.services.documents.document(id: id))
        #expect(after.labels(.sender) == ["Mine Lda"], "the sender corrected while the model read stays as the user left it: \(after.labels ?? [])")
        #expect(after.labels(.type) == doc.labels(.type) && !after.labels(.type).isEmpty, "and the reading fills in what the user did not touch")
    }

    @Test func aTagGivenOrTakenAwayWhileTheModelReadsAgainIsKeptSo() async throws {
        let holding = Holding()
        let h = try await Harness.make(analyzer: StubAnalyzer(during: { try await holding.read($0) }))
        defer { h.env.cleanup() }
        let filed = try await h.ingest("bill.txt", text: Self.bill)
        let id = try #require(filed.id)
        let (old, tag) = (DocumentLabel(kind: .tag, value: "Old"), DocumentLabel(kind: .tag, value: "Taxes"))
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [old]))
        let doc = try #require(try await h.services.documents.document(id: id))
        await holding.hold(doc.filename)
        try await h.services.queueReadingAgain(try #require(doc.id), settings: await h.services.settings.current)
        let worker = Task { await h.coordinator.drain() }
        #expect(await Patience.until { await holding.held == doc.filename }, "the model reads the document again")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [tag], removing: [old]))
        await holding.letGo()
        _ = await worker.value
        let after = try #require(try await h.services.documents.document(id: id))
        #expect(after.labels?.contains(tag) == true && after.labels?.contains(old) == false
                    && after.labels?.contains(where: { $0.kind == .sender }) == true,
                "the user's change made while the model read is kept, beside what it read: \(after.labels ?? [])")
    }

    @Test func hashingAFileStopsWhenItsTaskIsCancelled() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let url = try h.env.drop("bill.txt", text: Self.bill)
        let hashing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HashService.sha256Concurrently(of: url)
        }
        await #expect(throws: CancellationError.self, "a stop is never held up by reading a large file to its end") {
            try await hashing.value
        }
    }
}
