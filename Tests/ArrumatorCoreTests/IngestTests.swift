import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// Classifier stub: files into an existing code, or proposes `newFolder`, with a fixed band and model file name.
struct StubClassifier: DocumentClassifier {
    var code: String?
    var newFolder: FolderSpec?
    var band: Band
    var fileName: String? = "2026-07-05 EDP - Fatura eletricidade julho"
    var error: (any Error & Sendable)?

    func classify(_ content: ExtractedContent, taxonomy: TaxonomySnapshot, settings: AppSettings, config: PipelineConfig,
                  mode: ClassificationMode, trace: TraceContext) async throws -> ClassificationOutcome {
        if let error { throw error }
        let final = band == .auto ? 0.95 : (band == .check ? 0.7 : 0.2)
        return ClassificationOutcome(decision: FilingDecision(
            folderCode: code, proposedNewFolder: code == nil ? newFolder : nil, correspondent: "EDP", documentType: .invoice,
            documentDate: "2026-07-05", dateSource: .label, title: "Fatura eletricidade julho", fileName: fileName, language: "pt",
            confidence: ConfidenceReport(llm: final, final: final, band: band, thresholds: settings.thresholds),
            decidedBy: .llm, rationale: "stub"), embedding: [1, 0, 0], embeddingModel: "stub-embed")
    }

    func embedding(for content: ExtractedContent, sender: String?, settings: AppSettings, config: PipelineConfig,
                   trace: TraceContext) async throws -> (vector: [Float], model: String)? {
        ([1, 0, 0], "stub-embed")
    }

    static let utilities = FolderSpec(parentCode: nil, levels: [FolderLevel(name: "Home", description: "Home documents."),
                                                                FolderLevel(name: "Utilities", description: "Electricity, gas and water bills.")],
                                      yearSubfolders: true, yearRule: .documentDate)
}

actor RecordingLearner: LearningSink {
    var filed: [Int64] = []
    var corrections: [CorrectionEvent] = []
    var forgotten: [Int64] = []
    var reembedded: [Int64] = []
    func documentFiled(documentID: Int64, folderID: Int64, outcome: ClassificationOutcome, content: ExtractedContent,
                       confirmedByUser: Bool, trace: TraceContext) async { filed.append(documentID) }
    func correctionRecorded(_ correction: CorrectionEvent, trace: TraceContext) async { corrections.append(correction) }
    func documentForgotten(documentID: Int64) async { forgotten.append(documentID) }
    func taxonomyChanged(_ changes: [TaxonomyChange], taxonomy: TaxonomySnapshot) async {}
    func documentReembedded(documentID: Int64, vector: [Float], model: String) async { reembedded.append(documentID) }
    var rearranged: [PlacementMove] = []
    var removedFolders: Set<Int64> = []
    func placementsRearranged(_ moves: [PlacementMove], removedFolderIDs: Set<Int64>) async {
        rearranged += moves
        removedFolders.formUnion(removedFolderIDs)
    }
}

struct Harness {
    let env: TestEnvironment
    let services: PipelineServices
    let coordinator: IngestCoordinator
    let learner: RecordingLearner

    static func make(classifier: any DocumentClassifier) async throws -> Harness {
        try await make { _ in classifier }
    }

    /// For a classifier that needs the environment, such as its folder tree.
    static func make(classifier make: (TestEnvironment) -> any DocumentClassifier) async throws -> Harness {
        let env = try await TestEnvironment.make()
        let classifier = make(env)
        let placer = Placer(builder: FilenameBuilder(config: env.config.naming), operations: FileOperations(naming: env.config.naming))
        let learner = RecordingLearner()
        let registry = SelfChangeRegistry(ttl: env.config.watcher.selfChangeTTLSeconds)
        let services = PipelineServices(
            database: env.database, config: env.config, settings: env.settings, taxonomy: env.taxonomy,
            extractor: PlainTestExtractor(), classifier: classifier, learner: learner,
            filer: DocumentFiler(database: env.database, placer: placer, index: IndexStore(database: env.database), registry: registry),
            traces: TraceRecorder(database: env.database, appVersion: "test"), vectors: VectorIndex())
        return Harness(env: env, services: services, coordinator: IngestCoordinator(services: services), learner: learner)
    }

    func folderURL(_ code: String) async throws -> URL {
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        let folder = try #require(snapshot.folder(code: code))
        return snapshot.url(for: folder)
    }
}

/// Answers with the "Utilities" folder while that folder is removed before the answer arrives, as when the user undoes
/// the last other document in it meanwhile. Asked again, it proposes the folder anew, as the tree no longer has it.
struct VanishingFolderClassifier: DocumentClassifier {
    actor Calls {
        var count = 0
        func next() { count += 1 }
    }

    let store: TaxonomyStore
    let root: URL
    let calls = Calls()

    func classify(_ content: ExtractedContent, taxonomy: TaxonomySnapshot, settings: AppSettings, config: PipelineConfig,
                  mode: ClassificationMode, trace: TraceContext) async throws -> ClassificationOutcome {
        await calls.next()
        if let folder = taxonomy.fileable.first(where: { $0.name == "Utilities" }) {
            _ = try await store.pruneEmpty(root: root, folderIDs: [folder.id])
            return try await StubClassifier(code: folder.code, band: .auto)
                .classify(content, taxonomy: taxonomy, settings: settings, config: config, mode: mode, trace: trace)
        }
        return try await StubClassifier(newFolder: StubClassifier.utilities, band: .auto)
            .classify(content, taxonomy: taxonomy, settings: settings, config: config, mode: mode, trace: trace)
    }

    func embedding(for content: ExtractedContent, sender: String?, settings: AppSettings, config: PipelineConfig,
                   trace: TraceContext) async throws -> (vector: [Float], model: String)? { nil }
}

@Suite struct IngestTests {
    @Test func aDecisionForAFolderRemovedMeanwhileIsMadeAgainAndCreatesTheFolder() async throws {
        let h = try await Harness.make { env in VanishingFolderClassifier(store: env.taxonomy, root: env.archive) }
        defer { h.env.cleanup() }
        let removed = try await h.env.folder("Utilities", area: "Home")
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP bill"))
        await h.coordinator.drain()

        let filed = try #require(try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 5).first)
        let snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let folder = try #require(filed.folderId.flatMap(snapshot.folder(id:)))
        #expect(folder.name == "Utilities" && folder.id != removed.id, "the folder the document needs is created afresh")
        let events = try await h.services.history.events(limit: 30)
        #expect(events.contains { $0.kind == .retry && $0.summary.contains("was removed while this was being decided") })
        #expect(!events.contains { $0.kind == .failed })
        let classifier = try #require(h.services.classifier as? VanishingFolderClassifier)
        #expect(await classifier.calls.count == 2, "decided once more, against the tree as it is now")
    }

    @Test func filedDocumentsArePlacedByTheirFolderAndYear() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("a.txt", text: "EDP bill"))
        await h.coordinator.drain()
        let filed = try #require(try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 1).first)
        let snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let utilities = try #require(snapshot.fileable.first { $0.name == "Utilities" })
        #expect(snapshot.place(of: filed, incoming: h.env.incoming) == .folder(utilities, year: "2026"))
        var unknownFolder = filed
        unknownFolder.folderId = -1
        #expect(snapshot.place(of: unknownFolder, incoming: h.env.incoming) == .folder(utilities, year: "2026"),
                "a folder known only by where the file is")
    }

    @Test func documentsNotFiledArePlacedWhereTheirFileIs() async throws {
        let h = try await Harness.make(classifier: StubClassifier(code: "11", band: .review))
        defer { h.env.cleanup() }
        let target = try await h.env.folder("Utilities", area: "Home")
        await h.coordinator.enqueue(try h.env.drop("unclear.txt", text: "something"))
        await h.coordinator.drain()
        let held = try #require(try await h.services.documents.reviewQueue().first)
        var snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let review = try #require(snapshot.folder(role: .needsReview))
        #expect(snapshot.place(of: held, incoming: h.env.incoming) == .folder(review, year: nil), "waiting in Needs review")

        let docID = try #require(held.id)
        let actions = ReviewActions(services: h.services, coordinator: h.coordinator)
        try await actions.move(docID, toFolder: target.id)
        try await actions.undo(docID)
        let undone = try #require(try await h.services.documents.document(id: docID))
        snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        #expect(snapshot.place(of: undone, incoming: h.env.incoming) == .incoming, "back in Incoming after an undo")
        var gone = undone
        gone.status = .missing
        #expect(snapshot.place(of: gone, incoming: h.env.incoming) == .missing)
    }

    @Test func createsTheModelsFolderOnDemandAndUsesItsFileName() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto))
        defer { h.env.cleanup() }
        let url = try h.env.drop("scan_0001.txt", text: "EDP Comercial Fatura eletricidade")
        await h.coordinator.enqueue(url)
        await h.coordinator.drain()
        let snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let folder = try #require(snapshot.fileable.first { $0.name == "Utilities" })
        let target = snapshot.url(for: folder).appendingPathComponent("2026").appendingPathComponent("2026-07-05 EDP - Fatura eletricidade julho.txt")
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(Xattr.get(Xattr.originalName, from: target) == "scan_0001.txt")
        let found = try await h.services.documents.document(path: target.path)
        let doc = try #require(found)
        let docID = try #require(doc.id)
        #expect(doc.status == .filed && doc.decision?.folderCode == folder.code)
        let events = try await h.services.history.events(limit: 50)
        #expect(Set(events.map(\.kind)).isSuperset(of: [.arrived, .extracted, .classified, .folderCreated, .filed]))
        #expect(events.first { $0.kind == .classified }?.summary.hasPrefix("new Home / Utilities · auto") == true,
                "history names the folder by its path, not the app's code")
        let traceID = try #require(doc.lastTraceId)
        let loaded = try await h.services.traces.trace(id: traceID)
        let trace = try #require(loaded)
        #expect(Set(trace.1.map(\.stage)).isSuperset(of: ["hash", "dedupe", "name", "place", "index"]))
        #expect(await h.learner.filed == [docID])
        let search = SearchService(database: h.env.database, vectors: h.services.vectors, embedder: nil, config: h.env.config.search)
        #expect(try await search.fullText(SearchQuery(text: "eletricidade")).hits.count == 1)
    }

    @Test func aDocumentTheModelGaveNoNameKeepsItsOwn() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto, fileName: nil))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("scan.txt", text: "x"))
        await h.coordinator.drain()
        let filed = try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 1)
        #expect(filed.first?.filename == "scan.txt")
    }

    @Test func newFolderWaitsForReviewWhenAutoCreationIsOff() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .check))
        defer { h.env.cleanup() }
        try await h.env.settings.update { $0.autoCreateFolders = false }
        await h.coordinator.enqueue(try h.env.drop("a.txt", text: "x"))
        await h.coordinator.drain()
        #expect(try await h.env.taxonomy.snapshot(root: h.env.archive).fileable.isEmpty)
        let held = try await h.services.documents.reviewQueue()
        let doc = try #require(held.first)
        let actions = ReviewActions(services: h.services, coordinator: h.coordinator)
        let docID = try #require(doc.id)
        try await actions.approve(docID)
        let snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let filed = try #require(try await h.services.documents.document(id: docID))
        let home = try #require(filed.folderId.flatMap(snapshot.folder(id:)))
        #expect(snapshot.path(of: home) == "Home / Utilities" && filed.status == .filed, "approving creates the proposed path")
    }

    @Test func duplicatesGoToTheDuplicatesFolder() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("a.txt", text: "same bytes"))
        await h.coordinator.drain()
        let copy = try h.env.drop("a copy.txt", text: "same bytes")
        await h.coordinator.enqueue(copy)
        await h.coordinator.drain()
        let snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let dupCode = try #require(snapshot.folder(role: .duplicates)?.code)
        let dupDir = try await h.folderURL(dupCode)
        #expect(FileManager.default.fileExists(atPath: dupDir.appendingPathComponent("a copy.txt").path))
        let docs = try await h.services.documents.list(DocumentFilter(statuses: [.duplicate]), limit: 10)
        #expect(docs.count == 1 && docs[0].duplicateOf != nil)
    }

    @Test func lowConfidenceIsHeldForReviewAndCanBeMovedByTheUser() async throws {
        let h = try await Harness.make(classifier: StubClassifier(code: "11", band: .review))
        defer { h.env.cleanup() }
        let target = try await h.env.folder("Utilities", area: "Home")
        await h.coordinator.enqueue(try h.env.drop("unclear.txt", text: "something"))
        await h.coordinator.drain()
        let held = try await h.services.documents.reviewQueue()
        let doc = try #require(held.first)
        let docID = try #require(doc.id)
        #expect(doc.status == .needsReview)
        #expect(await h.learner.filed.isEmpty)
        let actions = ReviewActions(services: h.services, coordinator: h.coordinator)
        try await actions.move(docID, toFolder: target.id)
        let reloaded = try await h.services.documents.document(id: docID)
        let moved = try #require(reloaded)
        #expect(moved.status == .filed && moved.folderId == target.id)
        #expect(moved.path.contains("/\(target.relativePath)/"))
        #expect(await h.learner.corrections.count == 1)
    }

    @Test func transientOllamaErrorsWaitWithoutConsumingAttempts() async throws {
        let h = try await Harness.make(classifier: StubClassifier(code: "11", band: .auto, error: OllamaError.unreachable("down")))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("x.txt", text: "x"))
        await h.coordinator.drain()
        let jobs = try await h.services.jobs.active()
        #expect(jobs.count == 1)
        #expect(jobs[0].attempt == 0 && jobs[0].state == .classifying)
        #expect(await h.coordinator.status.waitingForOllama)
    }

    @Test func permanentFailuresRetryThenParkInNeedsReview() async throws {
        let h = try await Harness.make(classifier: StubClassifier(code: "11", band: .auto, error: IngestError.invalidState("boom")))
        defer { h.env.cleanup() }
        var config = h.env.config
        config.ingest.retryDelays = [0, 0, 0]
        let services = PipelineServices(database: h.services.database, config: config, settings: h.services.settings,
                                        taxonomy: h.services.taxonomy, extractor: h.services.extractor,
                                        classifier: h.services.classifier, learner: h.services.learner, filer: h.services.filer,
                                        traces: h.services.traces, vectors: h.services.vectors)
        let coordinator = IngestCoordinator(services: services)
        let url = try h.env.drop("bad.txt", text: "x")
        await coordinator.enqueue(url)
        for _ in 0..<config.ingest.maxAttempts { await coordinator.drain() }
        let failed = try await h.services.documents.list(DocumentFilter(statuses: [.failed]), limit: 5)
        #expect(failed.count == 1)
        let reviewSnapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let review = try #require(reviewSnapshot.folder(role: .needsReview))
        #expect(failed.first?.folderId == review.id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFileDroppedIntoAFolderAtAnyDepthIsAdoptedWhereItIs() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .review))
        defer { h.env.cleanup() }
        let santander = try await h.env.folder(path: ["Portugal", "Hlistan Zolerani LDA", "Banking", "Santander"], yearly: true)
        let snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let banking = try #require(santander.parentCode.flatMap(snapshot.folder(code:)))
        let review = try await h.env.taxonomy.ensureSystemFolder(.needsReview, root: h.env.archive)
        func place(_ name: String, in directory: URL) throws -> URL {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try Data("\(name) contents".utf8).write(to: url)
            return url
        }
        let statement = try place("statement.txt", in: snapshot.url(for: santander).appendingPathComponent("2025"))
        let overview = try place("overview.txt", in: snapshot.url(for: banking))
        let stray = try place("stray.txt", in: try await h.env.taxonomy.snapshot(root: h.env.archive).url(for: review))

        await ArchiveReconciler(services: h.services, coordinator: h.coordinator)
            .apply([.untrackedFile(path: statement.path), .untrackedFile(path: overview.path), .untrackedFile(path: stray.path)])
        await h.coordinator.drain()

        let documents = try await h.services.documents.list(DocumentFilter(), limit: 10)
        let adopted = try #require(documents.first { $0.originalFilename == "statement.txt" })
        #expect(adopted.folderId == santander.id && adopted.status == .filed, "the folder the user put it in is the decision")
        #expect(adopted.path == statement.path, "it stays in the year folder it was put in")
        #expect(documents.first { $0.originalFilename == "overview.txt" }?.folderId == banking.id, "any level holds documents")
        #expect(!documents.contains { $0.originalFilename == "stray.txt" }, "a file in the app's own folders is not adopted")
        let summaries = try await h.services.history.events(limit: 50, kinds: [.adopted]).map(\.summary)
        #expect(summaries.contains("statement.txt added to Portugal / Hlistan Zolerani LDA / Banking / Santander"))
    }

    @Test func statisticsCoverEveryFolderOfTheUsersAtAnyDepth() async throws {
        let path = ["Portugal", "Banking", "Santander"]
        let deep = FolderSpec(parentCode: nil, levels: path.map { FolderLevel(name: $0, description: "\($0).") }, yearSubfolders: true,
                              yearRule: .documentDate)
        let h = try await Harness.make(classifier: StubClassifier(newFolder: deep, band: .auto))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("statement.txt", text: "Santander statement"))
        await h.coordinator.drain()
        _ = try await h.env.taxonomy.ensureSystemFolder(.needsReview, root: h.env.archive)
        let snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let santander = try #require(snapshot.folders.first { $0.name == "Santander" })

        let insights = try await StatsService(database: h.env.database, config: h.env.config.stats).insights()
        #expect(insights.folders.map(\.code) == snapshot.lineage(of: santander).map(\.code),
                "every level is a folder of the user's, outermost first; the app's own folders are not")
        #expect(insights.folders.last?.documents == 1)
        #expect(snapshot.path(ofCode: santander.code) == path.joined(separator: " / "))
        #expect(snapshot.path(ofCode: "F999") == nil)
    }

    @Test func undoReturnsFileToIncomingAndHoldsIt() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("u.txt", text: "undo me"))
        await h.coordinator.drain()
        let filed = try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 1)
        let doc = try #require(filed.first)
        let docID = try #require(doc.id)
        let actions = ReviewActions(services: h.services, coordinator: h.coordinator)
        try await actions.undo(docID)
        let reloaded = try await h.services.documents.document(id: docID)
        let undone = try #require(reloaded)
        #expect(undone.status == .undone)
        #expect(undone.path.hasPrefix(h.env.incoming.path))
        #expect(FileManager.default.fileExists(atPath: undone.path))
        #expect(await h.coordinator.enqueue(undone.url) == nil)
        #expect(await h.learner.forgotten == [docID])
        let snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        #expect(snapshot.fileable.isEmpty, "the folder it left empty is removed")
        #expect(await h.learner.removedFolders.count == 2, "the category and the area it leaves empty")
    }
}
