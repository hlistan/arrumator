import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// Reading a document of the archive again, for an exact copy of it put into Incoming, **Read Again** or every document
/// at once, changes nothing of it until it is filed, and then puts what it read in the place of everything it had, in one
/// transaction: its labels but its tags, its name, its text and its meaning.
@Suite struct ReadingAgainTests {
    static let bill = IngestTests.bill
    static let tag = DocumentLabel(kind: .tag, value: "Taxes 2024")
    /// The embedding model of a profile used before the one in use.
    static let earlierModel = "earlier-embed"
    static let searchable = ["sender:edp", "stale", "sender:meo", "july"]

    /// A bill filed as EDP's, given a tag by hand, whose text an earlier extractor read otherwise ("stale words") and
    /// which an earlier profile's model embedded too.
    static func filedEarlier(_ h: Harness) async throws -> DocumentRecord {
        let id = try #require(try await h.ingest("bill.txt", text: bill).id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [tag]))
        try await h.services.index.upsertEmbedding(docID: id, model: earlierModel, vector: [0, 1, 0], sourceText: "earlier")
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE document_text SET body = 'stale words' WHERE doc_id = ?", arguments: [id])
        }
        return try #require(try await h.services.documents.document(id: id))
    }

    /// The pipeline over `h`'s archive and configuration, reading documents as `analyzer` does, as after the user chose
    /// another profile.
    static func pipeline(_ h: Harness, _ analyzer: any DocumentAnalyzing) -> (services: PipelineServices, coordinator: IngestCoordinator,
                                                                      review: ReviewActions) {
        var services = h.services
        services.analyzer = analyzer
        let coordinator = IngestCoordinator(services: services)
        return (services, coordinator, ReviewActions(services: services, coordinator: coordinator))
    }

    /// What each of `searchable` finds, by words alone.
    static func found(_ h: Harness) async throws -> [String: [Int64]] {
        var found: [String: [Int64]] = [:]
        for words in searchable { found[words] = try await h.search.fullText(SearchQuery(text: words, semantic: false)).hits.map(\.id) }
        return found
    }

    static func embeddingModels(_ h: Harness, _ id: Int64) async throws -> [String] {
        try await h.env.database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT model FROM embeddings WHERE doc_id = ? ORDER BY model", arguments: [id])
        }
    }

    @Test func aCopyHasItsOriginalFoundAsItWasUntilItIsFiledAndThenOnlyAsItIsReadNow() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let earlier = try await Self.filedEarlier(h)
        let id = try #require(earlier.id)
        let holding = Holding()
        let analyzer = StubAnalyzer(labels: LabelingTests.meoContract, title: Harness.otherTitle, during: { try await holding.read($0) })
        let (services, coordinator, _) = Self.pipeline(h, analyzer)
        await holding.hold(earlier.filename)
        await coordinator.enqueue(try h.env.drop("bill copy.txt", text: Self.bill))
        let worker = Task { await coordinator.drain() }
        #expect(await Patience.until { await holding.held == earlier.filename }, "the model reads the original again")

        let meanwhile = try #require(try await services.documents.document(id: id))
        #expect(meanwhile.labels == earlier.labels && meanwhile.path == earlier.path && meanwhile.status == .filed,
                "while it is read, it keeps its labels, its name and its place: \(meanwhile.labels ?? [])")
        #expect(try await Self.found(h) == ["sender:edp": [id], "stale": [id], "sender:meo": [], "july": []],
                "and is found by its labels and its text as they were, and by nothing it is being read as")
        #expect(try await Self.embeddingModels(h, id) == [Self.earlierModel, StubAnalyzer.embeddingModel], "and by its meaning as it was")
        await holding.letGo()
        _ = await worker.value
        let read = try #require(try await services.documents.document(id: id))
        #expect(read.labels == LabelingTests.meoContract + [Self.tag],
                "once filed, it has the labels read now and its tag, and none the model gave it before: \(read.labels ?? [])")
        #expect(read.filename == Harness.otherFileName + ".txt" && read.status == .filed, "under the name read now")
        #expect(try await Self.found(h) == ["sender:edp": [], "stale": [], "sender:meo": [id], "july": [id]],
                "nothing finds it by what it was before: its labels and its text are those read from its file now")
        #expect(try await Self.embeddingModels(h, id) == [StubAnalyzer.embeddingModel],
                "its meaning is that of the profile in use alone, an earlier model's gone with the rest")
        let events = try await services.history.events(limit: 20, docID: id).map(\.kind)
        let steps = try await h.env.database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT stage FROM trace_steps WHERE trace_id = (SELECT last_trace_id FROM documents WHERE id = ?)",
                                arguments: [id])
        }
        #expect(steps.contains(TraceStage.index.rawValue), "its trace says the index took what it read now: \(steps)")
        #expect(Array(events.prefix(4)) == [.filed, .analysed, .extracted, .duplicate] && events.filter { $0 == .analysed }.count == 2,
                "History says the copy, then its text read, then the reading recorded once with its filing, before it: \(events)")
    }

    @Test func aReadingAgainWithoutAValidAnswerKeepsTheLabelsTheDocumentHadAndItWaitsForYou() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let earlier = try await Self.filedEarlier(h)
        let id = try #require(earlier.id)
        let (services, coordinator, review) = Self.pipeline(h, StubAnalyzer(labels: nil))
        try await review.retry(id)
        await coordinator.drain()

        let read = try #require(try await services.documents.document(id: id))
        #expect(read.labels == earlier.labels && read.isLabelled && read.status == .needsReview,
                "a reading that gives no labels made none to put in their place: it keeps those it had, and waits for you: \(read.labels ?? [])")
        #expect(read.filename == earlier.filename && read.analysis?.problems == [DocumentAnalysis.Problem.noAnswer],
                "it keeps its name, as a reading that gives none leaves it, and its card says why it waits")
        #expect(try await Self.found(h)["sender:edp"] == [id], "it is found by the labels it had still")
        let said = try await services.history.events(limit: 5, kinds: [.error], docID: id).map(\.summary)
        #expect(said == ["Not read: " + DocumentAnalysis.said([DocumentAnalysis.Problem.noAnswer]) + "; keeps its tag “\(Self.tag.value)”"],
                "History says why, and that it keeps its tag: \(said)")
    }

    @Test func aFilingThatCannotBeRecordedLeavesTheDocumentAsItWasAndTheNextAttemptRecordsItWhole() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let earlier = try await Self.filedEarlier(base)
        let id = try #require(earlier.id)
        // Recording the filing of the reading again fails once, after the file was renamed.
        try await base.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER recording_fails_once BEFORE INSERT ON embeddings
                WHEN (SELECT kind || attempt FROM jobs WHERE doc_id = NEW.doc_id ORDER BY id DESC LIMIT 1) = '\(JobKind.reanalyse.rawValue)0'
                BEGIN SELECT RAISE(ABORT, 'the index is briefly unavailable'); END
                """)
        }
        let analyzer = StubAnalyzer(labels: LabelingTests.meoContract, title: Harness.otherTitle)
        let (services, coordinator, review) = Self.pipeline(base, analyzer)
        try await review.retry(id)
        await coordinator.drain()

        let renamed = base.env.archive.appendingPathComponent(Harness.otherFileName + ".txt").standardizedFileURL
        #expect(FileManager.default.fileExists(atPath: renamed.path) && !FileManager.default.fileExists(atPath: earlier.path),
                "the file was renamed before its filing was to be recorded")
        let meanwhile = try #require(try await services.documents.document(id: id))
        #expect(meanwhile.labels == earlier.labels && meanwhile.path == earlier.path && meanwhile.status == .filed,
                "nothing of the reading is recorded: the document is as it was: \(meanwhile.labels ?? [])")
        #expect(try await Self.found(base)["sender:edp"] == [id], "and found as it was")
        #expect(try await Self.embeddingModels(base, id) == [Self.earlierModel, StubAnalyzer.embeddingModel], "its meaning too")
        #expect(try await services.history.events(limit: 20, kinds: [.analysed], docID: id).count == 1, "History has no reading yet")

        // The user corrects the sender before the next attempt.
        let mine = DocumentLabel(kind: .sender, value: "Mine Lda")
        try await review.edit(id, fileName: nil, labels: LabelEdit(adding: [mine], removing: earlier.labels?.filter { $0.kind == .sender } ?? []))
        base.env.time.advance(by: base.env.config.ingest.retryDelays.first)
        await coordinator.drain()

        let read = try #require(try await services.documents.document(id: id))
        #expect(read.path == renamed.path && read.status == .filed, "the next attempt records the document where its file went")
        #expect(read.labels == LabelingTests.meoContract.filter { $0.kind != .sender } + [Self.tag, mine],
                "with the labels read, but the sender the user corrected after the reading began: \(read.labels ?? [])")
        #expect(try await Self.embeddingModels(base, id) == [StubAnalyzer.embeddingModel], "and the meaning read now alone")
        #expect(try await services.history.events(limit: 20, kinds: [.analysed], docID: id).count == 2, "the reading is recorded once")
        #expect(try await base.jobs().map(\.state) == [.done, .done], "and the job is done")
    }

    @Test func readingEveryDocumentAgainReadsThoseInTheArchiveAfterEveryFileThatArrives() async throws {
        let analyzer = StubAnalyzer(title: nil)
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        var ids: [Int64] = []
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] { ids.append(try #require(try await h.ingest(name, text: "\(Self.bill) \(name)").id)) }
        try await h.services.documents.update(ids[1]) { $0.status = .needsReview }
        try await h.review.hold(ids[2])
        try await h.review.undo(ids[3])
        let before = try await h.services.history.events(limit: 50).count

        let queued = try await h.review.retryAll()
        #expect(queued == [ids[0], ids[1]], "the documents in the archive are queued, filed or waiting for you, not one left for later or undone")
        #expect(try await h.services.jobs.counts() == JobCounts(queued: 0, reindexing: 0, readingAgain: 2),
                "counted as read again with the rest, not as files waiting in Incoming")
        let events = try await h.services.history.events(limit: 50)
        let event = try #require(events.first)
        let profile = await h.services.settings.current.profile
        #expect(events.count == before + 1 && event.kind == .retry && event.actor == .user && event.docId == nil
                    && JSON.decode(ReadingAllAgainPayload.self, from: event.payloadJson) == ReadingAllAgainPayload(profile: profile, documents: queued),
                "History records it once, under no document, naming the profile and the documents: \(event.summary)")

        await h.coordinator.enqueue(try h.env.drop("new.txt", text: "A new arrival"))
        #expect(try await h.services.jobs.listed(inHand: nil).map { URL(fileURLWithPath: $0.sourcePath).lastPathComponent } == ["new.txt"], "Incoming lists the file that arrived alone")
        await h.coordinator.drain(.everything)
        let read = await analyzer.calls.files
        #expect(Array(read.suffix(3)) == ["new.txt", "a.txt", "b.txt"], "the file that arrived meanwhile is filed first: \(read)")
        let statuses = try await h.services.documents.documents(ids: ids).map(\.status)
        #expect(statuses == [.filed, .filed, .held, .undone], "those read again are filed; those set aside stay so")
        #expect(try await h.services.jobs.counts() == JobCounts(queued: 0, reindexing: 0, readingAgain: 0), "and none is left to read")
    }

    @Test func aDocumentAskedForWhileItWaitsWithTheRestIsReadInItsTurn() async throws {
        let analyzer = StubAnalyzer(title: nil)
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        var ids: [Int64] = []
        for name in ["a.txt", "b.txt", "c.txt"] { ids.append(try #require(try await h.ingest(name, text: "\(Self.bill) \(name)").id)) }
        try await h.review.retryAll()
        try await h.review.retry(ids[2])
        await h.coordinator.enqueue(try h.env.drop("b copy.txt", text: "\(Self.bill) b.txt"))
        #expect(try await h.services.jobs.counts() == JobCounts(queued: 2, reindexing: 0, readingAgain: 2),
                "Read Again on one takes it out of those that give way, and the copy waits in Incoming")
        let asked = try await h.services.history.events(limit: 10, kinds: [.retry], docID: ids[2]).map(\.summary)
        #expect(asked.count == 1, "the Read Again that takes its place is recorded under it: \(asked)")
        await h.coordinator.drain(.everything)
        let read = await analyzer.calls.files
        #expect(Array(read.dropFirst(3)) == ["c.txt", "b.txt", "a.txt"],
                "the one asked for, then the one whose copy came, each in its turn, then the rest, each read once: \(read)")
        #expect(try await h.services.jobs.counts() == JobCounts(queued: 0, reindexing: 0, readingAgain: 0), "and none is left to read")
    }

    @Test func aDocumentRenamedOrLeftForLaterWhileItWaitsIsReadWhereItIsOrNotAtAll() async throws {
        let analyzer = StubAnalyzer(title: nil)
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        var ids: [Int64] = []
        for name in ["a.txt", "b.txt", "c.txt"] { ids.append(try #require(try await h.ingest(name, text: "\(Self.bill) \(name)").id)) }
        try await h.review.retryAll()
        // Meanwhile, a and c are renamed in Finder, and b is left for later.
        let reconciler = ArchiveReconciler(services: h.services, coordinator: h.coordinator)
        for (id, name) in [(ids[0], "a renamed.txt"), (ids[2], "c renamed.txt")] {
            let document = try #require(try await h.services.documents.document(id: id))
            let renamed = h.env.archive.appendingPathComponent(name).standardizedFileURL
            try FileManager.default.moveItem(at: document.url, to: renamed)
            try await reconciler.apply([.found(path: renamed.path), .gone(path: document.path)])
        }
        try await h.review.hold(ids[1])
        try await h.review.retry(ids[2])
        // And a new file is put where a was.
        let newcomer = try h.env.put("a.txt", text: "A new document")
        try await reconciler.apply([.found(path: newcomer.path)])
        #expect(try await h.services.jobs.counts() == JobCounts(queued: 2, reindexing: 0, readingAgain: 1),
                "Read Again on a renamed document finds its job where it is, the new file is queued, the one left for later is not")
        await h.coordinator.drain(.everything)

        let read = await analyzer.calls.files
        #expect(Array(read.dropFirst(3)) == ["c renamed.txt", "a.txt", "a renamed.txt"],
                "each renamed document is read where it is, once, the new file at a's old place as itself, and not the one left for later: \(read)")
        let documents = try await h.services.documents.documents(ids: ids)
        #expect(documents.map(\.status) == [.filed, .held, .filed] && documents.map(\.filename) == ["a renamed.txt", "b.txt", "c renamed.txt"],
                "those read again are filed where they are; the one left for later stays so")
        #expect(try await h.services.history.events(limit: 50, kinds: [.missing]).isEmpty, "and none is said to have disappeared")
        #expect(try await h.services.jobs.counts() == JobCounts(queued: 0, reindexing: 0, readingAgain: 0), "nothing is left to read")
    }

    @Test func readingEveryDocumentAgainWhenNoneIsLeftToQueueRecordsNothing() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        #expect(try await h.review.retryAll().isEmpty, "an archive with no document has none to read again")
        #expect(try await h.services.history.events(limit: 5, kinds: [.retry]).isEmpty, "and nothing is recorded")
        let id = try #require(try await h.ingest("bill.txt", text: Self.bill).id)
        #expect(try await h.review.retryAll() == [id], "a document is queued")
        #expect(try await h.review.retryAll().isEmpty, "asked again while it waits, it is queued once, as nothing is left to queue")
        #expect(try await h.services.history.events(limit: 5, kinds: [.retry]).count == 1, "and that is recorded once")
    }
}
