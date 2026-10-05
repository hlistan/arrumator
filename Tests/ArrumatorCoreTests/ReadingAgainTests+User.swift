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
        await worker.value

        let after = try #require(try await services.documents.document(id: id))
        #expect(after.status == (action == .hold ? .held : .undone) && after.labels == earlier.labels,
                "\(action): it stays as the user left it, with the labels it had: \(after.status) \(after.labels ?? [])")
        let place = action == .hold ? earlier.path : h.env.incoming.appendingPathComponent("bill.txt").spelledOnDisk.path
        #expect(after.path == place && FileManager.default.fileExists(atPath: place), "\(action): its file is where the user put it")
        #expect(try await services.history.events(limit: 20, kinds: [.analysed, .filed, .failed], docID: id).count == 2,
                "\(action): nothing of the reading is recorded, nor any failure: what is recorded is its first reading and filing")
        #expect(try await h.jobs().last?.state == .cancelled, "\(action): the reading again is cancelled")
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
        await worker.value

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
        await coordinator.drain(whileOllamaAnswers: true)
        #expect(try await h.jobs().suffix(2).map(\.state) == [.analysing, .pending],
                "the first waits for Ollama where it stopped, and the command stops there rather than take the next")
        h.env.time.advance(by: h.env.config.ingest.retryDelays.last)
        await coordinator.drain(whileOllamaAnswers: true)
        let waits = try await services.history.events(limit: 20, kinds: [.retry], docID: ids[0]).map(\.summary)
        #expect(waits.count == 1 && waits.first?.hasPrefix("Waiting for Ollama") == true,
                "History says once that it waits for Ollama, however often it is tried meanwhile: \(waits)")
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

    func embedding(for content: ExtractedContent, senders: [String], settings: AppSettings, config: PipelineConfig,
                   trace: TraceContext) async throws -> (vector: [Float], model: String)? { nil }
}
