import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// Every incoming document is labelled by the local model before it is decided: the labels are the document's, kept
/// in its record file, searchable kind by kind, and every step of it is in the history, the trace and the funnel.
@Suite struct LabelingTests {
    /// Gives each file the labels listed for its name, and none to the rest.
    struct PerFileLabeler: DocumentLabeler {
        let labels: [String: [DocumentLabel]]

        func labels(for content: ExtractedContent, settings: AppSettings, config: PipelineConfig,
                    trace: TraceContext) async throws -> [DocumentLabel]? {
            labels[content.source.originalFilename] ?? []
        }
    }

    static let meoContract = [DocumentLabel(kind: .subject, value: "João Silva"), DocumentLabel(kind: .object, value: "mobile line 912345678"),
                              DocumentLabel(kind: .jurisdiction, value: "Spain"), DocumentLabel(kind: .language, value: "es")]

    private func filed(_ h: Harness) async throws -> [DocumentRecord] {
        try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 10)
    }

    @Test func everyIncomingDocumentIsLabelledBeforeItIsDecided() async throws {
        let labeler = StubLabeler()
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto), labeler: labeler)
        defer { h.env.cleanup() }
        for (name, text) in [("edp_july.txt", "EDP electricity July"), ("edp_august.txt", "EDP electricity August")] {
            await h.coordinator.enqueue(try h.env.drop(name, text: text))
        }
        await h.coordinator.drain()

        #expect(Set(await labeler.calls.files) == ["edp_july.txt", "edp_august.txt"], "the model is asked about every document")
        let documents = try await filed(h)
        #expect(documents.count == 2 && documents.allSatisfy { $0.labels == StubLabeler.edpBill }, "the labels are the document's")
        for document in documents {
            let events = try await h.services.history.events(limit: 20, docID: document.id).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
            let kinds = events.map(\.kind)
            #expect(kinds.firstIndex(of: .labeled).map { $0 < (kinds.firstIndex(of: .classified) ?? 0) } == true,
                    "a document is labelled before it is decided: \(kinds)")
            #expect(events.first { $0.kind == .labeled }?.summary
                        == "Maria Exemplo · electricity supply point PT0002000012345678 · Portugal · pt")
        }
    }

    @Test func aCopyOfAFiledDocumentIsNotReadAgainSoNotLabelledAgain() async throws {
        let labeler = StubLabeler()
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto), labeler: labeler)
        defer { h.env.cleanup() }
        for name in ["bill.txt", "bill copy.txt"] { await h.coordinator.enqueue(try h.env.drop(name, text: "EDP electricity")) }
        await h.coordinator.drain()
        #expect(await labeler.calls.files == ["bill.txt"], "the original carries the labels; the copy goes to Duplicates unread")
        let copy = try #require(try await h.services.documents.list(DocumentFilter(statuses: [.duplicate]), limit: 5).first)
        #expect(copy.labels == nil)
        #expect(try await h.services.documents.unlabelled().isEmpty, "a copy has no text of its own to be labelled from later")
    }

    @Test func aDocumentShowingNothingSignificantIsLabelledWithNothing() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto),
                                       labeler: StubLabeler(labels: []))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("note.txt", text: "Remember the milk"))
        await h.coordinator.drain()
        let document = try #require(try await filed(h).first)
        #expect(document.labels == [], "labelled, with nothing worth a label, which is not the same as not labelled")
        #expect(try await h.services.documents.unlabelled().isEmpty)
        #expect(try await h.services.history.events(limit: 20, kinds: [.labeled], docID: document.id).first?.summary == "Nothing worth a label")
    }

    @Test func withoutAValidAnswerTheDocumentIsStillFiledUnlabelledAndTheHistorySaysSo() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto),
                                       labeler: StubLabeler(labels: nil))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP electricity"))
        await h.coordinator.drain()
        let document = try #require(try await filed(h).first, "a document is filed whether or not it could be labelled")
        #expect(document.labels == nil)
        #expect(try await h.services.documents.unlabelled() == [try #require(document.id)], "so it can be labelled later")
        let events = try await h.services.history.events(limit: 20, docID: document.id)
        #expect(events.contains { $0.kind == .error && $0.summary == "Not labelled: the model gave no valid answer" })
        #expect(!events.contains { $0.kind == .labeled })
    }

    @Test func aModelThatCannotBeReachedKeepsTheDocumentWaitingToBeLabelled() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto),
                                       labeler: StubLabeler(error: OllamaError.unreachable("connection refused")))
        defer { h.env.cleanup() }
        let url = try h.env.drop("bill.txt", text: "EDP electricity")
        await h.coordinator.enqueue(url)
        await h.coordinator.drain()
        let jobs = try await h.services.jobs.active()
        #expect(jobs.map(\.state) == [.labeling] && jobs.first?.attempt == 0,
                "the job waits at labelling, where it carries on, and waiting for Ollama costs no attempt")
        #expect(await h.coordinator.status.waitingForOllama)
        let filedMeanwhile = try await filed(h)
        #expect(FileManager.default.fileExists(atPath: url.path) && filedMeanwhile.isEmpty, "nothing is decided or moved meanwhile")
    }

    @Test func aMissingModelHoldsTheDocument() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto),
                                       labeler: StubLabeler(error: OllamaError.modelNotFound("ministral-3:14b")))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP electricity"))
        await h.coordinator.drain()
        let jobs = try await h.env.database.reader.read { db in try JobRecord.fetchAll(db) }
        #expect(jobs.map(\.state) == [.held], "held until the model is downloaded, as when deciding")
    }

    @Test func aDocumentLeftUnlabelledIsLabelledLaterFromTheTextItArrivedWith() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto),
                                       labeler: StubLabeler(labels: nil))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP electricity"))
        await h.coordinator.drain()
        let id = try #require(try await filed(h).first?.id)

        var services = h.services
        services.labeler = StubLabeler()
        let review = ReviewActions(services: services, coordinator: h.coordinator)
        #expect(try await review.relabel(id) == StubLabeler.edpBill)
        #expect(try await h.services.documents.document(id: id)?.labels == StubLabeler.edpBill)
        #expect(try await h.services.documents.unlabelled().isEmpty)
        #expect(try await h.services.history.events(limit: 20, kinds: [.labeled], docID: id).count == 1)
        let trace = try #require(try await h.services.traces.traces(docID: id).first)
        #expect(trace.source == TraceSource.review.rawValue && trace.outcome == "labelled", "labelling again is traced too")
    }

    @Test func decidingAgainLabelsADocumentThatHasNoLabelsFirst() async throws {
        let h = try await Harness.make(classifier: StubClassifier(band: .review), labeler: StubLabeler(labels: nil))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP electricity"))
        await h.coordinator.drain()
        let waiting = try #require(try await h.services.documents.reviewQueue().first?.id)
        try await ReviewActions(services: h.services, coordinator: h.coordinator).retry(waiting)
        #expect(try await h.services.jobs.active().map(\.state) == [.labeling], "labelled, then decided again")
    }

    @Test func labelsAreSearchableKindByKind() async throws {
        let labeler = PerFileLabeler(labels: ["edp.txt": StubLabeler.edpBill, "meo.txt": Self.meoContract])
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto), labeler: labeler)
        defer { h.env.cleanup() }
        for name in ["edp.txt", "meo.txt"] { await h.coordinator.enqueue(try h.env.drop(name, text: "A bill: \(name)")) }
        await h.coordinator.drain()
        let byName = Dictionary(uniqueKeysWithValues: try await filed(h).map { ($0.originalFilename, try #require($0.id)) })
        let search = SearchService(database: h.env.database, vectors: VectorIndex(), embedder: nil, config: h.env.config.search)
        func found(_ query: String) async throws -> [Int64] { try await search.fullText(SearchQuery(text: query)).hits.map(\.id) }

        #expect(try await found("jurisdiction:portugal") == [byName["edp.txt"]], "a label is found under its kind")
        #expect(try await found("subject:\"joão silva\"") == [byName["meo.txt"]], "a whole name as a phrase, accents or not")
        #expect(try await found("object:912345678") == [byName["meo.txt"]])
        #expect(try await found("language:portuguese") == [byName["edp.txt"]], "a language by its English name")
        #expect(try await found("language:es") == [byName["meo.txt"]], "and by its code")
        #expect(try await found("spain") == [byName["meo.txt"]], "a label is found without naming its kind too")
        #expect(try await found("subject:portugal").isEmpty, "a kind matches only labels of that kind")
    }

    @Test func theFunnelShowsWhereDocumentsWereLabelled() async throws {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto),
                                       labeler: StubLabeler(labels: nil))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP electricity"))
        await h.coordinator.drain()
        let funnel = try await StatsService(database: h.env.database, config: h.env.config.stats).funnel(days: 7)
        let step = try #require(funnel.steps.first { $0.id == "labelled" })
        #expect(step.reached == 1 && step.errors == 1, "a document the model gave no labels for counts as an error at this step")
    }
}
