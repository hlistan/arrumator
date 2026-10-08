@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What the user does with a document from its card, and what History says of it (the QA run of 4 October 2026): an
/// undo applies only to a document in the archive, a confirmation is recorded once and shown, and what a reading did
/// is said as it happened.
@Suite struct ReviewTests {
    /// The `from` and `to` an event's payload keeps.
    private func paths(_ event: EventRecord?) -> [String: String] {
        JSON.decode([String: String].self, from: event?.payloadJson) ?? [:]
    }

    @Test func aDocumentAlreadyUndoneIsNotUndoneAgainAndItsFileKeepsItsName() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        try await h.review.undo(id)
        let undone = try #require(try await h.services.documents.document(id: id))
        await #expect(throws: IngestError.notInArchive(id, .undo), "only a document in the archive is undone") {
            try await h.review.undo(id)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.env.incoming.path) == ["bill.txt"],
                "its file stays in Incoming under its name, never renamed as if it collided with itself")
        #expect(try await h.services.documents.document(id: id) == undone, "and the index is as it was")
        #expect(try await h.services.history.events(limit: 10, kinds: [.undone], docID: id).count == 1, "History has the one undo")
    }

    @Test func anUndoRecordsWhereTheFileWasAndWentAsTheDiskSpellsBoth() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        // The archive is named as the settings name it, here as the temporary folder's path, which the disk spells under
        // /private, as it spells Incoming.
        let filedOnDisk = doc.url.spelledOnDisk.path
        try await h.review.undo(id)
        let event = try await h.services.history.events(limit: 1, kinds: [.undone], docID: id).first
        let undone = try #require(try await h.services.documents.document(id: id))
        #expect(paths(event) == ["from": filedOnDisk, "to": undone.path],
                "both paths are in the one spelling the disk gives, so they read alike: \(paths(event))")
        #expect(event?.summary == "\(filedOnDisk) → Incoming", "and so is the summary")
    }

    @Test func lookingRightTwiceRecordsOneConfirmationAndTheCardSaysItWasConfirmed() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let filed = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(filed.id)
        #expect(try await h.review.choices(for: filed) == DocumentChoices(actions: [.undo, .confirm, .remove], notFiled: false),
                "a filed document not confirmed yet is offered Looks Right")
        try await h.review.confirm(id)
        try await h.review.confirm(id)
        let events = try await h.services.history.events(limit: 10, kinds: [.markedCorrect], docID: id)
        #expect(events.count == 1, "pressed twice, Looks Right records the confirmation once")
        let confirmed = try #require(try await h.services.documents.document(id: id))
        #expect(try await h.review.choices(for: confirmed) == DocumentChoices(actions: [.undo, .remove], notFiled: false, confirmed: events.first?.at),
                "its card says when it was confirmed, and no longer offers to confirm it")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [DocumentLabel(kind: .topic, value: "utilities")]))
        let corrected = try #require(try await h.services.documents.document(id: id))
        #expect(try await h.review.choices(for: corrected).confirmed == nil, "a correction after it is no longer what was confirmed")
        try await h.review.confirm(id)
        #expect(try await h.services.history.events(limit: 10, kinds: [.markedCorrect], docID: id).count == 2,
                "so confirming it then is recorded again")
    }

    @Test(arguments: [EventKind.userRenamed, .userMoved, .missing, .adopted])
    func aConfirmationIsOfTheDocumentAsItWasNotAsItIsAfterItsNameOrPlaceChanged(_ change: EventKind) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        try await h.review.confirm(id)
        #expect(try await h.review.choices(for: try #require(try await h.services.documents.document(id: id))).confirmed != nil, "confirmed")
        // What the archive's reconciler records when the file is renamed or moved in Finder, goes, or comes back.
        _ = try await h.services.history.record(change, doc: id, summary: "bill.txt changed in Finder")
        let changed = try #require(try await h.services.documents.document(id: id))
        #expect(try await h.review.choices(for: changed).confirmed == nil,
                "after \(change.rawValue) the card no longer says the document as it is was confirmed")
    }

    @Test func aDocumentReadAgainForACopyIsRecordedAsRenamedFromTheNameItHadNotTheOneItArrivedUnder() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let filed = try await h.ingest("01-edp-fatura.txt", text: IngestTests.bill)
        let id = try #require(filed.id)
        let other = h.readingOtherwise()
        let copy = try h.env.drop("01-edp-fatura copy.txt", text: IngestTests.bill)
        await other.coordinator.enqueue(copy)
        await other.coordinator.drain()
        let event = try await h.services.history.events(limit: 1, kinds: [.filed], docID: id).first
        #expect(event?.summary == "\(filed.filename) → \(Harness.otherFileName).txt",
                "renamed where it is from the name it had, never the one it arrived under weeks before: \(event?.summary ?? "none")")
    }

    @Test func aDamagedFileReadAgainIsSaidToWaitForTheUserNeverToHaveMovedOrHadNothingWorthALabel() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: [], problems: [DocumentAnalysis.Problem.corrupted]))
        defer { h.env.cleanup() }
        let damaged = try await h.ingest("94-corrupt.txt", text: "%PDF-1.4 broken")
        let id = try #require(damaged.id)
        try await h.review.retry(id)
        await h.coordinator.drain()
        let analysed = try await h.services.history.events(limit: 1, kinds: [.analysed], docID: id).first
        #expect(analysed?.summary == "Nothing could be read of it; waits for you: the file is damaged",
                "the reading says nothing could be read of it and why it waits, not that it had nothing worth a label")
        let waits = try await h.services.history.events(limit: 1, kinds: [.needsReview], docID: id).first
        #expect(waits?.summary == "94-corrupt.txt waits for you: the file is damaged",
                "and its filing says it waits where it is, not that it moved to where it was: \(waits?.summary ?? "none")")
        let read = try #require(try await h.services.documents.document(id: id))
        let traceID = try #require(read.lastTraceId)
        let (_, steps) = try #require(try await h.services.traces.trace(id: traceID))
        let review = steps.filter { $0.stage == TraceStage.review.rawValue }
        #expect(review.count == 1 && review.first?.status == .warn && review.first?.error?.contains("the file is damaged") == true,
                "its trace has a step that says why it waits, so not every step reads ok")
    }

    @Test func needsYouCountsOnlyWhatWaitsForTheUserAndListsWhatTheUserSetAsideApart() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let undone = try #require(try await h.ingest("a.txt", text: "first").id)
        let held = try #require(try await h.ingest("b.txt", text: "second").id)
        let waiting = try #require(try await h.ingest("c.txt", text: "third").id)
        #expect(try await h.services.documents.waitingCount() == 3, "three the model could not read wait for the user")
        try await h.review.undo(undone)
        try await h.review.hold(held)
        #expect(try await h.services.documents.waitingCount() == 1,
                "one the user undid and one left for later wait for nothing: only the third is counted")
        let listed = try await h.services.documents.needsYou()
        #expect(listed.waiting.map(\.id) == [waiting] && listed.setAside.map(\.id) == [held, undone],
                "Needs You lists what waits for the user, and apart from it what the user set aside, the latest first")
    }
}
