@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// What the search finds follows the index: a name the pipeline, the card or Finder gave, a label by hand, a document
/// filed or still being read. The proofs of the changes that have suites of their own: a document read again,
/// `ReadingAgainTests.aCopyHasItsOriginalFoundAsItWasUntilItIsFiledAndThenOnlyAsItIsReadNow`; one moved to the Trash,
/// `RemovingDocumentsTests.aRemovedDocumentsFileGoesToTheTrashAndNothingOfItIsLeftInTheIndexOrItsRecordFile`; one put
/// back, `PuttingBackDocumentsTests` ("its text is found again"); a query asked for twice,
/// `SearchTests.aQueryTwoSearchesAskForAtOnceIsKeptOnce`.
@Suite struct SearchIndexTests {
    static func found(_ h: Harness, _ query: String) async throws -> [Int64] {
        try await h.search.search(SearchQuery(text: query, meaning: .wordsOnly)).hits.map(\.id)
    }

    /// The pipeline names a document of its labels and title: that name is searched, the name the file came with is not.
    @Test func aDocumentIsFoundByTheNameThePipelineGaveItAndNotByTheNameItCameWith() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        let id = try #require(doc.id)
        #expect(try await Self.found(h, "julho") == [id], "found by a word only the name the pipeline gave it holds")
        #expect(try await Self.found(h, "bill") == [], "and not by the name the file came with")
    }

    /// The name a person gives on the card replaces the one before it in the index, through `ReviewActions`.
    @Test func aDocumentRenamedOnItsCardIsFoundByTheNewNameAndNotTheOldOne() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        let id = try #require(doc.id)
        #expect(try await Self.found(h, "julho") == [id], "found by the name the pipeline gave it")

        try await h.review.edit(id, fileName: "Electricity July", labels: nil)
        #expect(try await Self.found(h, "julho") == [], "no longer by the name it had")
        #expect(try await Self.found(h, "electricity") == [id], "by the name the card gave it")
        #expect(try await Self.found(h, "name:july") == [], "a field that is no column is a word")
    }

    /// The name Finder gives a document in the archive replaces the one before it in the index, through `ArchiveReconciler`.
    @Test func aDocumentRenamedInFinderIsFoundByTheNewNameAndNotTheOldOne() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        let id = try #require(doc.id)
        let named = try #require(try await h.services.documents.document(id: id))
        let renamed = h.env.archive.appendingPathComponent("Gas Agosto.txt").standardizedFileURL
        try FileManager.default.moveItem(at: named.url, to: renamed)
        try await ArchiveReconciler(services: h.services, coordinator: h.coordinator)
            .apply([.found(path: renamed.path), .gone(path: named.path)])
        #expect(try await Self.found(h, "agosto") == [id], "found by the name Finder gave it")
        #expect(try await Self.found(h, "julho") == [], "no longer by the name it had")
        #expect(try await Self.found(h, "Electricity July") == [id], "its text says electricity, which the name no longer does")
    }

    @Test func aNameWithSeparatorsOrInCyrillicIsFoundByItsWords() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "kilowatt").id)
        try await h.review.edit(id, fileName: "Invoice/2026:07 notes", labels: nil)
        let written = try #require(try await h.services.documents.document(id: id)).filename
        for word in ["invoice", "2026", "notes"] {
            #expect(try await Self.found(h, word) == [id], "a name the user wrote with / and : is found by each of its words, \(word), as it is kept: \(written)")
        }
        try await h.review.edit(id, fileName: "Счёт за свет", labels: nil)
        #expect(try await Self.found(h, "счет") == [id], "a Cyrillic name is found with е for ё")
        #expect(try await Self.found(h, "notes") == [], "and the name it had is gone")
    }

    @Test func theExtensionOfAFileNameIsAWordOfItsName() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "kilowatt").id)
        try await h.review.edit(id, fileName: "Electricity", labels: nil)
        let byExtension = try await Self.found(h, "txt")
        #expect(byExtension == [id], "the full-text index keeps the name with its extension, so the extension finds every file of its kind: \(byExtension)")
    }

    @Test func aDocumentFiledAfterASearchIsFoundByTheNext() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        #expect(try await Self.found(h, "kilowatt") == [], "nothing is found before it is filed")
        let id = try #require(try await h.ingest("bill.txt", text: "kilowatt hours").id)
        #expect(try await Self.found(h, "kilowatt") == [id], "the next search finds it")
    }

    @Test func aLabelAddedOrTakenOffOnTheCardIsFoundOrNotAtOnce() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "kilowatt hours").id)
        let tag = DocumentLabel(kind: .tag, value: "Zebra")
        #expect(try await Self.found(h, "zebra") == [], "before it is added")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [tag]))
        #expect(try await Self.found(h, "zebra") == [id], "found at once by its value")
        #expect(try await Self.found(h, "tag:zebra") == [id], "and by its kind")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(removing: [tag]))
        #expect(try await Self.found(h, "zebra") == [], "and not once it is taken off")
    }

    @Test func aDocumentReadInForTheFirstTimeIsFoundByWhatTheIndexHoldsWithItsStatus() async throws {
        let reading = Hold()
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let analyzer = StubAnalyzer(labels: [DocumentLabel(kind: .sender, value: "Zebra")], during: { _ in await reading.arrive() })
        let h = Harness(env: env, services: Harness.services(env, analyzer: analyzer, config: env.config))
        await h.coordinator.enqueue(try env.drop("kilowatt notes.txt", text: "kilowatt hours"))
        let worker = Task { await h.coordinator.drain() }
        #expect(await Patience.until { reading.arrivals == 1 }, "the model is reading the document")
        let held = try await h.search.search(SearchQuery(text: "kilowatt", meaning: .wordsOnly))
        #expect(held.hits.map(\.document.status) == [.processing], "found by what the index holds of it, with its status: \(held.hits.map(\.id))")
        #expect(try await Self.found(h, "zebra") == [], "and by nothing it does not hold yet: the label it will be given")
        reading.open()
        _ = await worker.value
        #expect(try await Self.found(h, "zebra").count == 1, "once read, by that too")
    }

    @Test func aSearchWritesNothingAndLogsNoQuery() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "kilowatt hours").id)
        let statements = Mutex<[String]>([])
        try await h.env.database.writer.write { db in
            db.trace { event in statements.withLock { $0.append(event.description) } }
        }
        let vectors = VectorIndex()
        await vectors.load(model: SearchTests.FixedEmbedder.model, rows: [(id, [1, 0])])
        let events = try await h.services.history.events(limit: 100, kinds: nil, docID: nil)
        let search = SearchService(database: h.env.database, vectors: vectors, embedder: SearchTests.FixedEmbedder(vector: [1, 0]),
                                   config: h.env.config.search, time: h.env.time)
        for mode in [SearchMeaning.wordsOnly, .askOnce] {
            let results = try await search.search(SearchQuery(text: "kilowatt", meaning: mode))
            #expect(results.hits.map(\.id) == [id], "\(mode) finds it")
        }
        // SQLite also traces its own transaction, pragma and index-page lines; what writes starts with one of these verbs.
        let writes = ["INSERT", "UPDATE", "DELETE", "REPLACE", "CREATE", "DROP", "ALTER"]
        let run = statements.withLock { $0 }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(run.contains { $0.hasPrefix("SELECT d.*, bm25(") }, "the searches' queries were traced: \(run.count) statements")
        #expect(run.filter { statement in writes.contains { statement.uppercased().hasPrefix($0) } }.isEmpty, "no statement a search runs writes")
        #expect(try await h.services.history.events(limit: 100, kinds: nil, docID: nil) == events, "and History is as it was")
    }

    /// A document read again has its text written to the index after the History event that began it, and records nothing
    /// then: the results of a search follow the index itself, not History (`AppDatabase.indexChanges`, `activity`).
    @Test func theIndexSaysItChangedWhenATextIsWrittenThoughHistoryRecordsNothing() async throws {
        let db = try AppDatabase.inMemory()
        let changes = await Collected.reading(db.indexChanges())
        defer { Task { await changes.stop() } }
        let id = try await SearchTests().insert(db, title: "Meter", body: "kilowatt hours", sender: "EDP")
        // The stream gives the rows it counts (the document and its text), each write a value; the writes of the setup may arrive as
        // one, so it is the last value that says both are seen, never how many values came.
        #expect(await Patience.until { await changes.all.last == 2 }, "the stream has seen both writes of the setup, the document and its text")
        let (before, eventsBefore) = (await changes.all.count, try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM events") })
        try await IndexStore(database: db, time: TestTime(.advances)).upsertText(docID: id, filename: "Meter.pdf", body: "gas cubic metres", summary: nil,
                                                                                 metadata: [:], extractorVersion: "t", labels: [])
        #expect(await Patience.until { await changes.all.count > before }, "a text written alone is a change")
        #expect(try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM events") } == eventsBefore, "which History recorded nothing of")
    }

    @Test func aSearchLogsHowLongAndHowManyAndNeverWhatWasLookedFor() {
        let fields = SearchService.logFields(elapsedMs: 12.4, words: 3, meaning: 2, without: .ollamaAway)
        #expect(fields == ["ms": "12", "fts": "3", "semantic": "2", "without": "ollamaAway"], "the fields a search logs: \(fields)")
        #expect(SearchService.logFields(elapsedMs: 0, words: 0, meaning: 0, without: nil)["without"] == "", "none when meaning was used")
    }
}
