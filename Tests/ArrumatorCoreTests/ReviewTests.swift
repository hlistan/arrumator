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

    /// Changes the document's file as a new copy of it would: more bytes, so another size and modification time.
    private func change(_ document: DocumentRecord) throws {
        let handle = try FileHandle(forWritingTo: document.url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" and more".utf8))
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
        #expect(try await h.review.choices(for: filed) == DocumentChoices(actions: [.undo, .readAgain, .confirm, .remove], notFiled: false),
                "a filed document not confirmed yet is offered Looks Right, and to be read again, as from a terminal")
        try await h.review.confirm(id)
        try await h.review.confirm(id)
        let events = try await h.services.history.events(limit: 10, kinds: [.markedCorrect], docID: id)
        #expect(events.count == 1, "pressed twice, Looks Right records the confirmation once")
        let confirmed = try #require(try await h.services.documents.document(id: id))
        #expect(try await h.review.choices(for: confirmed) == DocumentChoices(actions: [.undo, .readAgain, .remove], notFiled: false, confirmed: events.first?.at),
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
        // Read again only once the file has changed, as a copy put in its place has (`readAgainRefusal`).
        try change(damaged)
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

    @Test func readingAgainCannotMendAnUnchangedDamagedFile() async throws {
        // The QA run of 15 October 2026 (C4-2): Read Again was accepted for a damaged file that had not changed.
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: [], problems: [DocumentAnalysis.Problem.corrupted]))
        defer { h.env.cleanup() }
        let damaged = try await h.ingest("94-corrupt.txt", text: "%PDF-1.4 broken")
        let id = try #require(damaged.id)
        let error = IngestError.cannotMend(id, name: damaged.filename, encrypted: false)
        await #expect(throws: error, "reading an unchanged damaged file again cannot mend it") { try await h.review.retry(id) }
        #expect(try await h.services.history.events(limit: 10, kinds: [.retry], docID: id).isEmpty, "and nothing is recorded of it")
        #expect(try await h.services.documents.document(id: id)?.status == damaged.status, "nor is its status changed")
        #expect(error.localizedDescription.contains("cannot mend it") && error.localizedDescription.contains("94-corrupt"),
                "the reason names the file and says what helps: \(error.localizedDescription)")
    }

    @Test(arguments: [DocumentAnalysis.Problem.encrypted, DocumentAnalysis.Problem.corrupted])
    func readAgainIsRefusedForAnUnchangedFileThatCannotBeReadAndSaidBeforeItIsAsked(problem: String) async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: [], problems: [problem]))
        defer { h.env.cleanup() }
        let document = try await h.ingest("locked.txt", text: "no way in")
        let id = try #require(document.id)
        let choices = try await h.review.choices(for: document)
        let refusal = IngestError.cannotMend(id, name: document.filename, encrypted: problem == DocumentAnalysis.Problem.encrypted)
        #expect(choices.actions.contains(.readAgain) && choices.readAgainRefusal == refusal,
                "the card lists Read Again and says why it cannot help, by the rule `retry` applies: \(String(describing: choices.readAgainRefusal))")
        await #expect(throws: refusal, "and `retry` throws that same refusal") { try await h.review.retry(id) }
    }

    @Test func aChangedFileIsReadAgain() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: [], problems: [DocumentAnalysis.Problem.corrupted]))
        defer { h.env.cleanup() }
        let document = try await h.ingest("94-corrupt.txt", text: "%PDF-1.4 broken")
        let id = try #require(document.id)
        try change(document)
        #expect(try await h.review.choices(for: document).readAgainRefusal == nil, "a copy put in its place can be read")
        try await h.review.retry(id)
        #expect(try await h.services.history.events(limit: 10, kinds: [.retry], docID: id).count == 1, "so it is queued, and recorded once")
    }

    @Test(arguments: [DocumentAnalysis.Problem.noAnswer, DocumentAnalysis.Problem.noText])
    func readAgainIsOfferedForOtherProblems(problem: String) async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: [], problems: [problem]))
        defer { h.env.cleanup() }
        let document = try await h.ingest("thin.txt", text: "almost nothing")
        let id = try #require(document.id)
        #expect(try await h.review.choices(for: document).readAgainRefusal == nil, "a better model may mend \(problem)")
        try await h.review.retry(id)
        #expect(try await h.services.history.events(limit: 10, kinds: [.retry], docID: id).count == 1, "so it is queued")
    }

    @Test func aDocumentWithNoRecordedFingerprintIsOffered() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: [], problems: [DocumentAnalysis.Problem.corrupted]))
        defer { h.env.cleanup() }
        let document = try await h.ingest("94-corrupt.txt", text: "%PDF-1.4 broken")
        let id = try #require(document.id)
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET inode = NULL, file_mtime = NULL WHERE id = ?", arguments: [id])
        }
        let taken = try #require(try await h.services.documents.document(id: id))
        #expect(taken.fingerprint == nil, "nothing says its file is unchanged, as for a document taken in from a record file")
        #expect(try await h.review.choices(for: taken).readAgainRefusal == nil, "so Read Again is offered")
        try await h.review.retry(id)
        #expect(try await h.services.history.events(limit: 10, kinds: [.retry], docID: id).count == 1, "and queues it")
    }

    @Test func readingUnlabelledDocumentsSkipsOneThatCannotBeMended() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil, problems: [DocumentAnalysis.Problem.corrupted]))
        defer { h.env.cleanup() }
        let same = try await h.ingest("same.txt", text: "%PDF-1.4 broken one")
        let changed = try await h.ingest("changed.txt", text: "%PDF-1.4 broken two")
        try change(changed)
        let queued = try await h.review.retryUnlabelled()
        #expect(queued == [try #require(changed.id)], "the changed file is read again and the unchanged one \(String(describing: same.id)) is left, without a failure")
    }

    @Test func readingEveryDocumentAgainStillQueuesIt() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: [], problems: [DocumentAnalysis.Problem.corrupted]))
        defer { h.env.cleanup() }
        let document = try await h.ingest("94-corrupt.txt", text: "%PDF-1.4 broken")
        let queued = try await h.review.retryAll()
        #expect(queued == [try #require(document.id)], "a better Arrumator still reaches it (docs/how-it-works.md)")
    }

    @Test func needsYouAndTheCardKnowWhetherAReadingOfADocumentIsQueued() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        func asked() async throws -> (set: Set<Int64>, card: Bool) {
            let document = try #require(try await h.services.documents.document(id: id))
            return (try await h.services.jobs.beingRead([id]), try await h.review.choices(for: document).readingQueued)
        }
        var state = try await asked()
        #expect(state.set.isEmpty && !state.card, "a document never read again has no reading queued")
        try await h.review.retry(id)
        state = try await asked()
        #expect(state.set == [id] && state.card, "Read Again queues one, for Needs You and the card alike")
        await h.coordinator.drain()
        state = try await asked()
        #expect(state.set.isEmpty && !state.card, "once the reading ends, with the document needing the user again, none is queued")
        try await h.review.retry(id)
        try await h.review.hold(id)
        state = try await asked()
        #expect(state.set.isEmpty && !state.card, "Leave for Later cancels the reading (`JobStore.cancelReadingAgain`), so none is queued")
        let other = try #require(try await h.ingest("receipt.txt", text: IngestTests.bill + " and a receipt").id)
        try await h.review.retry(other)
        #expect(try await h.services.jobs.beingRead([other]) == [other], "another document is queued to be read again")
        try await h.review.remove(other)
        #expect(try await h.services.jobs.beingRead([other]).isEmpty, "once it is removed it is in none: the reading goes with it")
        #expect(try await h.services.jobs.beingRead([999]).isEmpty, "an unknown number is in none, and is no error")
        #expect(try await h.services.jobs.beingRead([]).isEmpty, "nor is no number")
    }

    @Test func readingEveryDocumentAgainIsNotAReadingOfOneQueuedForIt() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        #expect(try await h.review.retryAll() == [id], "the document is queued with the rest of the archive")
        let document = try #require(try await h.services.documents.document(id: id))
        let queued = try await h.services.jobs.beingRead([id])
        let card = try await h.review.choices(for: document).readingQueued
        #expect(queued.isEmpty && !card,
                "work that gives way to every file is not a reading asked for this document: Read Again moves it ahead")
    }

    @Test func aClaimedReadingIsStillUnderWay() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        try await h.review.retry(id)
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET state = ? WHERE doc_id = ? AND kind = ?",
                           arguments: [JobState.analysing.rawValue, id, JobKind.reanalyse.rawValue])
        }
        #expect(try await h.services.jobs.beingRead([id]) == [id], "a reading a worker has taken up is under way, not only queued")
    }

    @Test func aReadingThatFailsAgainIsNoLongerQueued() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: [], problems: [DocumentAnalysis.Problem.corrupted]))
        defer { h.env.cleanup() }
        let document = try await h.ingest("94-corrupt.txt", text: "%PDF-1.4 broken")
        let id = try #require(document.id)
        try change(document)
        try await h.review.retry(id)
        #expect(try await h.services.jobs.beingRead([id]) == [id], "the changed file is queued")
        await h.coordinator.drain()
        let after = try #require(try await h.services.documents.document(id: id))
        let queued = try await h.services.jobs.beingRead([id])
        let card = try await h.review.choices(for: after).readingQueued
        #expect(queued.isEmpty && !card,
                "it was read within no time and found damaged again, so nothing is queued and no notice is due")
    }

    @Test func recognisedTextHasNothingToShowForADamagedFile() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: [], problems: [DocumentAnalysis.Problem.corrupted]))
        defer { h.env.cleanup() }
        let document = try await h.ingest("94-corrupt.txt", text: "")
        let choices = try await h.review.choices(for: document)
        #expect(choices.nothingToShow == NothingToShow(problems: [DocumentAnalysis.Problem.corrupted]),
                "no text and no interpretation: the button is dimmed with why, not opened on an empty page: \(String(describing: choices.nothingToShow))")
    }

    @Test func recognisedTextHasNothingToShowAndNoReasonForABlankFileNoProblemWasFoundIn() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let document = try await h.ingest("blank.txt", text: "   \n")
        #expect(try await h.review.choices(for: document).nothingToShow == NothingToShow(problems: []), "and with no problem to name, none is")
    }

    @Test func recognisedTextIsOfferedForTextWithoutAnInterpretation() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let document = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(document.id)
        #expect(try await h.services.documentText(id)?.hasSomethingToShow == true, "its text is there")
        #expect(try await h.review.choices(for: document).nothingToShow == nil, "so the text is offered, though the model said nothing of it")
    }

    @Test func recognisedTextIsOfferedForAnImageWithOnlyADescription() async throws {
        let h = try await Harness.make(extractor: DescribedImageExtractor())
        defer { h.env.cleanup() }
        let document = try await h.ingest("photo.txt", text: "")
        let id = try #require(document.id)
        let text = try #require(try await h.services.documentText(id))
        #expect(text.text.isEmpty && text.interpretation == nil && text.imageDescription == DescribedImageExtractor.description,
                "the picture has no text and no interpretation, only what the vision model saw: \(text)")
        #expect(try await h.review.choices(for: document).nothingToShow == nil, "and that is something to show")
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

/// Reads every file as an image the vision model described and no text was recognised in.
private struct DescribedImageExtractor: ContentExtracting {
    static let description = "A photograph of a letterbox"

    func extract(_ url: URL, sha256: String, context: ExtractionContext, trace: TraceContext) async throws -> ExtractedContent {
        var content = try await PlainTestExtractor().extract(url, sha256: sha256, context: context, trace: trace)
        content.visual = VisualSummary(imageKind: .photo, description: Self.description, visibleTextSummary: "", organisations: [], dates: [])
        return content
    }
}
