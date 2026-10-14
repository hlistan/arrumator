@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// The user puts back a document they removed: its file comes back from the Trash and the document into the index and its
/// record file, as it was (`ReviewActions.putBack`).
@Suite struct PuttingBackDocumentsTests {
    static let handSender = DocumentLabel(kind: .sender, value: "Hand Given Sender")
    static let tag = DocumentLabel(kind: .tag, value: "keep-this-tag")

    /// A pipeline that reads every document with an interpretation, and one document in the archive with a tag and a sender
    /// given by hand, set to `status`, with its record files written.
    static func world(status: DocumentStatus = .filed) async throws -> (h: Harness, doc: DocumentRecord, records: ArchiveRecords, analyzer: StubAnalyzer) {
        let analyzer = StubAnalyzer(interpretation: StubAnalyzer.edpInterpretation)
        let h = try await Harness.make(analyzer: analyzer)
        // Search by meaning made ready, as the runtime makes it when it opens the archive.
        await h.services.vectors.load(model: StubAnalyzer.embeddingModel, rows: [])
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [tag, handSender]))
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
        let records = h.env.records()
        try await records.flush()
        return (h, try #require(try await h.services.documents.document(id: id)), records, analyzer)
    }

    static func events(_ h: Harness, _ kind: EventKind) async throws -> [EventRecord] {
        try await h.services.history.events(limit: 20, kinds: [kind])
    }

    /// The latest removal History holds, and what it recorded.
    static func removal(_ h: Harness) async throws -> (event: EventRecord, payload: RemovedPayload) {
        let event = try #require(try await events(h, .documentRemoved).first)
        return (event, try #require(JSON.decode(RemovedPayload.self, from: event.payloadJson)))
    }

    /// Rewrites what the removal `event` recorded, as a person editing History's record file, or a release before this one,
    /// would have left it; the event as it is read then.
    @discardableResult
    static func rewrite(_ h: Harness, _ event: EventRecord, _ change: @Sendable (inout RemovedPayload) -> Void) async throws -> EventRecord {
        var payload = try #require(JSON.decode(RemovedPayload.self, from: event.payloadJson))
        change(&payload)
        let json = try JSON.string(payload)
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE events SET payload_json = ? WHERE id = ?", arguments: [json, event.id])
        }
        return try #require(try await events(h, .documentRemoved).first(where: { $0.id == event.id }))
    }

    @Test(arguments: [DocumentStatus.filed, .needsReview])
    func aFiledDocumentComesBackAsItWas(_ status: DocumentStatus) async throws {
        let (h, doc, records, analyzer) = try await Self.world(status: status)
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        #expect(doc.analysis?.interpretation == StubAnalyzer.edpInterpretation && doc.byHand == [Self.handSender],
                "the document has an interpretation and a label given by hand")
        let readBefore = await analyzer.calls.files.count
        try await h.review.remove(id)
        let (removal, removed) = try await Self.removal(h)
        let trashed = try #require(removed.trashed)

        let back = try await h.review.putBack(id)
        #expect(back == PutBackPayload(removal: try #require(removal.id), document: id, removedAs: nil, from: trashed, to: removed.from, copied: nil),
                "it says where the file was in the Trash and where it went, as the disk spells them")
        let file = URL(fileURLWithPath: removed.from)
        #expect(FileManager.default.fileExists(atPath: file.path) && h.env.trashed().isEmpty, "its file is where it was, no longer in the Trash")
        #expect(Xattr.get(Xattr.documentID, from: file) == doc.uid && Xattr.get(Xattr.originalName, from: file) == doc.originalFilename,
                "carrying its identifier and its original name")

        let again = try #require(try await h.services.documents.document(id: id))
        #expect(again.uid == doc.uid && again.filename == doc.filename && again.originalFilename == doc.originalFilename
                    && again.sha256 == doc.sha256 && again.size == doc.size && again.status == status,
                "the same number, identity, name, checksum and status")
        #expect(again.labels == doc.labels && again.byHand == doc.byHand && again.tagsOnly == doc.tagsOnly && again.analysis == doc.analysis
                    && again.addedAt == doc.addedAt && again.filedAt == doc.filedAt,
                "its labels, those given by hand still the user's own, its reading, and its times")

        let puts = try await Self.events(h, .documentPutBack)
        let event = try #require(puts.first)
        #expect(puts.count == 1 && event.actor == .user && event.docId == id && event.summary == "Put back “\(doc.filename)” from the Trash",
                "exactly one event, the user's, for this document, naming its file")
        #expect(JSON.decode(PutBackPayload.self, from: event.payloadJson) == back, "with the payload the action returned")
        let (adopted, arrived) = (try await Self.events(h, .adopted), try await Self.events(h, .arrived))
        #expect(adopted.isEmpty && arrived.count == 1, "no adopted event, and no arrival beside the first one")
        #expect(try await h.services.jobs.active(kinds: [.ingest, .adopt]).isEmpty,
                "no ingest or adopt job")

        await h.coordinator.drain(.everything)
        #expect(await analyzer.calls.files.count == readBefore, "the model was not asked to read it again")
        #expect(try await h.search.fullText(SearchQuery(text: "electricity")).hits.map(\.id).contains(id), "its text is found again")
        #expect(try await h.search.fullText(SearchQuery(text: "Hand")).hits.map(\.id).contains(id), "and its labels")
        #expect(await h.foundByMeaning() == [id], "its embedding is back in the vector index")
        try await records.flush()
        #expect(try String(contentsOf: h.env.archive.appendingPathComponent(h.env.config.records.documentsFileName), encoding: .utf8)
                    .contains("file: \(doc.filename)"), "its folder's record file lists it again")
        let sidecar = try #require(h.env.layout.sidecar(of: again.path))
        #expect(FileManager.default.fileExists(atPath: sidecar.path), "and its sidecar is beside it")
        let waiting = try await h.services.documents.needsYou().waiting.compactMap(\.id)
        #expect(waiting.contains(id) == (status == .needsReview), "it is in Needs You again if it waited there, and not otherwise")
        let processed = try await h.services.documents.list(DocumentFilter(statuses: DocumentStatus.processed), order: .recentlyProcessed, limit: 10).compactMap(\.id)
        #expect(processed.contains(id), "and in Processed, where a filed document and one waiting for you both are listed")

        try await h.reconciler.apply([.found(path: again.path)])
        let adoptedAfter = try await Self.events(h, .adopted)
        #expect(try await h.services.documents.document(id: id)?.uid == doc.uid && adoptedAfter.isEmpty
                    && Xattr.get(Xattr.documentID, from: file) == doc.uid,
                "the archive watcher keeps it as this document, never adopts it nor strips its identifier")
    }

    /// Where an archive file lost its identifier, as a copy or a synchronisation leaves one.
    enum IdentifierLost: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case beforeTheRemoval, inTheTrash
        var testDescription: String { rawValue }
    }

    /// The removal and the put-back take the same file as the document's: one with no identifier is known by its size and
    /// checksum, so a document the app removed from the archive can be put back, and the listing does not refuse it.
    @Test(arguments: IdentifierLost.allCases)
    func aFileWithoutAnIdentifierIsTakenAsTheDocumentsByTheRemovalAndThePutBackAlike(_ lost: IdentifierLost) async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        if lost == .beforeTheRemoval { try Xattr.remove(Xattr.documentID, from: doc.url) }
        try await h.review.remove(id)
        let (event, removed) = try await Self.removal(h)
        let trashed = try #require(removed.trashed, "the removal took the file for the document's")
        if lost == .inTheTrash { try Xattr.remove(Xattr.documentID, from: URL(fileURLWithPath: trashed)) }
        #expect(Xattr.get(Xattr.documentID, from: URL(fileURLWithPath: trashed)) == nil, "the file in the Trash carries no identifier")
        #expect(try await h.review.putBackRefusals(of: [event]).isEmpty, "the listing does not refuse it")

        let back = try await h.review.putBack(id)
        #expect(back.to == removed.from && FileManager.default.fileExists(atPath: removed.from) && h.env.trashed().isEmpty,
                "its file is back where it was, out of the Trash")
        #expect(try await h.services.documents.document(id: id)?.uid == doc.uid, "as the same document")
    }

    /// The ways a document is in Incoming, not filed.
    enum InIncoming: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case undone, held, failed
        var testDescription: String { rawValue }
    }

    /// A document in Incoming that is `kind`, and the pipeline that moves files as the disk does.
    private func inIncoming(_ kind: InIncoming) async throws -> (h: Harness, doc: DocumentRecord) {
        switch kind {
        case .undone, .held:
            let h = try await Harness.make()
            let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
            try await h.review.undo(id)
            if kind == .held { try await h.review.hold(id) }
            return (h, try #require(try await h.services.documents.document(id: id)))
        case .failed:
            // Filed by a pipeline whose Trash refuses and whose every move crosses a volume, so it is left in Incoming.
            let base = try await Harness.make()
            var config = base.env.config
            config.ingest.retryDelays = NonEmpty(0, [])
            let left = Harness(env: base.env, services: Harness.services(base.env, analyzer: StubAnalyzer(), config: config,
                                                                         sameVolume: { _, _ in false }, trash: RefusingTrash()))
            let bill = try base.env.drop("bill.txt", text: IngestTests.bill)
            await left.coordinator.enqueue(bill)
            for _ in 0..<config.ingest.maxAttempts { await left.coordinator.drain() }
            let doc = try #require(try await base.services.documents.list(DocumentFilter(), limit: 10).first)
            return (base, doc)
        }
    }

    @Test(arguments: InIncoming.allCases)
    func aDocumentThatWasInIncomingComesBackToIncomingAndIsNotArrivingAgain(_ kind: InIncoming) async throws {
        let (h, doc) = try await inIncoming(kind)
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        let expected: DocumentStatus = kind == .failed ? .failed : (kind == .held ? .held : .undone)
        #expect(doc.status == expected && h.env.incoming.holds(doc.path), "the document is \(kind), in Incoming")
        try await h.review.remove(id)
        let back = try await h.review.putBack(id)
        let again = try #require(try await h.services.documents.document(id: id))
        #expect(again.status == expected && again.path == back.to && FileManager.default.fileExists(atPath: doc.path),
                "its file returns to Incoming, with the status it had")
        #expect(h.env.incoming.holds(again.path) && !h.env.archive.holds(again.path), "and it is in Incoming, not in the archive")
        let queued = await h.coordinator.enqueue(URL(fileURLWithPath: again.path))
        let arrived = try await Self.events(h, .arrived)
        let ingests = try await h.services.jobs.active(kinds: [.ingest, .adopt])
        #expect(queued == nil && ingests.isEmpty && arrived.count == 1,
                "a rescan of Incoming finds it as this document: no ingest job, no second arrival (\(arrived.count))")
    }
}

/// Where the file comes back to when its place is taken or gone, and under which number.
extension PuttingBackDocumentsTests {
    @Test func anotherFileAtItsPlaceIsLeftAndItComesBackBeside() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        try await h.review.remove(id)
        let from = URL(fileURLWithPath: try await Self.removal(h).payload.from)
        try Data("another file".utf8).write(to: from)
        let inode = try FileFingerprint.of(from).inode

        let back = try await h.review.putBack(id)
        #expect(back.to != from.path && URL(fileURLWithPath: back.to).deletingLastPathComponent().path == from.deletingLastPathComponent().path,
                "it comes back beside it, in the same folder, under a name of its own")
        #expect(try String(contentsOf: from, encoding: .utf8) == "another file" && (try FileFingerprint.of(from).inode) == inode,
                "the other file is not touched or moved")
        let again = try #require(try await h.services.documents.document(id: id))
        #expect(again.url.spelledOnDisk.path == back.to && again.filename == URL(fileURLWithPath: back.to).lastPathComponent,
                "the index gives the name it took")
        let event = try #require(try await Self.events(h, .documentPutBack).first)
        #expect(event.summary.contains("another file is at its place") && event.summary.contains(again.filename),
                "and History says why: \(event.summary)")
    }

    @Test func aRemovalRecordedWithAPlannedNameComesBackUnderIt() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        try await h.review.remove(id)
        let (event, removed) = try await Self.removal(h)
        // Removed while reading it again had planned its move: the place recorded is the planned one, with another name.
        let planned = URL(fileURLWithPath: removed.from).deletingLastPathComponent().appendingPathComponent("Planned name.txt")
        try await Self.rewrite(h, event) { $0.from = planned.path }

        let back = try await h.review.putBack(id)
        #expect(back.to == planned.spelledOnDisk.path, "it comes back under the name recorded")
        let put = try #require(try await Self.events(h, .documentPutBack).first)
        #expect(put.summary == "Put back “\(doc.filename)” from the Trash; it comes back as “Planned name.txt”, the name its file had when it was removed",
                "History says what happened, not a name its file in the Trash had: \(put.summary)")
    }

    @Test func itsFolderGoneItComesBackAtTheTopOfTheArchive() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let filed = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(filed.id)
        let moved = try h.moveIntoArchive(filed.url, to: "Taxes/\(filed.filename)")
        try await h.reconciler.apply([.found(path: moved.path), .gone(path: filed.path)])
        let doc = try #require(try await h.services.documents.document(id: id))
        #expect(doc.path == moved.path, "the document is filed in a folder of the archive")
        try await h.review.remove(id)
        try FileManager.default.removeItem(at: moved.deletingLastPathComponent())

        let back = try await h.review.putBack(id)
        let top = h.env.archive.appendingPathComponent(doc.filename).spelledOnDisk.path
        #expect(back.to == top, "it is at the top of the archive")
        #expect(!FileManager.default.fileExists(atPath: moved.deletingLastPathComponent().path), "the app made no folder")
        let event = try #require(try await Self.events(h, .documentPutBack).first)
        #expect(event.summary.contains("its folder is gone"), "History says why: \(event.summary)")
    }

    @Test func itsFolderInIncomingGoneItComesBackAtTheTopOfIncoming() async throws {
        let (h, doc) = try await inIncoming(.undone)
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        try await h.review.remove(id)
        // It was removed from a folder of Incoming, which is gone now (a record an earlier state of the folders left).
        let (event, removed) = try await Self.removal(h)
        let sub = h.env.incoming.appendingPathComponent("Sub", isDirectory: true)
        try await Self.rewrite(h, event) { $0.from = sub.appendingPathComponent(doc.filename).path }
        #expect(!FileManager.default.fileExists(atPath: sub.path) && removed.from != sub.path, "the folder is not there")

        let back = try await h.review.putBack(id)
        #expect(back.to == h.env.incoming.appendingPathComponent(doc.filename).spelledOnDisk.path, "it is at the top of Incoming: \(back.to)")
        #expect(!FileManager.default.fileExists(atPath: sub.path), "the app made no folder")
        let put = try #require(try await Self.events(h, .documentPutBack).first)
        #expect(put.summary.contains("its folder is gone, so it is at the top of \(h.env.incoming.lastPathComponent)"), "History says why: \(put.summary)")
    }

    @Test func itsNumberTakenItComesBackUnderANewOne() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let taken = try #require(w.documents.last)
        let doc = try #require(try await w.h.services.documents.document(id: taken))
        try await w.h.review.remove(taken)
        try await w.records.flush()
        // The index is lost and made again from the archive: its sequence starts after the documents it holds, so the number
        // of the document removed last is given to the next one that arrives.
        let (database, records) = try w.freshIndex()
        _ = try await records.rebuild()
        let h = w.h.over(database)
        let newcomer = try #require(try await h.ingest("edp_september.txt", text: "EDP electricity September").id)
        #expect(newcomer == taken, "the next document is given the number the removed one had")

        let back = try await h.review.putBack(taken)
        #expect(back.document != taken && back.removedAs == taken, "it comes back under a new number, and says which it had")
        let again = try #require(try await h.services.documents.document(id: back.document))
        #expect(again.uid == doc.uid && again.sha256 == doc.sha256, "it is the same document, by identity")
        let event = try #require(try await h.services.history.events(limit: 5, kinds: [.documentPutBack]).first)
        #expect(event.docId == back.document && event.summary.contains("\(taken)") && event.summary.contains("\(back.document)"),
                "History names both numbers: \(event.summary)")
    }
}

/// The user's rules about labels, made while the document was removed, apply to it as to every document.
extension PuttingBackDocumentsTests {
    /// What the label index (`document_labels`) holds of `id`.
    private func counted(_ h: Harness, _ id: Int64) async throws -> [String] {
        try await h.env.database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, value FROM document_labels WHERE doc_id = ? ORDER BY kind, value", arguments: [id])
                .map { "\($0["kind"] as String? ?? "")=\($0["value"] as String? ?? "")" }
        }
    }

    @Test func aLabelMergedMeanwhileComesBackAsTheLabelMergedIntoStillGivenByHand() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        try await h.review.remove(id)
        try await h.labels.merge(Self.handSender, into: "Merged Sender")
        try await h.review.putBack(id)
        let again = try #require(try await h.services.documents.document(id: id))
        let merged = DocumentLabel(kind: .sender, value: "Merged Sender")
        #expect(again.labels?.contains(merged) == true && again.labels?.contains(Self.handSender) == false,
                "it has the label it was merged into, not the one it had")
        #expect(again.byHand == [merged], "which is still the user's own")
        #expect(try await counted(h, id).contains("sender=Merged Sender"), "and counts in the label index")
    }

    @Test func aLabelRemovedForGoodMeanwhileDoesNotComeBack() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        try await h.review.remove(id)
        try await h.labels.ignore(Self.handSender)
        try await h.review.putBack(id)
        let again = try #require(try await h.services.documents.document(id: id))
        #expect(again.labels?.contains(Self.handSender) == false && again.byHand.isEmpty, "the label removed for good is not given again")
        #expect(again.labels?.contains(Self.tag) == true && again.labels?.contains(DocumentLabel(kind: .type, value: "invoice")) == true,
                "and the rest come back")
    }

    @Test func tagsAndLabelsByHandOtherwiseComeBackAndCountAgain() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        let before = try await counted(h, id)
        #expect(before.contains("sender=Hand Given Sender"), "the label index counts the label given by hand before")
        try await h.review.remove(id)
        #expect(try await counted(h, id).isEmpty, "and nothing of the removed document")
        try await h.review.putBack(id)
        let again = try #require(try await h.services.documents.document(id: id))
        #expect(again.labels == doc.labels && again.byHand == doc.byHand, "tags and labels given by hand come back as they were")
        #expect(try await counted(h, id) == before, "and count again in the label index")
    }
}

/// Through a rebuild of the index, and removed again.
extension PuttingBackDocumentsTests {
    @Test func aRemovalSurvivesARebuildAndCanBePutBack() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let id = try #require(w.documents.first)
        let doc = try #require(try await w.h.services.documents.document(id: id))
        try await w.h.review.remove(id)
        try await w.records.flush()
        let (database, records) = try w.freshIndex()
        _ = try await records.rebuild()
        let h = w.h.over(database)
        #expect(try await h.services.documents.document(id: id) == nil, "the rebuilt index does not hold the removed document")
        let back = try await h.review.putBack(id)
        let again = try #require(try await h.services.documents.document(id: id))
        #expect(back.document == id && again.uid == doc.uid && again.labels == doc.labels && FileManager.default.fileExists(atPath: again.path),
                "the entry in the History record file is enough to put it back, as it was")
    }

    @Test func aPutBackSurvivesARebuildUnderItsNumber() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let id = try #require(w.documents.first)
        let doc = try #require(try await w.h.services.documents.document(id: id))
        try await w.h.review.remove(id)
        try await w.h.review.putBack(id)
        await w.h.coordinator.drain(.everything)
        try await w.records.flush()
        let (database, records) = try w.freshIndex()
        _ = try await records.rebuild()
        let rebuilt = try #require(try await DocumentStore(database: database, time: TestTime(.advances)).document(id: id))
        #expect(rebuilt.uid == doc.uid && rebuilt.filename == doc.filename && rebuilt.labels == doc.labels,
                "the document is in its folder's record file and a rebuild keeps it, under the same number")
    }

    @Test func aDocumentPutBackCanBeRemovedAndPutBackAgain() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        for _ in 1...2 {
            try await h.review.remove(id)
            try await h.review.putBack(id)
        }
        let events = try await h.services.history.events(limit: 20, kinds: [.documentRemoved, .documentPutBack])
        #expect(events.map(\.kind) == [.documentPutBack, .documentRemoved, .documentPutBack, .documentRemoved],
                "each removal and put-back is recorded once, the latest first")
        let (second, secondRemoval) = (try #require(events.first), events[1])
        #expect(JSON.decode(PutBackPayload.self, from: second.payloadJson)?.removal == secondRemoval.id,
                "the second put-back undoes the second removal")
        #expect(h.env.trashed().isEmpty && FileManager.default.fileExists(atPath: doc.path), "the file is in the archive, the Trash empty")
    }
}
