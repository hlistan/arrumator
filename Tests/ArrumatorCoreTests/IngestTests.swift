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

    /// The title the model reads documents as in `readingOtherwise()`, and the name made of it with their sender.
    static let otherTitle = "Contrato"
    static let otherFileName = "MEO - Contrato"

    /// This pipeline as after the user chose another profile: its model reads every document as a contract from MEO
    /// (`LabelingTests.meoContract`), titled `otherTitle`, so named `otherFileName`.
    func readingOtherwise() -> (services: PipelineServices, coordinator: IngestCoordinator, analyzer: StubAnalyzer) {
        let analyzer = StubAnalyzer(labels: LabelingTests.meoContract, title: Self.otherTitle)
        var services = services
        services.analyzer = analyzer
        return (services, IngestCoordinator(services: services), analyzer)
    }
}

/// An extractor that throws each of `failures` in turn, one a call, and then reads files as `PlainTestExtractor` does;
/// it counts its calls.
actor ScriptedExtractor: ContentExtracting {
    private var failures: [any Error & Sendable]
    private(set) var calls = 0

    init(failures: [any Error & Sendable]) { self.failures = failures }

    func extract(_ url: URL, sha256: String, context: ExtractionContext, trace: TraceContext) async throws -> ExtractedContent {
        calls += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        return try await PlainTestExtractor().extract(url, sha256: sha256, context: context, trace: trace)
    }
}

/// A Trash that takes nothing, as that of a volume without one.
struct RefusingTrash: Trashing {
    static let reason = "the volume has no Trash"

    func trash(_ url: URL) throws -> URL? {
        throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: Self.reason])
    }
}

/// Every document is read by the model, labelled and filed at the top of the archive under the name it gave; the
/// archive has no folders of the app's making.
@Suite struct IngestTests {
    static let bill = "EDP electricity July"

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
        let h = try await Harness.make(analyzer: StubAnalyzer(title: nil))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        #expect(doc.filename == "bill.txt" && doc.status == .filed, "the document is still filed, under the name it came with")
    }

    @Test func aDocumentTheModelCouldNotReadWaitsForTheUserInTheArchive() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        #expect(doc.status == .needsReview && doc.url.deletingLastPathComponent().standardizedFileURL == h.env.archive.standardizedFileURL,
                "it waits for the user as a status, in the archive, not in a folder")
        #expect(doc.analysis?.problems == ["the model gave no valid answer"] && doc.labels == nil, "the user sees why it waits, and no labels are guessed")
        #expect(try await h.services.documents.needsYou().waiting.map(\.id) == [doc.id], "it is in the review queue")
    }

    @Test func aCopyOfADocumentInTheArchiveHasItReadAgainFromTheStartAndGoesToTheTrash() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: Self.bill)
        let id = try #require(original.id)
        h.env.time.advance(by: 60)
        let (services, coordinator, analyzer) = h.readingOtherwise()
        let copy = try h.env.drop("bill copy.txt", text: Self.bill)
        await coordinator.enqueue(copy)
        await coordinator.drain()

        let documents = try await services.documents.list(DocumentFilter(), limit: 10)
        #expect(documents.map(\.id) == [id], "the copy becomes no document of its own")
        let read = try #require(documents.first)
        #expect(read.labels == LabelingTests.meoContract && read.status == .filed, "its original is labelled with what the model reads now")
        #expect(read.path == h.env.archive.appendingPathComponent(Harness.otherFileName + ".txt").standardizedFileURL.path,
                "and renamed where it is, under the name the model gives now")
        #expect(await analyzer.calls.files == [original.filename], "the original is what is read, once")
        #expect((read.extractedAt ?? .distantPast) > (original.extractedAt ?? .distantFuture),
                "its text is read from its file again, as a file that arrives is, not taken from before")
        #expect(try await h.search.fullText(SearchQuery(text: "sender:meo")).hits.map(\.id) == [id], "the index has what it reads now")
        #expect(!FileManager.default.fileExists(atPath: copy.path), "the copy leaves Incoming")
        let trashed = h.env.trashed()
        #expect(trashed.map(\.lastPathComponent) == ["bill copy.txt"], "into the Trash, under its own name, never deleted")
        #expect(try trashed.first.map { try String(contentsOf: $0, encoding: .utf8) } == Self.bill, "as it came")

        let event = try #require(try await services.history.events(limit: 5, kinds: [.duplicate], docID: id).first)
        #expect(event.summary == "bill copy.txt is a copy of \(original.filename), which is read again; the copy is in the Trash",
                "History says, under the original, what became of the copy")
        let payload = try #require(JSON.decode(CopyPayload.self, from: event.payloadJson))
        #expect(payload.copy == copy.spelledOnDisk.path && payload.trashed == trashed.first?.spelledOnDisk.path && payload.tags == nil,
                "and where the copy was and went, both as the disk spells them: \(event.payloadJson)")
        #expect(try await h.jobs().map(\.state) == [.done, .duplicate, .done],
                "the copy's job ends as a copy's, and reading its original is a job of its own")
    }

    @Test func aCopyNoLongerTheSameAsItsOriginalOnDiskIsADocumentOfItsOwn() async throws {
        let analyzer = StubAnalyzer()
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        let changed = try await h.ingest("bill.txt", text: Self.bill)
        try Data("EDP electricity July, annotated".utf8).write(to: changed.url)
        let gone = try await h.ingest("receipt.txt", text: "A receipt")
        try FileManager.default.removeItem(at: gone.url)

        let first = try await h.ingest("bill copy.txt", text: Self.bill)
        let second = try await h.ingest("receipt copy.txt", text: "A receipt")
        #expect(first.id != changed.id && second.id != gone.id && [first.status, second.status] == [.filed, .filed],
                "a file the archive no longer holds the same bytes of, changed or gone, is filed as a new document")
        #expect(await analyzer.calls.files == ["bill.txt", "receipt.txt", "bill copy.txt", "receipt copy.txt"], "each read as itself")
        #expect(h.env.trashed().isEmpty, "and nothing goes to the Trash")
    }

    @Test func aCopyPutIntoTheArchiveIsADocumentOfItsOwnAndNothingGoesToTheTrash() async throws {
        let analyzer = StubAnalyzer()
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: Self.bill)
        let put = try h.env.put("Old/bill copy.txt", text: Self.bill)
        try await ArchiveReconciler(services: h.services, coordinator: h.coordinator).apply([.found(path: put.path)])
        await h.coordinator.drain()
        let adopted = try #require(try await h.services.documents.document(path: put.path))
        #expect(adopted.id != original.id && adopted.status == .filed && FileManager.default.fileExists(atPath: put.path),
                "a file the user put into the archive is theirs: read where it is, never taken for a copy")
        #expect(await analyzer.calls.files == ["bill.txt", "bill copy.txt"] && h.env.trashed().isEmpty,
                "its original is not read again, and nothing of the archive goes to the Trash")
    }

    @Test func aCopyTheTrashRefusesStaysInIncomingOnceSaidAndItsOriginalIsNotReadAgain() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        var services = base.with { $0.ingest.retryDelays = NonEmpty(0, []) }.services
        let analyzer = StubAnalyzer()
        services.analyzer = analyzer
        services.trash = RefusingTrash()
        let coordinator = IngestCoordinator(services: services)
        let copy = try base.env.drop("bill copy.txt", text: Self.bill)
        for arrival in ["arrives", "is found again by a rescan"] {
            await coordinator.enqueue(copy)
            for _ in 0..<services.config.ingest.maxAttempts { await coordinator.drain() }

            #expect(FileManager.default.fileExists(atPath: copy.path), "when it \(arrival), the copy stays where it was: nothing is lost")
            #expect(await analyzer.calls.files.isEmpty, "when it \(arrival), its original is not read again while the copy cannot go")
            let jobs = try await base.jobs()
            #expect(jobs.count == 2 && jobs.last?.state == .failed && jobs.last?.attempt == 0,
                    "when it \(arrival), the copy's job ends at once, as a Trash that refuses will refuse again")
            let failed = try await services.history.events(limit: 5, kinds: [.failed]).map(\.summary)
            let why = IngestError.notTrashed(copy.spelledOnDisk.path, reason: RefusingTrash.reason).localizedDescription
            #expect(failed == ["bill copy.txt stays in Incoming: \(why)"], "when it \(arrival), History says why, once: \(failed)")
            let left = try #require(try await services.documents.list(DocumentFilter(), limit: 5).first { $0.id != original.id })
            #expect(left.status == .failed && left.path == copy.spelledOnDisk.path && left.status.waitsForUser,
                    "when it \(arrival), it waits for the user in Needs You, left where it is, which a rescan leaves alone")
        }
    }

    @Test func aStopAfterTheCopyWentToTheTrashStillHasItsOriginalReadAgain() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        let id = try #require(original.id)
        var services = base.with { $0.ingest.retryDelays = NonEmpty(0, []) }.services
        let analyzer = StubAnalyzer()
        services.analyzer = analyzer
        let coordinator = IngestCoordinator(services: services)
        // Queueing the original to be read again fails once, after the copy went to the Trash.
        try await base.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER queueing_fails_once BEFORE INSERT ON jobs
                WHEN NEW.kind = '\(JobKind.reanalyse.rawValue)' AND (SELECT COUNT(*) FROM events WHERE kind = '\(EventKind.retry.rawValue)') = 0
                BEGIN SELECT RAISE(ABORT, 'the queue is briefly unavailable'); END
                """)
        }
        await coordinator.enqueue(try base.env.drop("bill copy.txt", text: Self.bill))
        await coordinator.drain()

        #expect(base.env.trashed().map(\.lastPathComponent) == ["bill copy.txt"], "the copy went to the Trash before the stop")
        #expect(await analyzer.calls.files == [original.filename], "its original is still read again, once")
        let events = try await services.history.events(limit: 20, kinds: [.duplicate, .missing])
        #expect(events.map(\.kind) == [.duplicate] && events.first?.docId == id,
                "the copy is recorded once, under its original, and never as a file that disappeared: \(events.map(\.summary))")
        #expect(events.first?.summary == "bill copy.txt is a copy of \(original.filename), which is read again",
                "where the Trash put it is not known after the stop, so History does not say")
        #expect(try await base.jobs().map(\.state) == [.done, .duplicate, .done], "the copy's job finishes what the stop left")
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

    @Test func aFileWhoseExtractionWaitsForOllamaIsExtractedAgainWithoutSpendingAnAttempt() async throws {
        let extractor = ScriptedExtractor(failures: [OllamaError.unreachable("connection refused")])
        let h = try await Harness.make(extractor: extractor)
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("scan.txt", text: Self.bill))
        await h.coordinator.drain()
        let waiting = try await h.jobs()
        #expect(waiting.map(\.state) == [.extracting] && waiting.first?.attempt == 0,
                "an image Ollama was away to describe waits where it stopped, and waiting costs no attempt")
        #expect(await h.coordinator.status.waitingForOllama, "the app shows it is waiting for Ollama")

        h.env.time.advance(by: h.env.config.ingest.retryDelays.last)
        await h.coordinator.drain()
        #expect(try await h.jobs().map(\.state) == [.done], "once Ollama is back the file is extracted again, and filed")
        #expect(await extractor.calls == 2, "it was extracted again from the start, not filed with what it had")
    }

    @Test("A server that answers each time with a failure for one file spends its attempts; one away spends none",
          arguments: [OllamaError.http(status: 500, body: "llama runner process has terminated"), .emptyResponse])
    func aFailureTheServerRepeatsEndsTheJob(answered: OllamaError) async throws {
        let failing = ScriptedExtractor(failures: Array(repeating: answered, count: 10))
        let base = try await Harness.make(extractor: failing)
        defer { base.env.cleanup() }
        let h = base.with { $0.ingest.retryDelays = NonEmpty(0, []) }
        await h.coordinator.enqueue(try base.env.drop("scan.txt", text: Self.bill))
        for _ in 0..<h.services.config.ingest.maxAttempts { await h.coordinator.drain() }
        #expect(try await base.jobs().map(\.state) == [.failed],
                "\(answered.localizedDescription): a failure the server answers with again and again ends the job, not every 30 s for ever")
        #expect(await failing.calls == h.services.config.ingest.maxAttempts, "after its attempts, each of which it spent")
        #expect(await !h.coordinator.status.waitingForOllama, "Ollama answered, so nothing waits for it")

        let away = ScriptedExtractor(failures: Array(repeating: OllamaError.unreachable("connection refused"), count: 10))
        let waits = try await Harness.make(extractor: away)
        defer { waits.env.cleanup() }
        await waits.coordinator.enqueue(try waits.env.drop("scan.txt", text: Self.bill))
        for _ in 0..<(waits.services.config.ingest.maxAttempts + 2) {
            await waits.coordinator.drain()
            waits.env.time.advance(by: waits.services.config.ingest.retryDelays.last)
        }
        let jobs = try await waits.jobs()
        #expect(jobs.map(\.state) == [.extracting] && jobs.first?.attempt == 0, "Ollama away, however often, spends no attempt")
        #expect(await away.calls == waits.services.config.ingest.maxAttempts + 2, "and the file is tried again each time it is due")
    }

    @Test func aTimeoutWaitsOnlyWhileOllamaAnswersNothingElseEither() async throws {
        let timedOut = OllamaError.timeout("chat")
        let answering = ScriptedExtractor(failures: Array(repeating: timedOut, count: 10))
        let base = try await Harness.make(extractor: answering)
        defer { base.env.cleanup() }
        let h = base.with { $0.ingest.retryDelays = NonEmpty(0, []) }
        await h.coordinator.enqueue(try base.env.drop("scan.txt", text: Self.bill))
        for _ in 0..<h.services.config.ingest.maxAttempts { await h.coordinator.drain() }
        #expect(try await base.jobs().map(\.state) == [.failed],
                "a read that times out each time while Ollama answers its version ends after its attempts, not every 30 s for ever")

        let silent = MockOllama { _ in "" }
        await silent.failVersion(with: .unreachable("connection refused"))
        let away = ScriptedExtractor(failures: Array(repeating: timedOut, count: 10))
        let waits = try await Harness.make(extractor: away, ollama: silent)
        defer { waits.env.cleanup() }
        await waits.coordinator.enqueue(try waits.env.drop("scan.txt", text: Self.bill))
        for _ in 0..<(waits.services.config.ingest.maxAttempts + 2) {
            await waits.coordinator.drain()
            waits.env.time.advance(by: waits.services.config.ingest.retryDelays.last)
        }
        let jobs = try await waits.jobs()
        #expect(jobs.map(\.state) == [.extracting] && jobs.first?.attempt == 0, "a timeout while Ollama answers nothing is Ollama away")
        #expect(await waits.coordinator.status.waitingForOllama, "and the app shows it is waiting for Ollama")
    }

    @Test func aDocumentThatKeepsFailingIsParkedInTheArchiveAndWaitsForTheUser() async throws {
        let base = try await Harness.make(analyzer: StubAnalyzer(error: TestFailure("boom")))
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
        try await reconciler.apply([.found(path: loose.path), .found(path: deep.path)])
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
        try await reconciler.apply([.found(path: renamed.path), .gone(path: doc.path)])
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
        try await ArchiveReconciler(services: h.services, coordinator: h.coordinator).apply([.gone(path: doc.path)])
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
        #expect(undone.status == .undone && undone.path == h.env.incoming.appendingPathComponent("bill.txt").spelledOnDisk.path,
                "undo puts the file back in Incoming under its original name, at its path as the disk spells it, as a rescan names it")
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
        try await reconciler.apply([.found(path: deep.path)])
        await h.coordinator.drain()
        let id = try #require(try await h.services.documents.document(path: deep.path)?.id)
        try await h.review.retry(id)
        await h.coordinator.drain()
        let read = try #require(try await h.services.documents.document(id: id))
        #expect(read.path == h.env.archive.appendingPathComponent("Old/\(StubAnalyzer.edpFileName).txt").standardizedFileURL.path,
                "a document already in the archive is renamed in its own directory, never moved out of it")
    }

    @Test func confirmingADocumentWaitingForTheUserFilesIt() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        try await h.review.confirm(id)
        let confirmed = try #require(try await h.services.documents.document(id: id))
        #expect(confirmed.status == .filed && confirmed.analysis?.problems == [], "confirming files it and clears what the model got wrong")
        #expect(try await h.services.history.events(limit: 5, kinds: [.markedCorrect], docID: id).count == 1, "the confirmation is in History")
    }

    @Test func correctingTheNameAndTheLabelsRenamesTheFileAndKeepsEachLabelAsItsKindKeepsIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        let corrected = LabelEdit(adding: [
            DocumentLabel(kind: .sender, value: "  EDP\nEnergia "), DocumentLabel(kind: .type, value: "receipt"),
            DocumentLabel(kind: .type, value: "invoice"), DocumentLabel(kind: .topic, value: "Electricity"),
        ], removing: StubAnalyzer.edpBill.filter { $0.kind == .sender })
        try await h.review.edit(id, fileName: "2026-07-05 EDP - Julho", labels: corrected)
        await #expect(throws: LabelError.notALabel(.deadline, "tomorrow"), "what is no date is no deadline, and is refused, not dropped") {
            try await h.review.edit(id, fileName: "Never Renamed", labels: LabelEdit(adding: [DocumentLabel(kind: .deadline, value: "tomorrow")]))
        }
        let edited = try #require(try await h.services.documents.document(id: id))
        #expect(edited.filename == "2026-07-05 EDP - Julho.txt" && FileManager.default.fileExists(atPath: edited.path),
                "the file on disk takes the corrected name")
        #expect(edited.analysis?.fileName == "2026-07-05 EDP - Julho", "the corrected name replaces the model's")
        #expect(edited.labels(.sender) == ["EDP Energia"], "a label is kept on one line")
        #expect(edited.labels(.type) == ["receipt"], "a document has one type")
        #expect(edited.labels(.deadline) == ["2026-07-25"], "and a correction refused changes nothing: the deadline it had stays")
        #expect(edited.labels(.topic) == ["electricity"], "the same topic however written is one")
        let search = h.search
        #expect(try await search.fullText(SearchQuery(text: "sender:energia")).hits.map(\.id) == [id], "a corrected label is searchable")
        let summary = try await h.services.history.events(limit: 5, kinds: [.corrected], docID: id).first?.summary ?? ""
        #expect(summary.hasPrefix("Renamed to “2026-07-05 EDP - Julho.txt”; added ") && summary.contains("sender “EDP Energia”")
                    && summary.contains("type “receipt”") && summary.contains("; removed ") && summary.contains("type “invoice”"),
                "History says in words what was corrected: the new name, the labels added and those removed: \(summary)")
    }

    @Test func historySaysInWordsWhatTextWasReadAndNoLanguageGuess() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        let extracted = try await h.services.history.events(limit: 5, kinds: [.extracted], docID: id).first?.summary
        #expect(extracted == "Read 20 characters of text from a text document",
                "what was read, in words, not the extractor's name; the language is the model's label to give: \(extracted ?? "")")
    }

    @Test func aBlankNameIsRefusedSayingSoAndNothingChanges() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let filed = try await h.ingest("bill.txt", text: "EDP electricity July")
        let id = try #require(filed.id)
        for blank in ["", "   ", "\n\t", " ... ", "/"] {
            await #expect(throws: IngestError.unusableFileName(blank), "a name cleaning leaves nothing of is no name: “\(blank)”") {
                try await h.review.edit(id, fileName: blank, labels: nil)
            }
        }
        await #expect(throws: IngestError.unusableFileName("~$Bill"), "nor is one the app keeps for files it never takes in") {
            try await h.review.edit(id, fileName: "~$Bill", labels: nil)
        }
        #expect(IngestError.unusableFileName("  ").errorDescription == "A document needs a name; it cannot be blank",
                "a blank name is refused in those words")
        let after = try #require(try await h.services.documents.document(id: id))
        #expect(after.filename == filed.filename && FileManager.default.fileExists(atPath: after.path), "the file keeps its name")
        #expect(try await h.services.history.events(limit: 5, kinds: [.corrected], docID: id).isEmpty, "and nothing is recorded")
    }
}
