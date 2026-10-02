import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// Every document is read by the model before it is filed, and its labels become its own: kept on it, searchable
/// kind by kind, and every step of it in the history, the trace and the funnel.
@Suite struct LabelingTests {
    static let meoContract = [DocumentLabel(kind: .sender, value: "MEO"), DocumentLabel(kind: .party, value: "João Silva"),
                              DocumentLabel(kind: .object, value: "mobile line 912345678"), DocumentLabel(kind: .jurisdiction, value: "Spain"),
                              DocumentLabel(kind: .language, value: "es")]

    @Test func everyDocumentIsReadAndLabelledBeforeItIsFiled() async throws {
        let analyzer = StubAnalyzer()
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        for (name, text) in [("edp_july.txt", "EDP electricity July"), ("edp_august.txt", "EDP electricity August")] {
            try await h.ingest(name, text: text)
        }
        #expect(Set(await analyzer.calls.files) == ["edp_july.txt", "edp_august.txt"], "the model reads every document")
        for document in try await h.services.documents.list(DocumentFilter(), limit: 5) {
            #expect(document.labels == StubAnalyzer.edpBill, "the labels are the document's")
            let kinds = try await h.services.history.events(limit: 20, docID: document.id).sorted { ($0.id ?? 0) < ($1.id ?? 0) }.map(\.kind)
            #expect(kinds.firstIndex(of: .analysed).map { $0 < (kinds.firstIndex(of: .filed) ?? 0) } == true,
                    "a document is read before it is filed: \(kinds)")
        }
        let event = try #require(try await h.services.history.events(limit: 20, kinds: [.analysed]).first)
        #expect(event.summary == StubAnalyzer.edpBill.map(\.value).joined(separator: " · "), "the history says what it was labelled with")
    }

    @Test func aDocumentShowingNothingSignificantIsLabelledWithNothing() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: []))
        defer { h.env.cleanup() }
        let document = try await h.ingest("note.txt", text: "Remember the milk")
        #expect(document.labels == [] && document.status == .filed, "labelled with nothing, which is not the same as not labelled")
        #expect(try await h.services.documents.unlabelled().isEmpty, "so it is not offered to be labelled again")
    }

    @Test func withoutAValidAnswerTheDocumentIsUnlabelledAndTheHistorySaysWhy() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let document = try await h.ingest("bill.txt", text: "EDP electricity July")
        let id = try #require(document.id)
        #expect(document.labels == nil, "no labels are guessed")
        #expect(try await h.services.documents.unlabelled() == [id], "so it can be labelled later")
        let events = try await h.services.history.events(limit: 20, docID: id)
        #expect(events.contains { $0.kind == .error && $0.summary == "Not read: the model gave no valid answer" }, "the history says why it was not read")
        #expect(!events.contains { $0.kind == .analysed }, "and records no reading")
    }

    @Test func readingAnUnlabelledDocumentAgainLabelsIt() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        var services = h.services
        services.analyzer = StubAnalyzer()
        let coordinator = IngestCoordinator(services: services)
        try await ReviewActions(services: services, coordinator: coordinator).retry(id)
        let queued = try await services.jobs.active()
        #expect(queued.map(\.state) == [.pending] && queued.first?.payload.content != nil,
                "it waits its turn with the text it arrived with, to be read again from it")
        await coordinator.drain()
        let read = try #require(try await services.documents.document(id: id))
        #expect(read.labels == StubAnalyzer.edpBill && read.status == .filed && read.analysis?.problems == [],
                "read again, it is labelled and filed with nothing left for the user")
        #expect(try await services.documents.unlabelled().isEmpty, "and it is no longer waiting for labels")
    }

    @Test func labelsAreSearchableKindByKind() async throws {
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: ["edp.txt": StubAnalyzer.edpBill, "meo.txt": Self.meoContract]))
        defer { h.env.cleanup() }
        var byName: [String: Int64] = [:]
        for name in ["edp.txt", "meo.txt"] { byName[name] = try await h.ingest(name, text: "A bill: \(name)").id }
        let search = h.search
        func found(_ query: String) async throws -> [Int64] { try await search.fullText(SearchQuery(text: query)).hits.map(\.id) }

        #expect(try await found("jurisdiction:portugal") == [byName["edp.txt"]], "a label is found under its kind")
        #expect(try await found("party:\"joão silva\"") == [byName["meo.txt"]], "a whole name as a phrase, accents or not")
        #expect(try await found("sender:edp") == [byName["edp.txt"]], "the sender is a label like any other")
        #expect(try await found("amount:54.21") == [byName["edp.txt"]], "an amount by its value")
        #expect(try await found("deadline:2026-07") == [byName["edp.txt"]], "dates are found by their start")
        #expect(try await found("object:912345678") == [byName["meo.txt"]], "an object by the number in it")
        #expect(try await found("language:portuguese") == [byName["edp.txt"]], "a language by its English name")
        #expect(try await found("language:es") == [byName["meo.txt"]], "and by its code")
        #expect(try await found("spain") == [byName["meo.txt"]], "a label is found without naming its kind too")
        #expect(try await found("party:portugal").isEmpty, "a kind matches only labels of that kind")
    }

    @Test func theFunnelShowsWhereDocumentsWereRead() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        try await h.ingest("bill.txt", text: "EDP electricity July")
        let funnel = try await StatsService(database: h.env.database, config: h.env.config.stats, time: h.env.time).funnel(days: 7)
        let step = try #require(funnel.steps.first { $0.id == "analysed" })
        #expect(step.reached == 1 && step.errors == 1, "a document the model could not read counts as an error at this step")
        let insights = try await StatsService(database: h.env.database, config: h.env.config.stats, time: h.env.time).insights()
        #expect(insights.labelled == 0 && insights.unlabelled == 1, "Statistics counts it as waiting for labels")
    }
}
