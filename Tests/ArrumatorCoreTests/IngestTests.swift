import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

struct Harness {
    let env: TestEnvironment
    let services: PipelineServices
    let coordinator: IngestCoordinator

    static func make(analyzer: any DocumentAnalyzing = StubAnalyzer()) async throws -> Harness {
        let env = try await TestEnvironment.make()
        let placer = Placer(builder: FilenameBuilder(config: env.config.naming), operations: FileOperations(naming: env.config.naming))
        let services = PipelineServices(
            database: env.database, config: env.config, settings: env.settings, extractor: PlainTestExtractor(), analyzer: analyzer,
            filer: DocumentFiler(database: env.database, placer: placer, index: IndexStore(database: env.database),
                                 registry: SelfChangeRegistry(ttl: env.config.watcher.selfChangeTTLSeconds)),
            traces: TraceRecorder(database: env.database, appVersion: "test"), vectors: VectorIndex())
        return Harness(env: env, services: services, coordinator: IngestCoordinator(services: services))
    }

    var review: ReviewActions { ReviewActions(services: services, coordinator: coordinator) }

    /// Drops `name` into Incoming and runs the pipeline over it.
    @discardableResult
    func ingest(_ name: String, text: String) async throws -> DocumentRecord {
        let url = try env.drop(name, text: text)
        await coordinator.enqueue(url)
        await coordinator.drain()
        return try #require(try await services.documents.list(DocumentFilter(), limit: 50).first { $0.originalFilename == name })
    }

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
        #expect(doc.analysis == DocumentAnalysis(fileName: StubAnalyzer.edpFileName, model: "stub"))
        let contents = try FileManager.default.contentsOfDirectory(atPath: h.env.archive.path)
        #expect(Set(contents) == [filed.lastPathComponent], "no folder is made for it")
        #expect(try await h.jobs().map(\.state) == [.done])
    }

    @Test func aDocumentTheModelGaveNoNameKeepsItsOwn() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(fileName: nil))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        #expect(doc.filename == "bill.txt" && doc.status == .filed)
    }

    @Test func aDocumentTheModelCouldNotReadWaitsForTheUserInTheArchive() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil, fileName: nil))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        #expect(doc.status == .needsReview && doc.url.deletingLastPathComponent().standardizedFileURL == h.env.archive.standardizedFileURL,
                "it waits for the user as a status, in the archive, not in a folder")
        #expect(doc.analysis?.problems == ["the model gave no valid answer"] && doc.labels == nil)
        #expect(try await h.services.documents.reviewQueue().map(\.id) == [doc.id])
    }

    @Test func aCopyIsFiledBesideItsOriginalUnreadOrLeftInIncoming() async throws {
        let analyzer = StubAnalyzer()
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: "EDP electricity July")
        let copy = try await h.ingest("bill copy.txt", text: "EDP electricity July")
        #expect(copy.status == .duplicate && copy.duplicateOf == original.id)
        #expect(copy.url.deletingLastPathComponent().standardizedFileURL == h.env.archive.standardizedFileURL && copy.filename == "bill copy.txt",
                "a copy goes into the archive under its own name")
        #expect(await analyzer.calls.files == ["bill.txt"], "the copy is not read again")

        try await h.env.settings.update { $0.duplicateAction = .leaveInIncoming }
        let another = try await h.ingest("bill again.txt", text: "EDP electricity July")
        #expect(another.status == .duplicate && another.path == h.env.incoming.appendingPathComponent("bill again.txt").path)
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
        #expect(await h.coordinator.status.waitingForOllama)
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
        var services = base.services
        services.config.ingest.retryDelays = [0, 0, 0]
        let coordinator = IngestCoordinator(services: services)
        let url = try base.env.drop("bad.txt", text: "x")
        await coordinator.enqueue(url)
        for _ in 0..<services.config.ingest.maxAttempts { await coordinator.drain() }
        let failed = try #require(try await services.documents.list(DocumentFilter(statuses: [.failed]), limit: 5).first)
        #expect(failed.url.deletingLastPathComponent().standardizedFileURL == base.env.archive.standardizedFileURL
                    && failed.filename == "bad.txt",
                "Incoming stays clean; the file keeps its name at the top of the archive")
        #expect(failed.analysis?.problems.first?.contains("boom") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
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
        #expect(try await h.services.documents.document(id: try #require(doc.id))?.path == renamed.path)
        let events = try await h.services.history.events(limit: 5, kinds: [.userRenamed, .userMoved], docID: doc.id)
        #expect(events.map(\.kind) == [.userRenamed], "a new name in the same place is a rename")
    }

    @Test func undoReturnsTheFileToIncomingAndReadingItAgainFilesItAtTheTop() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        let id = try #require(doc.id)
        try await h.review.undo(id)
        let undone = try #require(try await h.services.documents.document(id: id))
        #expect(undone.status == .undone && undone.path == h.env.incoming.appendingPathComponent("bill.txt").path)
        try await h.review.retry(id)
        await h.coordinator.drain()
        let refiled = try #require(try await h.services.documents.document(id: id))
        #expect(refiled.status == .filed && refiled.url.deletingLastPathComponent().standardizedFileURL == h.env.archive.standardizedFileURL)
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
        #expect(confirmed.status == .filed && confirmed.analysis?.problems == [])
        #expect(try await h.services.history.events(limit: 5, kinds: [.markedCorrect], docID: id).count == 1)
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
        #expect(edited.filename == "2026-07-05 EDP - Julho.txt" && FileManager.default.fileExists(atPath: edited.path))
        #expect(edited.analysis?.fileName == "2026-07-05 EDP - Julho")
        #expect(edited.labels(.sender) == ["EDP Energia"], "a label is kept on one line")
        #expect(edited.labels(.type) == ["receipt"], "a document has one type")
        #expect(edited.labels(.deadline) == ["2026-07-25"], "what is no date is no deadline")
        #expect(edited.labels(.topic) == ["electricity"], "the same topic however written is one")
        let search = SearchService(database: h.env.database, vectors: VectorIndex(), embedder: nil, config: h.env.config.search)
        #expect(try await search.fullText(SearchQuery(text: "sender:energia")).hits.map(\.id) == [id], "a corrected label is searchable")
        #expect(try await h.services.history.events(limit: 5, kinds: [.corrected], docID: id).first?.summary == "Corrected fileName, labels")
    }
}
