import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

extension Harness {
    /// Every job, however it ended.
    func jobs() async throws -> [JobRecord] {
        try await env.database.reader.read { db in try JobRecord.order(Column("id")).fetchAll(db) }
    }
}

/// Every document is read by the model, labelled and filed at the top of the archive under the name it gave; the
/// archive has no folders of the app's making.
@Suite struct IngestTests {
    @Test func aNewDocumentIsFiledAtTheTopOfTheArchiveUnderTheNameTheModelGave() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let url = try h.env.drop("scan_0042.txt", text: "EDP electricity July")
        await h.coordinator.enqueue(url)
        await h.coordinator.drain()
        let doc = try #require(try await h.services.documents.list(DocumentFilter(), limit: 5).first)
        let filed = h.env.archive.appendingPathComponent(StubAnalyzer.edpFileName + ".txt").standardizedFileURL
        #expect(doc.status == .filed && doc.url.standardizedFileURL == filed, "filed at the top of the archive, named by the model")
        #expect(!FileManager.default.fileExists(atPath: url.path), "Incoming is left empty")
        #expect(Xattr.get(Xattr.documentID, from: filed) == doc.uid, "the file carries its identity, so a move in Finder is followed")
        #expect(doc.labels == StubAnalyzer.edpBill, "the document is described by its labels")
        #expect(doc.analysis == DocumentAnalysis(fileName: StubAnalyzer.edpFileName, model: "stub"), "the name the model gave and the model that gave it are kept with the document")
        let contents = try FileManager.default.contentsOfDirectory(atPath: h.env.archive.path)
        #expect(Set(contents) == [filed.lastPathComponent], "no folder is made for it")
        #expect(try await h.jobs().map(\.state) == [.done], "the job is finished and does not run again")
    }

    @Test func aDocumentTheModelGaveNoNameKeepsItsOwn() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(fileName: nil))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        #expect(doc.filename == "bill.txt" && doc.status == .filed, "the document is still filed, under the name it came with")
    }

    @Test func aDocumentTheModelCouldNotReadWaitsForTheUserInTheArchive() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil, fileName: nil))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        #expect(doc.status == .needsReview && doc.url.deletingLastPathComponent().standardizedFileURL == h.env.archive.standardizedFileURL,
                "it waits for the user as a status, in the archive, not in a folder")
        #expect(doc.analysis?.problems == ["the model gave no valid answer"] && doc.labels == nil, "the user sees why it waits, and no labels are guessed")
        #expect(try await h.services.documents.reviewQueue().map(\.id) == [doc.id], "it is in the review queue")
    }

    @Test func aCopyIsFiledBesideItsOriginalUnreadOrLeftInIncoming() async throws {
        let analyzer = StubAnalyzer()
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: "EDP electricity July")
        let copy = try await h.ingest("bill copy.txt", text: "EDP electricity July")
        #expect(copy.status == .duplicate && copy.duplicateOf == original.id, "the copy points at the document it repeats")
        #expect(copy.url.deletingLastPathComponent().standardizedFileURL == h.env.archive.standardizedFileURL && copy.filename == "bill copy.txt",
                "a copy goes into the archive under its own name")
        #expect(await analyzer.calls.files == ["bill.txt"], "the copy is not read again")

        try await h.env.settings.update { $0.duplicateAction = .leaveInIncoming }
        let another = try await h.ingest("bill again.txt", text: "EDP electricity July")
        #expect(another.status == .duplicate && another.path == h.env.incoming.appendingPathComponent("bill again.txt").path,
                "when the user asks, a copy is left in Incoming untouched")
    }

    @Test func aModelThatCannotBeReachedKeepsTheDocumentWaitingToBeRead() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(error: OllamaError.unreachable("connection refused")))
        defer { h.env.cleanup() }
        let url = try h.env.drop("bill.txt", text: "EDP electricity July")
        await h.coordinator.enqueue(url)
        await h.coordinator.drain()
        let jobs = try await h.jobs()
        #expect(jobs.map(\.state) == [.analysing] && jobs.first?.attempt == 0,
                "the job waits where it stopped, and waiting for Ollama costs no attempt")
        #expect(await h.coordinator.status.waitingForOllama, "the app shows it is waiting for Ollama")
        #expect(FileManager.default.fileExists(atPath: url.path), "nothing is moved meanwhile")
    }

    @Test func aMissingModelHoldsTheDocument() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(error: OllamaError.modelNotFound("ministral-3:14b")))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP electricity July"))
        await h.coordinator.drain()
        #expect(try await h.jobs().map(\.state) == [.held], "held until the model is downloaded")
    }

    @Test func aDocumentThatKeepsFailingIsParkedInTheArchiveAndWaitsForTheUser() async throws {
        let base = try await Harness.make(analyzer: StubAnalyzer(error: IngestError.invalidState("boom")))
        defer { base.env.cleanup() }
        let h = base.with { $0.ingest.retryDelays = NonEmpty(0, []) }
        let (services, coordinator) = (h.services, h.coordinator)
        let url = try base.env.drop("bad.txt", text: "x")
        await coordinator.enqueue(url)
        for _ in 0..<services.config.ingest.maxAttempts { await coordinator.drain() }
        let failed = try #require(try await services.documents.list(DocumentFilter(statuses: [.failed]), limit: 5).first)
        #expect(failed.url.deletingLastPathComponent().standardizedFileURL == base.env.archive.standardizedFileURL
                    && failed.filename == "bad.txt",
                "Incoming stays clean; the file keeps its name at the top of the archive")
        #expect(failed.analysis?.problems == ["Processing failed: boom"], "the user sees what went wrong")
        #expect(!FileManager.default.fileExists(atPath: url.path), "Incoming is left empty")
    }

    @Test func aFailureAfterFilingDoesNotFileTheDocumentAgain() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let h = base.with { $0.ingest.retryDelays = NonEmpty(0, []) }
        let (services, coordinator) = (h.services, h.coordinator)
        let first = try await base.ingest("bill.txt", text: "EDP electricity July")
        // Indexing the second document fails once, after it was moved into the archive and recorded as filed.
        try await base.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER index_fails_once BEFORE INSERT ON embeddings
                WHEN (SELECT attempt FROM jobs WHERE doc_id = NEW.doc_id ORDER BY id DESC LIMIT 1) = 0
                BEGIN SELECT RAISE(ABORT, 'the index is briefly unavailable'); END
                """)
        }
        await coordinator.enqueue(try base.env.drop("bill 2.txt", text: "EDP electricity August"))
        await coordinator.drain()
        let second = try #require(try await services.documents.list(DocumentFilter(), limit: 5).first { $0.id != first.id })
        #expect(second.filename == StubAnalyzer.edpFileName + " (2).txt" && FileManager.default.fileExists(atPath: second.path),
                "the retry finds the document where the first attempt filed it, and does not move it on to a third name")
        let filed = try await services.history.events(limit: 10, kinds: [.filed], docID: second.id)
        #expect(filed.count == 1, "one move, recorded once")
        #expect(try await base.jobs().map(\.state) == [.done, .done], "the retry finishes what the first attempt left undone")
    }

    @Test func aFilePutIntoTheArchiveIsReadWhereItIs() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let reconciler = ArchiveReconciler(services: h.services, coordinator: h.coordinator)
        let loose = try h.env.put("contract.txt", text: "Rental contract")
        let deep = try h.env.put("Old/2024/receipt.txt", text: "A receipt")
        await reconciler.apply([.untrackedFile(path: loose.path), .untrackedFile(path: deep.path)])
        await h.coordinator.drain()
        let docs = try await h.services.documents.list(DocumentFilter(), limit: 5)
        #expect(Set(docs.map(\.path)) == [loose.path, deep.path], "adopted where they are, at any depth, under their own names")
        #expect(docs.allSatisfy { $0.status == .filed && $0.labels == StubAnalyzer.edpBill }, "and read and labelled like any other")
    }

    @Test func aDocumentMovedOrRenamedInFinderIsFollowed() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        let reconciler = ArchiveReconciler(services: h.services, coordinator: h.coordinator)
        let renamed = h.env.archive.appendingPathComponent("EDP July.txt").standardizedFileURL
        try FileManager.default.moveItem(at: doc.url, to: renamed)
        await reconciler.apply([.documentMoved(uid: doc.uid, newPath: renamed.path)])
        #expect(try await h.services.documents.document(id: try #require(doc.id))?.path == renamed.path, "the record follows the file to its new name")
        let events = try await h.services.history.events(limit: 5, kinds: [.userRenamed, .userMoved], docID: doc.id)
        #expect(events.map(\.kind) == [.userRenamed], "a new name in the same place is a rename")
    }

    @Test func aDocumentRemovedFromTheArchiveIsMarkedMissingNeverDeleted() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        let id = try #require(doc.id)
        try FileManager.default.removeItem(at: doc.url)
        await ArchiveReconciler(services: h.services, coordinator: h.coordinator).apply([.documentMissing(path: doc.path)])
        let missing = try #require(try await h.services.documents.document(id: id))
        #expect(missing.status == .missing && missing.labels == doc.labels, "the record stays, with its labels, marked missing")
        #expect(try await h.services.history.events(limit: 5, kinds: [.missing], docID: id).count == 1, "and the removal is in History")
    }

    @Test func undoReturnsTheFileToIncomingAndReadingItAgainFilesItAtTheTop() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        let id = try #require(doc.id)
        try await h.review.undo(id)
        let undone = try #require(try await h.services.documents.document(id: id))
        #expect(undone.status == .undone && undone.path == h.env.incoming.appendingPathComponent("bill.txt").path,
                "undo puts the file back in Incoming under its original name")
        try await h.review.retry(id)
        await h.coordinator.drain()
        let refiled = try #require(try await h.services.documents.document(id: id))
        #expect(refiled.status == .filed && refiled.url.deletingLastPathComponent().standardizedFileURL == h.env.archive.standardizedFileURL,
                "read again, it is filed at the top of the archive")
    }

    @Test func readingADocumentAgainRenamesItWhereItIs() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let reconciler = ArchiveReconciler(services: h.services, coordinator: h.coordinator)
        let deep = try h.env.put("Old/receipt.txt", text: "A receipt")
        await reconciler.apply([.untrackedFile(path: deep.path)])
        await h.coordinator.drain()
        let id = try #require(try await h.services.documents.document(path: deep.path)?.id)
        try await h.review.retry(id)
        await h.coordinator.drain()
        let read = try #require(try await h.services.documents.document(id: id))
        #expect(read.path == h.env.archive.appendingPathComponent("Old/\(StubAnalyzer.edpFileName).txt").standardizedFileURL.path,
                "a document already in the archive is renamed in its own directory, never moved out of it")
    }

    @Test func confirmingADocumentWaitingForTheUserFilesIt() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil, fileName: nil))
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        try await h.review.confirm(id)
        let confirmed = try #require(try await h.services.documents.document(id: id))
        #expect(confirmed.status == .filed && confirmed.analysis?.problems == [], "confirming files it and clears what the model got wrong")
        #expect(try await h.services.history.events(limit: 5, kinds: [.markedCorrect], docID: id).count == 1, "the confirmation is in History")
    }

    @Test func correctingTheNameAndTheLabelsRenamesTheFileAndKeepsOnlyWhatIsALabel() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        let corrected = StubAnalyzer.edpBill.filter { $0.kind != .sender && $0.kind != .type } + [
            DocumentLabel(kind: .sender, value: "  EDP\nEnergia "), DocumentLabel(kind: .type, value: "receipt"),
            DocumentLabel(kind: .type, value: "invoice"), DocumentLabel(kind: .deadline, value: "tomorrow"),
            DocumentLabel(kind: .topic, value: "Electricity"),
        ]
        try await h.review.edit(id, fileName: "2026-07-05 EDP - Julho", labels: corrected)
        let edited = try #require(try await h.services.documents.document(id: id))
        #expect(edited.filename == "2026-07-05 EDP - Julho.txt" && FileManager.default.fileExists(atPath: edited.path),
                "the file on disk takes the corrected name")
        #expect(edited.analysis?.fileName == "2026-07-05 EDP - Julho", "the corrected name replaces the model's")
        #expect(edited.labels(.sender) == ["EDP Energia"], "a label is kept on one line")
        #expect(edited.labels(.type) == ["receipt"], "a document has one type")
        #expect(edited.labels(.deadline) == ["2026-07-25"], "what is no date is no deadline")
        #expect(edited.labels(.topic) == ["electricity"], "the same topic however written is one")
        let search = h.search
        #expect(try await search.fullText(SearchQuery(text: "sender:energia")).hits.map(\.id) == [id], "a corrected label is searchable")
        #expect(try await h.services.history.events(limit: 5, kinds: [.corrected], docID: id).first?.summary == "Corrected fileName, labels",
                "History says what was corrected")
    }
}
