@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// Two put-backs at once, and a put-back that fails part way: the file is in one place and the document is recorded once,
/// or nothing has changed.
extension PuttingBackDocumentsTests {
    /// A document removed, with where its file was and is.
    private struct Removed {
        let h: Harness
        let doc: DocumentRecord
        let analyzer: StubAnalyzer
        let removal: RemovedPayload
        let trashed: String
    }

    private func removed() async throws -> Removed {
        let (h, doc, _, analyzer) = try await Self.world()
        try await h.review.remove(try #require(doc.id))
        let removal = try await Self.removal(h).payload
        return Removed(h: h, doc: doc, analyzer: analyzer, removal: removal, trashed: try #require(removal.trashed))
    }

    @Test func twoPutBacksAtOnceMoveTheFileAndRecordItOnce() async throws {
        let gone = try await removed()
        let (h, doc, removal) = (gone.h, gone.doc, gone.removal)
        defer { h.env.cleanup() }
        let (id, review) = (try #require(doc.id), h.review)
        async let first: Result<PutBackPayload, any Error> = Result { try await review.putBack(id) }
        async let second: Result<PutBackPayload, any Error> = Result { try await review.putBack(id) }
        let outcomes = [await first, await second]
        let done = outcomes.compactMap { try? $0.get() }
        let refused = outcomes.compactMap { if case let .failure(error) = $0 { error as? PutBackError } else { nil } }
        #expect(done.count == 1, "one put-back moves the file: \(outcomes)")
        #expect(refused == [.alreadyPutBack(name: doc.filename)] || refused == [.noLongerInTrash(name: doc.filename, trashed: removal.trashed ?? "")],
                "the other finds it put back already or the file gone from the Trash, never a second file or event: \(refused)")
        let puts = try await Self.events(h, .documentPutBack)
        #expect(puts.count == 1 && h.env.trashed().isEmpty && FileManager.default.fileExists(atPath: removal.from),
                "History records it once, the Trash is empty and the file is in one place")
        #expect(try await h.services.documents.list(DocumentFilter(), limit: 10).count == 1, "and the index holds the one document")
    }

    @Test func aPutBackAndARemovalAtOnceLeaveOneConsistentState() async throws {
        let gone = try await removed()
        let (h, doc, removal) = (gone.h, gone.doc, gone.removal)
        defer { h.env.cleanup() }
        let (id, review) = (try #require(doc.id), h.review)
        async let put: Result<PutBackPayload, any Error> = Result { try await review.putBack(id) }
        async let removing: Result<RemovedPayload, any Error> = Result { try await review.remove(id) }
        let (putOutcome, removeOutcome) = (await put, await removing)
        #expect((try? putOutcome.get()) != nil, "the put-back is done: \(putOutcome)")
        let indexed = try await h.services.documents.document(id: id) != nil
        let events = try await h.services.history.events(limit: 10, kinds: [.documentRemoved, .documentPutBack])
        if (try? removeOutcome.get()) != nil {
            #expect(!indexed && !FileManager.default.fileExists(atPath: removal.from) && h.env.trashed().count == 1,
                    "removed after it was put back: out of the index, its file in the Trash")
            #expect(events.map(\.kind) == [.documentRemoved, .documentPutBack, .documentRemoved], "and History says so, once each: \(events.map(\.kind))")
        } else {
            #expect(indexed && FileManager.default.fileExists(atPath: removal.from) && h.env.trashed().isEmpty,
                    "the removal found no document: it is in the index with its file in place")
            #expect(events.map(\.kind) == [.documentPutBack, .documentRemoved], "and History says so, once each: \(events.map(\.kind))")
        }
    }

    @Test(.folderModesKeepOut) func aMoveTheFolderRefusesLeavesTheFileInTheTrash() async throws {
        let gone = try await removed()
        let (h, doc, removal, trashed) = (gone.h, gone.doc, gone.removal, gone.trashed)
        defer { h.env.cleanup() }
        let folder = URL(fileURLWithPath: removal.from).deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        let id = try #require(doc.id)
        let error = try await #require(throws: PutBackError.self, "it is refused with the reason") { try await h.review.putBack(id) }
        guard case let .notMoved(name, reason) = error else { Issue.record("expected notMoved, got \(error)"); return }
        #expect(name == doc.filename && !reason.isEmpty, "naming the document and the reason")
        #expect(FileManager.default.fileExists(atPath: trashed) && !FileManager.default.fileExists(atPath: removal.from),
                "the file stays in the Trash, and nothing is written at its place")
        let putBacks = try await Self.events(h, .documentPutBack)
        #expect(putBacks.isEmpty, "nothing is recorded")
        #expect(try await h.services.documents.document(id: id) == nil, "and the document is not in the index")
    }

    @Test func aFileBroughtBackWhosePutBackIsNotRecordedGoesBackToTheTrash() async throws {
        let gone = try await removed()
        let (h, doc, removal, trashed) = (gone.h, gone.doc, gone.removal, gone.trashed)
        defer { h.env.cleanup() }
        // Recording the put-back fails once its file is back, as on a disk that fills up.
        try await h.env.database.writer.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER unrecorded BEFORE INSERT ON documents BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        let id = try #require(doc.id)
        // The record's own failure, which comes only after the file was brought back, so the file was moved and then taken back.
        let error = try await #require(throws: DatabaseError.self, "the put-back fails with the record's error") { try await h.review.putBack(id) }
        #expect(error.message?.contains("disk full") == true, "the one the trigger raised: \(error)")
        #expect(FileManager.default.fileExists(atPath: trashed) && !FileManager.default.fileExists(atPath: removal.from),
                "its file is back exactly where it was in the Trash")
        #expect(h.env.trashed().map(\.path) == [URL(fileURLWithPath: trashed).path], "not in a new place of it")
        let (putBacks, jobs) = (try await Self.events(h, .documentPutBack), try await h.services.jobs.active(kinds: nil))
        let indexed = try await h.services.documents.document(id: id)
        #expect(indexed == nil && putBacks.isEmpty && jobs.isEmpty,
                "and the index and History are as they were")
    }

    @Test func aFileBroughtBackWhosePutBackCannotCommitGoesBackToTheTrash() async throws {
        let gone = try await removed()
        let (h, doc, removal, trashed) = (gone.h, gone.doc, gone.removal, gone.trashed)
        defer { h.env.cleanup() }
        // The transaction fails only as it commits, as one on a full disk does: a constraint checked then.
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TABLE kept (id INTEGER PRIMARY KEY);
                CREATE TEMP TABLE keeping (kept INTEGER REFERENCES kept(id) DEFERRABLE INITIALLY DEFERRED);
                CREATE TEMP TRIGGER uncommitted AFTER INSERT ON main.documents BEGIN INSERT INTO keeping (kept) VALUES (-1); END
                """)
        }
        let id = try #require(doc.id)
        let error = try await #require(throws: DatabaseError.self, "the put-back fails as it commits") { try await h.review.putBack(id) }
        #expect(error.message?.contains("FOREIGN KEY") == true, "with the constraint checked then: \(error)")
        #expect(FileManager.default.fileExists(atPath: trashed) && !FileManager.default.fileExists(atPath: removal.from)
                    && h.env.trashed().map(\.path) == [URL(fileURLWithPath: trashed).path],
                "its file is back exactly where it was in the Trash")
        let putBacks = try await Self.events(h, .documentPutBack)
        let indexed = try await h.services.documents.document(id: id)
        #expect(indexed == nil && putBacks.isEmpty, "and the index and History are as they were")
    }

    /// The pipeline of `h` with every move crossing a volume, and `trash` as its Trash, the environment's own unless given.
    private func crossing(_ h: Harness, _ analyzer: StubAnalyzer, trash: (any Trashing)? = nil) -> Harness {
        Harness(env: h.env, services: Harness.services(h.env, analyzer: analyzer, config: h.env.config, sameVolume: { _, _ in false }, trash: trash))
    }

    /// A Trash that holds what `kept` holds and takes nothing more, as that of a volume that stops taking files.
    private struct HoldingButTakingNothing: Trashing {
        let kept: FolderTrash
        func trash(_ url: URL) throws -> URL? { throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "the Trash is full"]) }
        func holds(_ url: URL) -> Bool { kept.holds(url) }
    }

    @Test func acrossVolumesACheckedCopyComesBackAndTheOriginalStaysInTheTrash() async throws {
        let gone = try await removed()
        let (h, doc, analyzer, removal, trashed) = (gone.h, gone.doc, gone.analyzer, gone.removal, gone.trashed)
        defer { h.env.cleanup() }
        let back = try await crossing(h, analyzer).review.putBack(try #require(doc.id))
        #expect(back.copied == true, "History says it came back as a copy")
        #expect(try HashService.sha256(of: URL(fileURLWithPath: removal.from)) == doc.sha256, "that hashes as the document")
        #expect(FileManager.default.fileExists(atPath: trashed), "the original stays in the Trash, never deleted")
        #expect(Xattr.get(Xattr.documentID, from: URL(fileURLWithPath: removal.from)) == doc.uid, "and the copy carries its identifier")
    }

    @Test func acrossVolumesAPutBackThatCannotCommitTakesTheCopyBackToTheTrashAndLeavesTheOriginal() async throws {
        let gone = try await removed()
        let (h, doc, analyzer, removal, trashed) = (gone.h, gone.doc, gone.analyzer, gone.removal, gone.trashed)
        defer { h.env.cleanup() }
        try await h.env.database.writer.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER unrecorded BEFORE INSERT ON documents BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        let id = try #require(doc.id)
        let review = crossing(h, analyzer).review
        let error = try await #require(throws: DatabaseError.self, "the put-back fails with the record's error") { try await review.putBack(id) }
        #expect(error.message?.contains("disk full") == true, "the one the trigger raised: \(error)")
        #expect(!FileManager.default.fileExists(atPath: removal.from) && FileManager.default.fileExists(atPath: trashed),
                "nothing is left where it was, and the original is where it was")
        #expect(h.env.trashed().count == 2, "the copy went to the Trash, beside the original, never deleted")
    }

    @Test func acrossVolumesACopyTheTrashWillNotTakeBackStaysAndTheRecordsOwnErrorIsWhatIsThrown() async throws {
        let gone = try await removed()
        let (h, doc, analyzer, removal, trashed) = (gone.h, gone.doc, gone.analyzer, gone.removal, gone.trashed)
        defer { h.env.cleanup() }
        try await h.env.database.writer.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER unrecorded BEFORE INSERT ON documents BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        let id = try #require(doc.id)
        let review = crossing(h, analyzer, trash: HoldingButTakingNothing(kept: h.env.trash)).review
        let error = try await #require(throws: DatabaseError.self, "what is thrown is the record's error, not the Trash's") { try await review.putBack(id) }
        #expect(error.message?.contains("disk full") == true, "the one the trigger raised: \(error)")
        #expect(try HashService.sha256(of: URL(fileURLWithPath: removal.from)) == doc.sha256 && FileManager.default.fileExists(atPath: trashed),
                "the copy stays where it was put, whole, and the original where it was")
        let putBacks = try await Self.events(h, .documentPutBack)
        let indexed = try await h.services.documents.document(id: id)
        #expect(indexed == nil && putBacks.isEmpty, "with no document and no event, so the next start takes the file in as a new one")
    }

    @Test func aFileGoneFromTheTrashWhileItIsReadIsGoneNotAFailureOfTheReading() async throws {
        let gone = try await removed()
        let (h, doc, trashed) = (gone.h, gone.doc, gone.trashed)
        defer { h.env.cleanup() }
        let there = try await PutBackRule.reading(trashed, name: doc.filename)
        #expect(there.sha256 == doc.sha256 && there.fingerprint.size == doc.size, "read while it is there, its checksum and size are the document's")
        try FileManager.default.removeItem(atPath: trashed)
        // Gone at the first step or at the last, as when another put-back moves it meanwhile: one refusal, never a raw error.
        let error = try await #require(throws: PutBackError.self, "a file gone is refused as gone") { try await PutBackRule.reading(trashed, name: doc.filename) }
        #expect(error == .noLongerInTrash(name: doc.filename, trashed: trashed), "naming the document and the place: \(error)")
    }

    /// Cancelled before it starts, so the first read of the index throws `CancellationError` (GRDB checks the task before it
    /// runs a closure): what this proves is that a stop is surfaced, never swallowed by a fallback, and that nothing was moved
    /// or recorded. The check between hashing and the move has no seam that stops a task there deterministically.
    @Test func aPutBackStoppedBeforeItStartsThrowsTheCancellationAndChangesNothing() async throws {
        let gone = try await removed()
        let (h, doc, removal, trashed) = (gone.h, gone.doc, gone.removal, gone.trashed)
        defer { h.env.cleanup() }
        let (id, review) = (try #require(doc.id), h.review)
        let outcome: Result<PutBackPayload, any Error> = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Result { try await review.putBack(id) }
        }.value
        guard case let .failure(error) = outcome else { Issue.record("a cancelled put-back went on: \(outcome)"); return }
        #expect(error is CancellationError, "it stops with the cancellation, which no fallback swallows: \(error)")
        #expect(FileManager.default.fileExists(atPath: trashed) && !FileManager.default.fileExists(atPath: removal.from),
                "nothing was moved")
        let putBacks = try await Self.events(h, .documentPutBack)
        #expect(putBacks.isEmpty, "and nothing was recorded")
    }
}
