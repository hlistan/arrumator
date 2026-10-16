@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// A label the user gives a document by hand, of any kind, is the user's own, as a tag is (`DocumentRecord.byHand`):
/// reading the document again, for Read Again or for an exact copy of it put into Incoming, replaces what the model gave
/// it and never takes the place of what the user gave (`IndexStore.kept`).
@Suite struct LabelsByHandTests {
    static let bill = "EDP electricity July"
    static let household = DocumentLabel(kind: .topic, value: "household")
    static let edp = DocumentLabel(kind: .sender, value: "EDP")
    static let receipt = DocumentLabel(kind: .type, value: "receipt")
    static let firstOfJuly = DocumentLabel(kind: .date, value: "2026-07-01")

    /// What has a document of the archive read again.
    enum ReadingAgain: CaseIterable {
        /// **Read Again** on its card (`review retry`), which reads it where it is and then replaces what it had
        /// (`IndexStore.replaceReading`).
        case readAgain
        /// An exact copy of it put at the top of Incoming.
        case copyInIncoming
        /// An exact copy of it put into a folder in Incoming, which gives it the folder's tag before it is read
        /// (`IndexStore.addLabels`).
        case copyInAFolder
        /// **Read Again** once its filing was undone, which reads it as a file that arrives (`IndexStore.saveReading`).
        case readAgainAfterUndo

        /// The tags it has once read again, besides its own.
        var tags: [DocumentLabel] { self == .copyInAFolder ? [TagTests.tag] : [] }
    }

    /// Has document `id` read again, as `how` says, by a model that reads what `analyzer` gives; the pipeline it was read
    /// by.
    static func read(_ id: Int64, _ how: ReadingAgain, in h: Harness, analyzer: StubAnalyzer) async throws -> PipelineServices {
        var services = h.services
        services.analyzer = analyzer
        let coordinator = IngestCoordinator(services: services)
        let review = ReviewActions(services: services, coordinator: coordinator)
        switch how {
        case .readAgain: try await review.retry(id)
        case .copyInIncoming: await coordinator.enqueue(try h.env.drop("bill copy.txt", text: Self.bill))
        case .copyInAFolder: await coordinator.enqueue(try h.env.drop("\(TagTests.folder)/bill copy.txt", text: Self.bill))
        case .readAgainAfterUndo:
            try await review.undo(id)
            try await review.retry(id)
        }
        await coordinator.drain()
        return services
    }

    // MARK: Reading again

    @Test(arguments: ReadingAgain.allCases)
    func aLabelGivenByHandStaysWhenTheDocumentIsReadAgainAndOnlyTheModelsAreReplaced(how: ReadingAgain) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: Self.bill).id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.household, Self.edp, TagTests.mine]))
        let given = try #require(try await h.services.documents.document(id: id))
        #expect(given.byHand == [Self.household, Self.edp] && given.yours == [Self.household, Self.edp, TagTests.mine],
                "a label added by hand of a kind the model gives is the user's own, beside the tag, which is by its kind")
        #expect(given.labels(readAs: LabelingTests.meoContract) == LabelingTests.meoContract + [Self.household, Self.edp, TagTests.mine],
                "what a reading would leave it, as a replay shows it")
        h.env.time.advance(by: 60)

        let services = try await Self.read(id, how, in: h, analyzer: StubAnalyzer(labels: LabelingTests.meoContract, title: Harness.otherTitle))
        let read = try #require(try await services.documents.document(id: id))
        #expect(read.labels == LabelingTests.meoContract + [Self.household, Self.edp, TagTests.mine] + how.tags,
                "read again, what the model gave before is replaced by what it reads now, and every label given by hand stays")
        #expect(read.byHand == [Self.household, Self.edp], "still the user's own, to stay at the next reading too")
        #expect(read.filename == "EDP - \(Harness.otherTitle).txt",
                "named by the sender given by hand before the model's, as the labels the document keeps: \(read.filename)")
        let found = try await services.documents.list(DocumentFilter(labels: [Self.household]), limit: 5).map(\.id)
        #expect(found == [id], "and found by it")
        let event = try #require(try await services.history.events(limit: 5, kinds: [.analysed], docID: id).first)
        let kept = ([TagTests.mine] + how.tags).map { "“\($0.value)”" }.joined(separator: ", ")
        #expect(event.summary == LabelingTests.meoContract.map { $0.shown(locale: TestTime.locale) }.joined(separator: " · ")
                    + "; keeps its \(how.tags.isEmpty ? "tag" : "tags") \(kept)",
                "History says what the model gave, which the labels given by hand are not: \(event.summary)")
    }

    @Test func aLabelGivenByHandOfAKindADocumentHasOneOfTakesThePlaceOfTheModels() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: Self.bill).id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.receipt, Self.firstOfJuly]))
        h.env.time.advance(by: 60)
        let services = try await Self.read(id, .readAgain, in: h, analyzer: StubAnalyzer())
        let read = try #require(try await services.documents.document(id: id))
        #expect(read.labels == StubAnalyzer.edpBill.filter { !$0.kind.isSingle } + [Self.receipt, Self.firstOfJuly],
                "a document keeps one type and one date: those given by hand, never the model's in their place")
        #expect(read.filename == "2026-07-01 EDP Comercial - \(StubAnalyzer.edpTitle).txt",
                "named by the date given by hand, which the document has, not the model's: \(read.filename)")
    }

    @Test func aLabelTakenOffRenamedOrRemovedEverywhereIsAsTheUserLeftIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: Self.bill).id)
        let party = DocumentLabel(kind: .party, value: "Ana Exemplo")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.household, Self.edp, party]))
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(removing: [Self.household]))
        _ = try await h.labels.rename(Self.edp, to: "EDP Energia")
        _ = try await h.labels.remove(party)
        let energia = DocumentLabel(kind: .sender, value: "EDP Energia")
        let changed = try #require(try await h.services.documents.document(id: id))
        #expect(changed.byHand == [energia],
                "one taken off is no longer given by hand, one renamed is under its new writing, one removed everywhere goes")
        h.env.time.advance(by: 60)

        let services = try await Self.read(id, .readAgain, in: h, analyzer: StubAnalyzer(labels: LabelingTests.meoContract, title: Harness.otherTitle))
        let read = try #require(try await services.documents.document(id: id))
        #expect(read.labels == LabelingTests.meoContract + [energia], "read again, it keeps only what the user left it")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(removing: [energia]))
        let cleared = try #require(try await services.documents.document(id: id))
        #expect(cleared.byHandJson == nil && cleared.labels == LabelingTests.meoContract,
                "with no label given by hand left, it holds none, as before any was given")
    }

    @Test func aCorrectionGivesByHandOnlyWhatItAddsOfAKindTheModelGives() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: Self.bill).id)
        let sender = try #require(StubAnalyzer.edpBill.first { $0.kind == .sender })
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [sender, DocumentLabel(kind: .sender, value: "edp comercial")]))
        let unchanged = try #require(try await h.services.documents.document(id: id))
        let corrections = try await h.services.history.events(limit: 5, kinds: [.corrected], docID: id)
        #expect(unchanged.byHandJson == nil && corrections.isEmpty,
                "a label the document has, however cased, added again changes nothing, and is not given by hand")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.receipt, TagTests.mine]))
        let corrected = try #require(try await h.services.documents.document(id: id))
        #expect(corrected.byHand == [Self.receipt] && corrected.labels?.values(.type) == ["receipt"],
                "a type given by hand takes the model's place and is given by hand; a tag is the user's by its kind, not listed")
    }

    @Test func aReadingTakenBackKeepsTheLabelsGivenByHand() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: Self.bill).id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.household, TagTests.mine]))
        try await h.services.index.forgetReading(docID: id)
        let taken = try #require(try await h.services.documents.document(id: id))
        #expect(taken.labels == [Self.household, TagTests.mine] && taken.byHand == [Self.household],
                "as when its file changed and it arrives again: what the model gave goes, the user's own stay")
        #expect(taken.isLabelled, "a label of a kind the model gives, given by hand, labels it, as a correction does")
    }

    // MARK: The rule

    @Test func whatAReadingLeavesKeepsTheUsersOwnConditionByCondition() {
        let model = DocumentLabel(kind: .sender, value: "EDP Comercial")
        let date = DocumentLabel(kind: .date, value: "2026-07-05")
        let current = [model, Self.edp, date, TagTests.mine]
        func kept(_ read: [DocumentLabel], byHand: [DocumentLabel], before: [DocumentLabel] = current) -> [DocumentLabel] {
            IndexStore.kept(read, before: before, current: current, byHand: byHand)
        }
        let meo = DocumentLabel(kind: .sender, value: "MEO")
        #expect(kept([meo], byHand: [Self.edp]) == [meo, Self.edp, TagTests.mine],
                "a label given by hand stays though the reading gives none of it, and the tag stays by its kind")
        #expect(kept([meo], byHand: []) == [meo, TagTests.mine], "one the model gave is replaced by what it reads now")
        #expect(kept([DocumentLabel(kind: .sender, value: "edp"), meo], byHand: [Self.edp]) == [meo, Self.edp, TagTests.mine],
                "a reading giving one given by hand, however cased, leaves it as the user wrote it")
        let other = DocumentLabel(kind: .date, value: "2026-08-01")
        #expect(kept([meo, other], byHand: [date]) == [meo, date, TagTests.mine],
                "of a kind a document has one of, the one given by hand stays and the model's is left out")
        #expect(kept([meo, other], byHand: []) == [meo, other, TagTests.mine], "while the model's own date is replaced")
        #expect(kept([meo, model], byHand: [Self.edp]) == [meo, model, Self.edp, TagTests.mine],
                "of a kind a document has several of, the model's stand beside one given by hand")
        #expect(kept([meo], byHand: [], before: [model, date, TagTests.mine]) == [model, Self.edp, TagTests.mine],
                "and a kind the user changed while it was read stays as the user left it, as before")
    }

    // MARK: The record files

    @Test func theLabelsGivenByHandAreInTheRecordAndARebuildKeepsThem() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: Self.bill).id)
        let record = h.env.archive.appendingPathComponent(h.env.config.records.documentsFileName)
        try await h.env.records().flush()
        #expect(try !String(contentsOf: record, encoding: .utf8).contains("by_hand"), "an entry with none given by hand writes none")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.household]))
        try await h.env.records().flush()
        let text = try String(contentsOf: record, encoding: .utf8)
        #expect(text.contains("by_hand:\n  - kind: topic\n    value: household"), "the entry says which labels were given by hand:\n\(text)")

        let database = try AppDatabase.inMemory()
        try await h.env.records(index: database).rebuild()
        let back = try #require(try await DocumentStore(database: database, time: TestTime(.advances)).document(id: id))
        #expect(back.byHand == [Self.household] && back.labels == StubAnalyzer.edpBill + [Self.household],
                "a rebuild brings them back as given by hand, to stay when it is read again")
    }

    @Test func anEntrysLabelsGivenByHandAreOnlyThoseOfItsLabelsOfKindsTheModelGives() throws {
        // An entry edited by hand: its list of labels given by hand names one it no longer has, and a tag.
        let text = """
            ---
            arrumator: 1
            entries:
            - id: 7
              uid: 5B7A8F4E-0000-0000-0000-000000000007
              file: bill.pdf
              original_name: bill.pdf
              added: 2026-07-05T10:00:00Z
              status: filed
              labels:
              - kind: sender
                value: EDP
              - kind: tag
                value: Mine
              by_hand:
              - kind: sender
                value: EDP
              - kind: topic
                value: household
              - kind: tag
                value: Mine
              content_type: com.adobe.pdf
              size: 3
              sha256: abc
            ---
            """
        let parsed = try ParsedRecords(.documents(directory: "/archive"), url: URL(fileURLWithPath: "/archive/_documents.md"), text: text)
        let entry = try #require(parsed.documents.first?.entries.first)
        let record = try entry.record(directory: URL(fileURLWithPath: "/archive"), now: Date(timeIntervalSince1970: 0))
        #expect(record.byHand == [Self.edp],
                "one edited out of its labels is not the document's, and a tag is the user's own by its kind, not listed")
    }
}
