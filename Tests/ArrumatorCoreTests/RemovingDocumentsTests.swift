@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// The user removes a document: its file goes to the Trash, never deleted, and it leaves the archive, its index and its
/// record file, with what History says of it.
@Suite struct RemovingDocumentsTests {
    /// The tables of the index that still refer to document `id`, but History and traces, which keep what happened, and,
    /// unless `flushed`, the sidecar the next writing of the record files removes from beside where the document was.
    private func referring(to id: Int64, in database: AppDatabase, flushed: Bool = false) async throws -> [String] {
        try await database.reader.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT m.name FROM sqlite_master m WHERE m.type = 'table'
                AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) WHERE name = 'doc_id') AND m.name NOT IN ('events', 'traces')
                """).filter { flushed || $0 != "sidecar_files" }
            return try tables.filter { try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \"\($0)\" WHERE doc_id = ?)", arguments: [id]) == true }
                + (try DocumentRecord.fetchOne(db, key: id) == nil ? [] : ["documents"])
        }
    }

    @Test func aRemovedDocumentsFileGoesToTheTrashAndNothingOfItIsLeftInTheIndexOrItsRecordFile() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let h = w.h
        let first = try #require(w.documents.first)
        let doc = try #require(try await h.services.documents.document(id: first))
        let id = try #require(doc.id)
        try await w.records.flush()
        #expect(try w.listing(in: h.env.archive).contains("file: \(doc.filename)"), "listed in its record file before")
        let filedOnDisk = doc.url.spelledOnDisk.path

        try await h.review.remove(id)
        #expect(!FileManager.default.fileExists(atPath: doc.path), "its file has left the archive")
        let trashed = h.env.trashed()
        #expect(trashed.map(\.lastPathComponent) == [doc.filename], "and is in the Trash, never deleted")
        #expect(try await referring(to: id, in: h.env.database).isEmpty, "nothing of the index refers to it: labels, text, meaning, jobs")
        #expect(try await h.search.search(SearchQuery(text: "EDP", meaning: .wordsOnly)).hits.map(\.id).contains(id) == false, "it is found no more")
        try await w.records.flush()
        #expect(try !w.listing(in: h.env.archive).contains("file: \(doc.filename)"), "and its record file lists it no more")
        let sidecar = try #require(h.env.layout.sidecar(of: doc.path))
        #expect(try await referring(to: id, in: h.env.database, flushed: true).isEmpty && !FileManager.default.fileExists(atPath: sidecar.path)
                    && h.env.trashed().count == 1,
                "nor is its sidecar beside where it was, which held what the app wrote, so it is gone rather than in the Trash")

        let (event, payload) = try await PuttingBackDocumentsTests.removal(h)
        #expect(event.actor == .user && event.summary == "Removed “\(doc.filename)”; its file is in the Trash",
                "History says the user removed it and where its file went")
        #expect(payload == RemovedPayload(document: id, from: filedOnDisk, trashed: trashed.first?.spelledOnDisk.path, entry: DocumentEntry(doc)),
                "and keeps its number, both paths, as the disk spells them, and its record file's entry")

        let (database, records) = try w.freshIndex()
        _ = try await records.rebuild()
        #expect(try await DocumentStore(database: database, time: TestTime(.advances)).document(id: id) == nil,
                "a rebuild of the index from the archive does not bring it back")
    }

    @Test func theRemovalKeepsTheDocumentsEntryThroughHistoryAndARebuild() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let h = w.h
        let id = try #require(w.documents.first)
        let (tag, sender) = (PuttingBackDocumentsTests.tag, PuttingBackDocumentsTests.handSender)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [tag, sender]))
        let record = try #require(try await h.services.documents.document(id: id))
        let entry = try #require(DocumentEntry(record))
        #expect(entry.labels?.contains(tag) == true && entry.byHand == [sender] && entry.analysis?.model == "stub",
                "the entry holds a tag, a label given by hand and how the model read it")

        try await h.review.remove(id)
        let (event, payload) = try await PuttingBackDocumentsTests.removal(h)
        #expect(payload.entry == entry, "History keeps the entry as it was when the document was removed")
        try await w.records.flush()
        let month = RecordKind.month(of: event.at)
        let text = try String(contentsOf: h.env.layout.historyFile(month: month), encoding: .utf8)
        #expect(text.contains(entry.uid) && text.contains(sender.value), "the month's History file holds it")

        let (database, records) = try w.freshIndex()
        _ = try await records.rebuild()
        let again = try #require(try await HistoryStore(database: database, time: TestTime(.advances)).events(limit: 5, kinds: [.documentRemoved]).first)
        #expect(JSON.decode(RemovedPayload.self, from: again.payloadJson)?.entry == entry,
                "and a rebuild of the index reads it back unchanged (dates are whole seconds under `TestTime`, as JSON writes them)")
    }

    @Test func aDocumentBackInIncomingIsRemovedFromThere() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        try await h.review.undo(id)
        let undone = try #require(try await h.services.documents.document(id: id))
        #expect(try await h.review.choices(for: undone).actions == [.readAgain, .remove], "an undone document can be removed")
        try await h.review.remove(id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.env.incoming.path).isEmpty, "Incoming no longer holds its file")
        #expect(h.env.trashed().map(\.lastPathComponent) == ["bill.txt"], "the Trash does")
        #expect(try await h.services.documents.document(id: id) == nil, "and the index no longer has it")
    }

    @Test func aDocumentWhoseFileIsGoneLeavesTheIndexWithNothingToTrash() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        try FileManager.default.removeItem(at: doc.url)
        try await h.review.remove(id)
        #expect(try await h.services.documents.document(id: id) == nil, "it leaves the index")
        #expect(h.env.trashed().isEmpty, "with nothing put in the Trash")
        let (event, payload) = try await PuttingBackDocumentsTests.removal(h)
        #expect(event.summary == "Removed “\(doc.filename)”; its file was not there" && payload.trashed == nil && payload.from == doc.path,
                "History says its file was not there, where the index had it")
    }

    /// A Trash that takes nothing, as one on a volume without one.
    struct RefusingTrash: Trashing {
        func trash(_ url: URL) throws -> URL? { throw CocoaError(.fileWriteNoPermission) }
        func holds(_ url: URL) -> Bool { false }
    }

    @Test func aFileTheTrashRefusesStaysAndSoDoesItsDocument() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        var services = h.services
        services.trash = RefusingTrash()
        let refusing = Harness(env: h.env, services: services)
        await #expect(throws: IngestError.notTrashed(doc.url.spelledOnDisk.path, reason: CocoaError(.fileWriteNoPermission).localizedDescription),
                      "it says the Trash would not take it") {
            try await refusing.review.remove(id)
        }
        #expect(FileManager.default.fileExists(atPath: doc.path), "the file stays where it is")
        #expect(try await h.services.documents.document(id: id) == doc, "the document is as it was")
        #expect(try await h.services.history.events(limit: 5, kinds: [.documentRemoved]).isEmpty, "and nothing is recorded")
    }

    @Test func aDocumentNotThereIsRefusedNamingIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        await #expect(throws: IngestError.documentNotFound(42), "no document 42") { try await h.review.remove(42) }
    }

    @Test func aFileAtItsPathThatIsAnotherDocumentsIsNeverMoved() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        // Another file took its place, carrying another document's identifier, as one moved there in Finder.
        try FileManager.default.removeItem(at: doc.url)
        try Data("another".utf8).write(to: doc.url)
        try Xattr.set(Xattr.documentID, "another-document", on: doc.url)
        try await h.review.remove(id)
        #expect(FileManager.default.fileExists(atPath: doc.path) && h.env.trashed().isEmpty, "the other file stays where it is")
        #expect(try await h.services.documents.document(id: id) == nil, "and the document, whose file is not there, leaves the index")
        let (event, payload) = try await PuttingBackDocumentsTests.removal(h)
        #expect(event.summary.hasSuffix("its file was not there") && payload.trashed == nil, "History says its file was not there")
    }

    @Test func twoRemovalsAtOnceMoveTheFileAndRecordItOnce() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        let review = h.review
        async let first: Result<RemovedPayload, any Error> = Result { try await review.remove(id) }
        async let second: Result<RemovedPayload, any Error> = Result { try await review.remove(id) }
        let outcomes = [await first, await second]
        let done = outcomes.compactMap { try? $0.get() }
        let refused = outcomes.compactMap { if case let .failure(error) = $0 { error as? IngestError } else { nil } }
        #expect(done.count == 1 && done.first?.trashed != nil, "one removal moves the file to the Trash: \(outcomes)")
        #expect(refused == [.documentNotFound(id)], "the other finds the document gone")
        #expect(try await h.services.history.events(limit: 5, kinds: [.documentRemoved]).count == 1 && h.env.trashed().count == 1,
                "History records it once, and the Trash holds the one file")
    }

    @Test func aDocumentAWorkerIsMovingIsNotRemovedAndOneWhoseMoveFailedIsRemovedWhereItIs() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        let job = try await h.services.queueReadingAgain(id, settings: await h.services.settings.current)
        // A worker reading it again holds its job and has planned where its file goes, as `DocumentFiler` does before the
        // move.
        let claim = h.services.claims.make()
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                UPDATE jobs SET state = 'filing', claim = ?, claimed_by = ?, payload_json = json_set(payload_json, '$.plannedPath', ?)
                WHERE id = ?
                """, arguments: [claim, h.services.claims.process, h.env.archive.appendingPathComponent("EDP/bill.txt").path, job])
        }
        let read = try #require(try await h.services.documents.document(id: id))
        #expect(try await !h.review.choices(for: read).actions.contains(.remove), "the card offers no removal while it may move")
        await #expect(throws: IngestError.beingMoved(id, name: doc.filename), "and a removal is refused, naming it") {
            try await h.review.remove(id)
        }
        #expect(FileManager.default.fileExists(atPath: doc.path) && h.env.trashed().isEmpty, "the file stays where it is")
        // The move failed, and the job waits to be tried again, which no worker holds meanwhile.
        h.services.claims.letGo(claim)
        #expect(try await h.review.choices(for: read).actions.contains(.remove), "it is offered again")
        try await h.review.remove(id)
        let left = try await h.services.jobs.job(id: job)
        #expect(h.env.trashed().map(\.lastPathComponent) == [doc.filename] && left == nil, "and removed from where it is, with its reading again")
    }

    @Test func aFileMovedBeforeItsMoveWasRecordedIsRemovedFromWhereItWent() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        let job = try await h.services.queueReadingAgain(id, settings: await h.services.settings.current)
        // Reading it again moved its file and was cut off before it recorded the move, as by a crash.
        let planned = h.env.archive.appendingPathComponent("EDP bill.txt")
        try FileManager.default.moveItem(at: doc.url, to: planned)
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET state = 'filing', payload_json = json_set(payload_json, '$.plannedPath', ?) WHERE id = ?",
                           arguments: [planned.path, job])
        }
        try await h.review.remove(id)
        #expect(!FileManager.default.fileExists(atPath: planned.path) && h.env.trashed().map(\.lastPathComponent) == ["EDP bill.txt"],
                "its file goes to the Trash from where the move left it, carrying its identifier")
        let (_, payload) = try await PuttingBackDocumentsTests.removal(h)
        #expect(payload.from == planned.spelledOnDisk.path, "and History says it was there")
    }

    /// A way a document may not be removed yet, each on its own (`ReviewActions.removalRefusal`).
    enum Refusing: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case arrived, processing, readIn, moving
        var testDescription: String { rawValue }
    }

    @Test(arguments: Refusing.allCases)
    func theListingRefusesARemovalExactlyAsRemoveDoes(_ condition: Refusing) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        switch condition {
        case .arrived, .processing:
            try await h.env.database.writer.write { db in
                try db.execute(sql: "UPDATE documents SET status = ? WHERE id = ?", arguments: [condition.rawValue, id])
            }
        case .readIn:
            _ = try await h.services.jobs.enqueue(path: doc.path, kind: .ingest, docID: id)
        case .moving:
            let job = try await h.services.queueReadingAgain(id, settings: await h.services.settings.current)
            let claim = h.services.claims.make()
            try await h.env.database.writer.write { db in
                try db.execute(sql: """
                    UPDATE jobs SET state = 'filing', claim = ?, claimed_by = ?, payload_json = json_set(payload_json, '$.plannedPath', ?)
                    WHERE id = ?
                    """, arguments: [claim, h.services.claims.process, h.env.archive.appendingPathComponent("EDP/bill.txt").path, job])
            }
        }
        let read = try #require(try await h.services.documents.document(id: id))
        let listed = try await h.review.removalRefusals(of: [read])
        let expected: IngestError = condition == .moving ? .beingMoved(id, name: doc.filename) : .beingReadIn(id, name: doc.filename)
        #expect(listed[id] == expected, "the listing says what removing it then says, for \(condition)")
        await #expect(throws: expected, "removing it is then refused so") { try await h.review.remove(id) }
        #expect(FileManager.default.fileExists(atPath: doc.path) && h.env.trashed().isEmpty, "its file has not moved")
        #expect(try await !h.review.choices(for: read).actions.contains(.remove), "and its card offers no removal")
    }

    @Test(arguments: [DocumentStatus.filed, .needsReview, .failed, .held, .undone, .duplicate, .missing])
    func everyOtherStatusIsListedRemovableAndIsRemoved(_ status: DocumentStatus) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let other = try #require(try await h.ingest("other.txt", text: "Another letter about something else.").id)
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET status = ?, duplicate_of = ? WHERE id = ?",
                           arguments: [status.rawValue, status == .duplicate ? other : nil, id])
        }
        if status == .missing { try FileManager.default.removeItem(at: doc.url) }
        let read = try #require(try await h.services.documents.document(id: id))
        #expect(try await h.review.removalRefusals(of: [read]).isEmpty, "nothing refuses the removal of a \(status) document")
        #expect(try await h.review.choices(for: read).actions.contains(.remove), "its card offers it")
        try await h.review.remove(id)
        #expect(try await h.services.documents.document(id: id) == nil, "and it is removed")
    }

    @Test func aFileInTheTrashWhoseRemovalIsNotRecordedComesBack() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        // Recording the removal fails once its file is in the Trash, as on a disk that fills up.
        try await h.env.database.writer.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER unrecorded BEFORE DELETE ON documents BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        let error = try await #require(throws: DatabaseError.self, "the removal fails with the record's error") { try await h.review.remove(id) }
        #expect(error.message?.contains("disk full") == true, "the one the trigger raised: \(error)")
        #expect(FileManager.default.fileExists(atPath: doc.path) && h.env.trashed().isEmpty, "its file is back where it was, not in the Trash")
        #expect(try await h.services.documents.document(id: id) == doc, "and the document is as it was")
    }

    @Test func aFileInTheTrashWhoseRemovalCannotCommitComesBack() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        // The removal's transaction fails only as it commits, as one on a full disk does: a constraint checked then.
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TABLE kept (id INTEGER PRIMARY KEY);
                CREATE TEMP TABLE keeping (kept INTEGER REFERENCES kept(id) DEFERRABLE INITIALLY DEFERRED);
                CREATE TEMP TRIGGER uncommitted AFTER DELETE ON main.documents BEGIN INSERT INTO keeping (kept) VALUES (-1); END
                """)
        }
        let error = try await #require(throws: DatabaseError.self, "the removal fails as it commits") { try await h.review.remove(id) }
        #expect(error.message?.contains("FOREIGN KEY") == true, "with the constraint checked then: \(error)")
        #expect(FileManager.default.fileExists(atPath: doc.path) && h.env.trashed().isEmpty, "its file is back where it was, not in the Trash")
        #expect(try await h.services.documents.document(id: id) == doc, "and the document is as it was")
    }
}
