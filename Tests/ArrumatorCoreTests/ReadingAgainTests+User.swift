import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// What the user does while a document is read again stands, and so does what it had where reading it again could not
/// give it anything.
extension ReadingAgainTests {
    /// The pipeline over `h` reading every document as a contract from MEO, held while it reads `name` until let go.
    static func heldReading(_ h: Harness, of name: String) async -> (pipeline: (services: PipelineServices, coordinator: IngestCoordinator,
                                                                                review: ReviewActions), holding: Holding) {
        let holding = Holding()
        await holding.hold(name)
        let analyzer = StubAnalyzer(labels: LabelingTests.meoContract, title: Harness.otherTitle, during: { try await holding.read($0) })
        return (pipeline(h, analyzer), holding)
    }

    @Test("A document left for later or undone while it is read again is left as the user left it",
          arguments: [DocumentAction.hold, .undo])
    func aDocumentSetAsideWhileItIsReadAgainIsLeftAsTheUserLeftIt(action: DocumentAction) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let earlier = try await Self.filedEarlier(h)
        let id = try #require(earlier.id)
        let ((services, coordinator, review), holding) = await Self.heldReading(h, of: earlier.filename)
        try await review.retry(id)
        let worker = Task { await coordinator.drain() }
        #expect(await Patience.until { await holding.held == earlier.filename }, "the model reads the document again")
        if action == .hold { try await review.hold(id) } else { try await review.undo(id) }
        await holding.letGo()
        _ = await worker.value
        let after = try #require(try await services.documents.document(id: id))
        #expect(after.status == (action == .hold ? .held : .undone) && after.labels == earlier.labels,
                "\(action): it stays as the user left it, with the labels it had: \(after.status) \(after.labels ?? [])")
        let place = action == .hold ? earlier.path : h.env.incoming.appendingPathComponent("bill.txt").spelledOnDisk.path
        #expect(after.path == place && FileManager.default.fileExists(atPath: place), "\(action): its file is where the user put it")
        #expect(try await services.history.events(limit: 20, kinds: [.analysed, .filed, .failed], docID: id).count == 2,
                "\(action): nothing of the reading is recorded, nor any failure: what is recorded is its first reading and filing")
        #expect(try await h.jobs().last?.state == .cancelled, "\(action): the reading again is cancelled")
    }

    @Test func aDocumentLeftForLaterAsItIsRenamedIsRecordedWhereItIsAndKeepsTheRestAsTheUserLeftIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let earlier = try await Self.filedEarlier(h)
        let id = try #require(earlier.id)
        // The user leaves it for later just as the filing that renames it begins: after the move was planned, before it
        // is recorded.
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER left_for_later_as_it_moves AFTER UPDATE OF payload_json ON jobs
                WHEN NEW.kind = '\(JobKind.reanalyse.rawValue)' AND json_extract(NEW.payload_json, '$.plannedPath') IS NOT NULL
                BEGIN
                  UPDATE documents SET status = '\(DocumentStatus.held.rawValue)' WHERE id = NEW.doc_id;
                  UPDATE jobs SET state = '\(JobState.cancelled.rawValue)', claim = NULL, claimed_by = NULL WHERE id = NEW.id;
                END
                """)
        }
        let (services, coordinator, review) = Self.pipeline(h, StubAnalyzer(labels: LabelingTests.meoContract, title: Harness.otherTitle))
        try await review.retry(id)
        await coordinator.drain()

        let after = try #require(try await services.documents.document(id: id))
        let renamed = h.env.archive.appendingPathComponent(Harness.otherFileName + ".txt").standardizedFileURL.path
        #expect(after.path == renamed && FileManager.default.fileExists(atPath: renamed), "its record follows the file to where it was moved")
        #expect(after.status == .held && after.labels == earlier.labels && after.analysis == earlier.analysis,
                "and it keeps the rest as the user left it, left for later: \(after.status) \(after.labels ?? [])")
        #expect(try await Self.embeddingModels(h, id) == [Self.earlierModel, StubAnalyzer.embeddingModel], "its meaning too")
        let events = try await services.history.events(limit: 20, kinds: [.analysed, .filed], docID: id)
        let said = events.map(\.summary)
        #expect(said.first?.hasSuffix(DocumentFiler.setAside) == true && said.count == 3,
                "History says it was renamed and nothing more, and records no reading: \(said)")
        #expect(events.filter { $0.kind == .filed }.map(\.announcesFiling) == [false, true],
                "and no notification announces it as filed, as one did its first filing (the review of this fix)")
    }

    @Test func aNameTheUserGivesWhileItIsReadAgainStaysAndTheReadingFillsInTheRest() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let earlier = try await Self.filedEarlier(h)
        let id = try #require(earlier.id)
        let ((services, coordinator, review), holding) = await Self.heldReading(h, of: earlier.filename)
        try await review.retry(id)
        let worker = Task { await coordinator.drain() }
        #expect(await Patience.until { await holding.held == earlier.filename }, "the model reads the document again")
        try await review.edit(id, fileName: "Mine", labels: nil)
        await holding.letGo()
        _ = await worker.value
        let after = try #require(try await services.documents.document(id: id))
        #expect(after.filename == "Mine.txt" && after.analysis?.fileName == "Mine" && FileManager.default.fileExists(atPath: after.path),
                "the name the user gave while it was read stays: \(after.filename)")
        #expect(after.labels == LabelingTests.meoContract + [Self.tag] && after.status == .filed, "and the reading fills in the labels")
    }

    @Test func aReadingAgainThatMakesNoEmbeddingLeavesTheMeaningItHad() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let earlier = try await Self.filedEarlier(h)
        let id = try #require(earlier.id)
        let (services, coordinator, review) = Self.pipeline(h, WithoutMeaning(labels: LabelingTests.meoContract))
        try await review.retry(id)
        await coordinator.drain()
        let after = try #require(try await services.documents.document(id: id))
        #expect(after.labels == LabelingTests.meoContract + [Self.tag], "the reading is filed")
        #expect(try await Self.embeddingModels(h, id) == [Self.earlierModel, StubAnalyzer.embeddingModel],
                "with no embedding of its own, it keeps those it had, rather than being found by meaning not at all")
    }

    @Test func aDocumentWithNoFileToReadIsNotReadAgainAndNothingIsRecorded() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: Self.bill)
        let id = try #require(doc.id)
        try FileManager.default.removeItem(at: doc.url)
        try await ArchiveReconciler(services: h.services, coordinator: h.coordinator).apply([.gone(path: doc.path)])
        await #expect(throws: IngestError.cannotReadAgain(id), "a missing document has no file to read") { try await h.review.retry(id) }
        #expect(try await h.services.history.events(limit: 20, kinds: [.retry], docID: id).isEmpty, "and no reading again is recorded")
        #expect(try await h.services.jobs.active().isEmpty, "nor queued")
    }

    @Test func readingEveryDocumentAgainFromACommandStopsAtTheFirstThatWaitsForOllamaAndSaysItOnce() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        var ids: [Int64] = []
        for name in ["a.txt", "b.txt"] { ids.append(try #require(try await h.ingest(name, text: "\(Self.bill) \(name)").id)) }
        let (services, coordinator, review) = Self.pipeline(h, StubAnalyzer(error: OllamaError.unreachable("connection refused")))
        try await review.retryAll()
        await coordinator.drain(.everything)
        #expect(try await h.jobs().suffix(2).map(\.state) == [.analysing, .pending],
                "the first waits for Ollama where it stopped, and the command stops there rather than take the next")
        h.env.time.advance(by: h.env.config.ingest.retryDelays.last)
        await coordinator.drain(.everything)
        let waits = try await services.history.events(limit: 20, kinds: [.retry], docID: ids[0]).map(\.summary)
        #expect(waits.count == 1 && waits.first?.hasPrefix("Waiting for Ollama") == true,
                "History says once that it waits for Ollama, however often it is tried meanwhile: \(waits)")
    }

    @Test func aLabelOrANameTheUserChangesWhileItWaitsToBeReadAgainStays() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let earlier = try await Self.filedEarlier(h)
        let id = try #require(earlier.id)
        let (services, coordinator, review) = Self.pipeline(h, StubAnalyzer(labels: LabelingTests.meoContract, title: Harness.otherTitle))
        try await review.retryAll()
        // While it waits its turn, before the model begins.
        let mine = DocumentLabel(kind: .sender, value: "Mine Lda")
        try await review.edit(id, fileName: "Mine", labels: LabelEdit(adding: [mine], removing: earlier.labels?.filter { $0.kind == .sender } ?? []))
        await coordinator.drain(.everything)
        let after = try #require(try await services.documents.document(id: id))
        #expect(after.filename == "Mine.txt" && after.labels(.sender) == ["Mine Lda"],
                "what the user changed after asking for it to be read again stays: \(after.filename) \(after.labels ?? [])")
        #expect(after.labels(.party) == LabelingTests.meoContract.values(.party), "and the reading fills in the rest")
    }

    @Test func aCommandTakesNoDocumentThatWaitsWithTheRestOfTheArchive() async throws {
        let analyzer = StubAnalyzer(title: nil)
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        for name in ["a.txt", "b.txt"] { try await h.ingest(name, text: "\(Self.bill) \(name)") }
        try await h.review.retryAll()
        await h.coordinator.enqueue(try h.env.drop("new.txt", text: "A new arrival"))
        await h.coordinator.drain()
        let read = await analyzer.calls.files
        #expect(read == ["a.txt", "b.txt", "new.txt"],
                "a command files the file it was given, and none of the archive waiting to be read again: \(read)")
        #expect(try await h.services.jobs.counts() == JobCounts(queued: 0, reindexing: 0, readingAgain: 2),
                "those are left to the app, or run")
    }

    @Test func aJobReadingADocumentAgainIsFoundByItsDocumentWhereverItWasLeft() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: Self.bill)
        let id = try #require(doc.id)
        // A job an earlier version queued where the document was before it moved, and one where it is now.
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (kind, doc_id, source_path, state, payload_json, created_at, updated_at, gives_way)
                VALUES ('\(JobKind.reindex.rawValue)', ?, '/Archive/where it was.txt', 'pending', '{}', 0, 0, 1)
                """, arguments: [id])
        }
        let queued = try await h.services.jobs.enqueue(path: doc.path, kind: .reanalyse, docID: id)
        let jobs = try await h.jobs()
        #expect(queued.isNew && jobs.filter { $0.state.isActive }.map(\.id) == [queued.id],
                "a request to read it again finds the job left where it was, which does less, and takes its place")
        // Two jobs of one document, one left behind: a move of the document moves the one where it was.
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (kind, doc_id, source_path, state, payload_json, created_at, updated_at, gives_way)
                VALUES ('\(JobKind.reindex.rawValue)', ?, '/Archive/left behind.txt', 'pending', '{}', 0, 0, 1)
                """, arguments: [id])
        }
        let moved = h.env.archive.appendingPathComponent("moved.txt").path
        try await h.services.documents.update(id) { $0.path = moved }
        let paths = try await h.env.database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT source_path FROM jobs WHERE doc_id = ? AND state = 'pending' ORDER BY id", arguments: [id])
        }
        #expect(paths == [moved, "/Archive/left behind.txt"], "the document's job follows it; the one left behind stays, and nothing fails: \(paths)")
    }
}

/// Reads a document as `StubAnalyzer` does, with `labels`, but makes no embedding of it, as an embedding model that
/// failed.
struct WithoutMeaning: DocumentAnalyzing {
    let labels: [DocumentLabel]

    func analyse(_ content: ExtractedContent, guidance: LabelGuidance, settings: AppSettings, config: PipelineConfig,
                 trace: TraceContext) async throws -> AnalysisOutcome {
        var outcome = try await StubAnalyzer(labels: labels, title: Harness.otherTitle).analyse(content, guidance: guidance, settings: settings,
                                                                                               config: config, trace: trace)
        (outcome.embedding, outcome.embeddingModel) = (nil, nil)
        return outcome
    }

    func embedding(for content: ExtractedContent, senders: [String], interpretation: String?, settings: AppSettings,
                   config: PipelineConfig, trace: TraceContext) async throws -> (vector: [Float], model: String)? { nil }
}
