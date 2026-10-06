@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What a change the user made in the archive does to the index, decided from the identifier on the file and what is on
/// disk when it is applied: a move is followed only when the old path no longer holds the document, a copy is a document
/// of its own, a document found again is as it was, and applying a change twice does nothing more.
@Suite struct ArchiveReconcilerTests {
    @Test func aDocumentMovedInFinderIsFollowedAndOnceOnly() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        let moved = try h.moveIntoArchive(doc.url, to: "Bills/\(doc.filename)")
        let reconciler = h.reconciler
        try await reconciler.apply([.found(path: moved.path), .gone(path: doc.path)])
        try await reconciler.apply([.found(path: moved.path), .gone(path: doc.path)])
        let followed = try #require(try await h.services.documents.document(id: id))
        #expect(followed.path == moved.path && followed.status == .filed, "the record follows its file, which its old path no longer holds")
        #expect(try await h.services.history.events(limit: 10, kinds: [.userMoved, .missing], docID: id).map(\.kind) == [.userMoved],
                "recorded once, though applied twice as after a restart, and never taken for a removal")
    }

    @Test func aCopyMadeInFinderIsADocumentOfItsOwnAndTheOriginalStaysWhereItIs() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(original.id)
        let copy = h.env.archive.appendingPathComponent("Kept/bill copy.txt").standardizedFileURL
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original.url, to: copy)
        // A copy made in Finder keeps the identifier the app stored on its original.
        try Xattr.set(Xattr.documentID, original.uid, on: copy)
        try await h.reconciler.apply([.found(path: copy.path)])
        #expect(try await h.services.documents.document(id: id)?.path == original.path,
                "the original's file is still where its record says: the copy is not it moved")
        #expect(Xattr.get(Xattr.documentID, from: copy) == nil, "the copy no longer carries the original's identifier")
        await h.coordinator.drain()
        let adopted = try #require(try await h.services.documents.document(path: copy.path))
        #expect(adopted.id != id && adopted.status == .filed, "the copy is a document of its own, read where it is")
        #expect(Xattr.get(Xattr.documentID, from: copy) == adopted.uid, "with an identifier of its own")
        try FileManager.default.removeItem(at: copy)
        try await h.reconciler.apply([.gone(path: copy.path)])
        #expect(try await h.services.documents.document(id: try #require(adopted.id))?.status == .missing, "removing the copy is the copy's")
        #expect(try await h.services.documents.document(id: id)?.status == .filed, "and never the original's, which is still there")
    }

    @Test func aFileWithAnIdentifierTheIndexDoesNotKnowIsTakenIn() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let letter = try h.env.put("From another archive/letter.txt", text: IngestTests.bill)
        let foreign = UUID().uuidString
        try Xattr.set(Xattr.documentID, foreign, on: letter)
        try await h.reconciler.apply([.found(path: letter.path)])
        await h.coordinator.drain()
        let adopted = try #require(try await h.services.documents.document(path: letter.path),
                                   "a file another archive filed is read and labelled where it is")
        #expect(adopted.uid != foreign && Xattr.get(Xattr.documentID, from: letter) == adopted.uid, "under an identifier of this archive's")
    }

    @Test func aFileInTheSystemFolderOrTakenInAlreadyIsNotTakenInAgain() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let stray = try h.env.put("\(h.env.config.records.systemFolderName)/stray.txt", text: "no document")
        let loose = try h.env.put("loose.txt", text: IngestTests.bill)
        try await h.reconciler.apply([.found(path: stray.path), .found(path: loose.path)])
        try await h.reconciler.apply([.found(path: loose.path)])
        #expect(try await h.services.jobs.active().map(\.sourcePath) == [loose.path], "the system folder holds no documents")
        #expect(try await h.services.history.events(limit: 10, kinds: [.adopted]).count == 1,
                "a file reported again before it is read is taken in once, and recorded once")
    }

    @Test func aDocumentBackFromMissingTakesBackItsStatusAndItsPlaceInSearch() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        // Search by meaning made ready, as the runtime makes it when it opens the archive.
        await h.services.vectors.load(model: StubAnalyzer.embeddingModel, rows: [])
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        let searchable = await h.foundByMeaning()
        #expect(doc.status == .needsReview && searchable == [id], "it waits for the user, and is found by meaning")
        let away = try h.moveOutOfArchive(doc.url)
        try await h.reconciler.apply([.gone(path: doc.path)])
        let gone = try await h.services.documents.document(id: id)
        let unsearchable = await h.foundByMeaning()
        #expect(gone?.status == .missing && unsearchable.isEmpty, "taken out of the archive, it is missing, and not found by meaning")
        let back = try h.moveIntoArchive(away, to: "Back/\(doc.filename)")
        try await h.reconciler.apply([.found(path: back.path)])
        let found = try #require(try await h.services.documents.document(id: id))
        #expect(found.status == .needsReview && found.path == back.path, "put back elsewhere, it still waits for the user, where it is now")
        #expect(await h.foundByMeaning() == [id], "and is found by meaning again")
        #expect(try await h.services.history.events(limit: 10, kinds: [.missing, .userMoved], docID: id).map(\.kind) == [.userMoved, .missing],
                "both are in History")
    }

    @Test func aDocumentPutBackWhereItWasIsInTheArchiveAgain() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        let away = try h.moveOutOfArchive(doc.url)
        try await h.reconciler.apply([.gone(path: doc.path)])
        try FileManager.default.moveItem(at: away, to: doc.url)
        try await h.reconciler.apply([.found(path: doc.path)])
        #expect(try await h.services.documents.document(id: id)?.status == .filed, "back in its place, it is filed again")
        let back = try #require(try await h.services.history.events(limit: 1, kinds: [.userMoved], docID: id).first)
        #expect(back.summary == "\(doc.filename) is back in the archive", "History says so")
    }

    /// A new file saved where a document was removed from is taken in, a document of its own, the removed one staying
    /// missing: a document missing from a path is none taken in for a file there (the review of the fix of the final
    /// review of #17).
    @Test func aNewFileSavedWhereARemovedDocumentWasIsTakenIn() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        _ = try h.moveOutOfArchive(doc.url)
        try await h.reconciler.apply([.gone(path: doc.path)])
        try Data("Water bill of August".utf8).write(to: doc.url)
        try await h.reconciler.apply([.found(path: doc.path)])
        #expect(try await h.services.jobs.active().map(\.sourcePath) == [doc.path], "the new file is queued to be read where it is")
        #expect(try await h.services.history.events(limit: 10, kinds: [.adopted]).count == 1, "and History says it was added")
        #expect(try await h.services.documents.document(id: id)?.status == .missing, "the document removed stays missing")
    }

    @Test func aDocumentLeftForLaterIsMissingWhenItsFileGoesAndLeftForLaterWhenItComesBack() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        try await h.review.hold(id)
        let away = try h.moveOutOfArchive(doc.url)
        try await h.reconciler.apply([.gone(path: doc.path)])
        #expect(try await h.services.documents.document(id: id)?.status == .missing, "a document left for later is in the archive")
        let back = try h.moveIntoArchive(away, to: doc.filename)
        try await h.reconciler.apply([.found(path: back.path)])
        #expect(try await h.services.documents.document(id: id)?.status == .held, "back, it is left for later as it was")
    }

    @Test func aFolderGoneMarksTheDocumentsInItMissingAndNoOthers() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let inOld = try await h.ingest("bill.txt", text: IngestTests.bill)
        let inOlder = try await h.ingest("receipt.txt", text: "A receipt")
        let movedOut = try await h.ingest("contract.txt", text: "Rental contract")
        let reconciler = h.reconciler
        let old = try h.moveIntoArchive(inOld.url, to: "Old/2024/\(inOld.filename)")
        let older = try h.moveIntoArchive(inOlder.url, to: "Older/\(inOlder.filename)")
        let left = try h.moveIntoArchive(movedOut.url, to: "Old/\(movedOut.filename)")
        try await reconciler.apply([.found(path: old.path), .found(path: older.path), .found(path: left.path)])
        let kept = try h.moveIntoArchive(left, to: movedOut.filename)
        try FileManager.default.removeItem(at: h.env.archive.appendingPathComponent("Old"))
        try await reconciler.apply([.found(path: kept.path), .gone(path: h.env.archive.appendingPathComponent("Old").standardizedFileURL.path)])
        var statuses: [DocumentStatus?] = []
        for doc in [inOld, inOlder, movedOut] { statuses.append(try await h.services.documents.document(id: try #require(doc.id))?.status) }
        #expect(statuses == [.missing, .filed, .filed],
                "a folder removed takes the documents in it at any depth, not those of a folder named alike, nor one moved out of it first")
    }

    @Test func aDocumentWhoseFileAnotherWasMovedOverIsMissing() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let replaced = try await h.ingest("bill.txt", text: IngestTests.bill)
        let replacing = try await h.ingest("receipt.txt", text: "A receipt")
        // As Finder replaces a file: the one there goes, and the other takes its place.
        try FileManager.default.removeItem(at: replaced.url)
        try FileManager.default.moveItem(at: replacing.url, to: replaced.url)
        try await h.reconciler.apply([.found(path: replaced.path), .gone(path: replacing.path)])
        #expect(try await h.services.documents.document(id: try #require(replacing.id))?.path == replaced.path,
                "the file now there is the one its identifier names")
        #expect(try await h.services.documents.document(id: try #require(replaced.id))?.status == .missing,
                "the document whose file it replaced is missing, so no two documents share one file")
    }

    @Test func aStopWhileChangesAreAppliedEndsItAndAppliesNothingMore() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let loose = try h.env.put("loose.txt", text: IngestTests.bill)
        let reconciler = h.reconciler
        let applying = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await reconciler.apply([.found(path: loose.path)])
        }
        await #expect(throws: CancellationError.self, "a stop is no change that failed: it ends the work") { try await applying.value }
        #expect(try await h.services.jobs.active().isEmpty, "and nothing is applied after it, to be reported again at the next start")
    }

    @Test(.enabled(if: Volume.ignoresCase, Volume.needsCaseInsensitive))
    func aRenameThatChangesOnlyCaseIsFollowedAndTheFileStaysOneDocument() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        let upper = doc.url.deletingLastPathComponent().appendingPathComponent(doc.filename.uppercased()).standardizedFileURL
        try FileManager.default.moveItem(at: doc.url, to: upper)
        try await h.reconciler.apply([.found(path: upper.path), .gone(path: doc.path)])
        // Applied again, as after a restart, with the name the file had before, which on this volume still finds it.
        try await h.reconciler.apply([.found(path: doc.path), .found(path: upper.path), .gone(path: doc.path)])
        let documents = try await h.services.documents.list(DocumentFilter(), limit: h.env.config.interface.pageSize)
        #expect(documents.map(\.id) == [id] && documents.first?.path == upper.path && documents.first?.status == .filed,
                "the same file under another case is the document renamed: one document, where it is now")
        let queued = try await h.services.jobs.active()
        #expect(Xattr.get(Xattr.documentID, from: upper) == doc.uid && queued.isEmpty,
                "its identifier stays on it, and nothing is taken in again to be read by the model")
    }

    @Test func aFolderRenamedWithItsListHasEachOfItsDocumentsRecordedMovedOnce() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let records = h.env.records()
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        let inFolder = try h.moveIntoArchive(doc.url, to: "Pasta QA/\(doc.filename)")
        try await h.reconciler.apply([.found(path: inFolder.path), .gone(path: doc.path)])
        try await records.flush()
        let folder = inFolder.deletingLastPathComponent()
        let renamedFolder = folder.deletingLastPathComponent().appendingPathComponent("Pasta QA renamed", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamedFolder)
        // As the runtime's archive pump does: the record files that changed are read first, then the changes applied.
        try await records.reconcile()
        try await h.reconciler.apply([.found(path: renamedFolder.appendingPathComponent(doc.filename).path), .gone(path: folder.path)])
        try await records.reconcile()
        let followed = try #require(try await h.services.documents.document(id: id))
        #expect(followed.path.hasSuffix("/Pasta QA renamed/\(doc.filename)") && followed.status == .filed,
                "the document is where its folder went")
        let moves = try await h.services.history.events(limit: 10, kinds: [.userMoved, .userRenamed, .missing], docID: id)
        #expect(moves.map(\.kind) == [.userMoved, .userMoved] && moves.first?.summary == "\(doc.filename) moved to \(followed.path)",
                "its folder renamed moves it, which History records once, as it records a document moved on its own: \(moves.map(\.summary))")
    }

    @Test(.enabled(if: Volume.ignoresCase, Volume.needsCaseInsensitive))
    func aFolderRenamedOnlyInCaseHasItsDocumentsFollowed() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(doc.id)
        let inBills = try h.moveIntoArchive(doc.url, to: "bills/\(doc.filename)")
        try await h.reconciler.apply([.found(path: inBills.path), .gone(path: doc.path)])
        let lower = inBills.deletingLastPathComponent()
        let upper = lower.deletingLastPathComponent().appendingPathComponent("Bills", isDirectory: true).standardizedFileURL
        try FileManager.default.moveItem(at: lower, to: upper)
        let renamed = upper.appendingPathComponent(doc.filename)
        try await h.reconciler.apply([.found(path: renamed.path), .gone(path: lower.path)])
        try await h.reconciler.apply([.found(path: inBills.path)])
        let documents = try await h.services.documents.list(DocumentFilter(), limit: h.env.config.interface.pageSize)
        #expect(documents.map(\.id) == [id] && documents.first?.path == renamed.path && documents.first?.status == .filed,
                "every document in a folder renamed only in case follows it, and none becomes a second document")
        #expect(try await h.services.jobs.active().isEmpty, "nothing is read again")
    }

    @Test(arguments: [true, false])
    func aCopyAndAMoveOfItsOriginalAppliedTogetherFollowTheOriginalInEitherOrder(_ copyFirst: Bool) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(original.id)
        // Named so it comes before where the original goes, as a batch is ordered by path.
        let copy = h.env.archive.appendingPathComponent("A copy.txt").standardizedFileURL
        try FileManager.default.copyItem(at: original.url, to: copy)
        try Xattr.set(Xattr.documentID, original.uid, on: copy)
        let moved = try h.moveIntoArchive(original.url, to: "Z/\(original.filename)")
        let found: [ArchiveChange] = [.found(path: copy.path), .found(path: moved.path)]
        try await h.reconciler.apply((copyFirst ? found : found.reversed()) + [.gone(path: original.path)])
        #expect(try await h.services.documents.document(id: id)?.path == moved.path,
                "the document follows its own file, told from the copy by its inode, whichever is applied first")
        #expect(Xattr.get(Xattr.documentID, from: moved) == original.uid && Xattr.get(Xattr.documentID, from: copy) == nil,
                "the original keeps its identifier, and the copy no longer carries it")
        #expect(try await h.services.jobs.active().map(\.sourcePath) == [copy.path], "and only the copy is taken in, as a document of its own")
    }

    @Test(.fileModesKeepOut) func aCopyWhoseIdentifierCannotBeTakenOffStaysOneDocumentWhenRenamed() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: IngestTests.bill)
        let copy = h.env.archive.appendingPathComponent("bill copy.txt").standardizedFileURL
        try FileManager.default.copyItem(at: original.url, to: copy)
        try Xattr.set(Xattr.documentID, original.uid, on: copy)
        // Read-only: neither the original's identifier can be taken off it nor one of its own written on it.
        try FileManager.default.setAttributes([.posixPermissions: Self.readOnly], ofItemAtPath: copy.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: Self.writable], ofItemAtPath: copy.path) }
        try await h.reconciler.apply([.found(path: copy.path)])
        await h.coordinator.drain()
        let adopted = try #require(try await h.services.documents.document(path: copy.path))
        #expect(Xattr.get(Xattr.documentID, from: copy) == original.uid, "the copy still carries the original's identifier")
        let renamed = copy.deletingLastPathComponent().appendingPathComponent("bill copy renamed.txt")
        try FileManager.default.moveItem(at: copy, to: renamed)
        try await h.reconciler.apply([.found(path: renamed.path), .gone(path: copy.path)])
        let adoptedID = try #require(adopted.id)
        let followed = try #require(try await h.services.documents.document(id: adoptedID))
        #expect(followed.path == renamed.path && followed.status == .filed,
                "renamed, it is followed as the document it is, by its inode, and not taken for the original's copy again")
        let queued = try await h.services.jobs.active()
        let originalNow = try await h.services.documents.document(id: try #require(original.id))
        #expect(queued.isEmpty && originalNow?.path == original.path, "nothing is taken in again, and the original stays where it is")
        // The original moved away, and the copy changed before its move is applied: the copy is still its own document.
        let kept = try h.moveIntoArchive(original.url, to: "Kept/\(original.filename)")
        try await h.reconciler.apply([.found(path: renamed.path)])
        try await h.reconciler.apply([.found(path: kept.path), .gone(path: original.path)])
        let copyNow = try await h.services.documents.document(id: adoptedID)
        let originalMoved = try await h.services.documents.document(id: try #require(original.id))
        #expect(copyNow?.path == renamed.path && originalMoved?.path == kept.path,
                "a document recorded where a file is, with its inode, is that file's, whatever identifier it carries")
    }

    @Test func aDocumentSavedAnewIsStillToldFromACopyMadeWithItsMove() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(original.id)
        // Saved anew, as many apps save: written beside it and put in its place, which gives it another inode.
        let written = original.url.deletingLastPathComponent().appendingPathComponent(".saving")
        try Data("EDP electricity July, annotated".utf8).write(to: written)
        try Xattr.set(Xattr.documentID, original.uid, on: written)
        _ = try FileManager.default.replaceItemAt(original.url, withItemAt: written)
        try await h.reconciler.apply([.found(path: original.path)])
        let copy = h.env.archive.appendingPathComponent("A copy.txt").standardizedFileURL
        try FileManager.default.copyItem(at: original.url, to: copy)
        try Xattr.set(Xattr.documentID, original.uid, on: copy)
        let moved = try h.moveIntoArchive(original.url, to: "Z/\(original.filename)")
        try await h.reconciler.apply([.found(path: copy.path), .found(path: moved.path), .gone(path: original.path)])
        #expect(try await h.services.documents.document(id: id)?.path == moved.path,
                "the inode is kept as the file has it when it is seen where it is, so its copy is still told from it")
    }

    @Test(.enabled(if: Volume.ignoresCase, Volume.needsCaseInsensitive))
    func aFileReportedUnderTheNameItHadBeforeACaseRenameIsNotTakenInUnderIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let lower = try h.env.put("note.txt", text: "put there by hand")
        let upper = lower.deletingLastPathComponent().appendingPathComponent("Note.txt")
        try FileManager.default.moveItem(at: lower, to: upper)
        try await h.reconciler.apply([.found(path: lower.path), .found(path: upper.path), .gone(path: lower.path)])
        #expect(try await h.services.jobs.active().map(\.sourcePath) == [upper.path],
                "nothing is there under the old name, though it finds the file: the file is taken in once, under the name it has")
    }

    @Test func nothingIsMissingAndNothingIsMadeAgainWhileTheArchiveFolderIsNotThere() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let records = h.env.records()
        try await records.flush()
        let away = h.env.root.appendingPathComponent("Archive renamed", isDirectory: true)
        try FileManager.default.moveItem(at: h.env.archive, to: away)
        // As a watcher that took the folder's going for its documents' would report it.
        try await h.reconciler.apply([.gone(path: h.env.archive.standardizedFileURL.path), .gone(path: doc.path)])
        let id = try #require(doc.id)
        let status = try await h.services.documents.document(id: id)?.status
        let missing = try await h.services.history.events(limit: 5, kinds: [.missing])
        #expect(status == .filed && missing.isEmpty, "an archive that is not there, renamed or on a disk that went, has nothing missing from it")
        try await h.services.history.record(.settingsChanged, summary: "a change recorded meanwhile")
        await #expect(throws: RecordsError.self, "its record files are not written") { try await records.flush() }
        #expect(!FileManager.default.fileExists(atPath: h.env.archive.path), "nor is its folder made again where it no longer is")
    }

    @Test func aChangeThatCannotBeAppliedIsSaidSoAndTheOthersAreApplied() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let failing = try h.env.put("failing.txt", text: IngestTests.bill)
        let other = try h.env.put("other.txt", text: "A receipt")
        let reconciler = h.reconciler
        await reconciler.setBeforeApplying { change in
            if change == .found(path: failing.path) { throw Refused() }
        }
        let appliedAll = try await reconciler.apply([.found(path: failing.path), .found(path: other.path)])
        #expect(!appliedAll, "the batch is not all applied, so whoever reported it does not take it as applied")
        #expect(try await h.services.jobs.active().map(\.sourcePath) == [other.path], "the change after the one that failed is applied")
        let said = try #require(try await h.services.history.events(limit: 5, kinds: [.error]).first, "the failure is in History")
        #expect(said.summary.contains(failing.path) && said.summary.contains(Refused.reason), "naming where, and why")
    }

    struct Refused: LocalizedError {
        static let reason = "refused by the test"
        var errorDescription: String? { Self.reason }
    }

    @Test func aCopyAndAMoveOfItsOriginalAreToldApartAfterTheIndexIsRebuilt() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let (database, records) = try w.freshIndex()
        try await records.rebuild()
        let h = w.h.over(database)
        let original = try #require(try await h.services.documents.document(id: w.documents[0]))
        #expect(original.inode == FileOnDisk(original.url)?.number, "a rebuild keeps the inode each document's file has, as it finds it")
        let copy = h.env.archive.appendingPathComponent("A copy.txt").standardizedFileURL
        try FileManager.default.copyItem(at: original.url, to: copy)
        try Xattr.set(Xattr.documentID, original.uid, on: copy)
        let moved = try h.moveIntoArchive(original.url, to: "Z/\(original.filename)")
        try await h.reconciler.apply([.found(path: copy.path), .found(path: moved.path), .gone(path: original.path)])
        #expect(try await h.services.documents.document(id: w.documents[0])?.path == moved.path
                    && Xattr.get(Xattr.documentID, from: moved) == original.uid,
                "after a rebuild too, the document follows its own file, told from the copy by its inode")
    }

    @Test(.fileModesKeepOut) func aCopyWhoseIdentifierCannotBeTakenOffStaysOneDocumentAfterTheIndexIsRebuilt() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let original = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        let copy = w.h.env.archive.appendingPathComponent("bill copy.txt").standardizedFileURL
        try FileManager.default.copyItem(at: original.url, to: copy)
        try Xattr.set(Xattr.documentID, original.uid, on: copy)
        try FileManager.default.setAttributes([.posixPermissions: Self.readOnly], ofItemAtPath: copy.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: Self.writable], ofItemAtPath: copy.path) }
        try await w.h.reconciler.apply([.found(path: copy.path)])
        await w.h.coordinator.drain()
        let adopted = try #require(try await w.h.services.documents.document(path: copy.path)?.id)
        try await w.records.flush()
        let (database, records) = try w.freshIndex()
        try await records.rebuild()
        let h = w.h.over(database)
        let renamed = copy.deletingLastPathComponent().appendingPathComponent("bill copy renamed.txt")
        try FileManager.default.moveItem(at: copy, to: renamed)
        try await h.reconciler.apply([.found(path: renamed.path), .gone(path: copy.path)])
        let followed = try await h.services.documents.document(id: adopted)
        let queued = try await h.services.jobs.active(kinds: [.adopt])
        #expect(followed?.path == renamed.path && queued.isEmpty,
                "after a rebuild too, a copy that still carries its original's identifier is followed by its inode, not taken in again")
    }

    @Test(arguments: [false, true])
    func anInodeIsNoSignOfAMoveWhereTheVolumeGivesItAgainOrTheSizeDiffers(_ volumeKeepsFileIDs: Bool) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: IngestTests.bill)
        let inode = UInt64(bitPattern: try #require(doc.inode))
        try FileManager.default.removeItem(at: doc.url)
        // Made after, and numbered as the document's file was: of its size on a volume that gives numbers again, as exFAT
        // does; of another size on one that does not.
        let text = volumeKeepsFileIDs ? "an unrelated letter of another size" : String(repeating: "x", count: Int(doc.size))
        let unrelated = try h.env.put("letter.txt", text: text)
        let reconciler = h.reconciler
        await reconciler.use(ArchiveDisk(
            file: { url in FileOnDisk(url).map { url.standardizedFileURL.path == unrelated.path ? FileOnDisk(device: $0.device, inode: inode) : $0 } },
            volume: ArchiveDisk.disk.volume, volumeName: ArchiveDisk.disk.volumeName, keepsFileIDs: { _ in volumeKeepsFileIDs }))
        try await reconciler.apply([.found(path: unrelated.path), .gone(path: doc.path)])
        let status = try await h.services.documents.document(id: try #require(doc.id))?.status
        let queued = try await h.services.jobs.active().map(\.sourcePath)
        #expect(status == .missing && queued == [unrelated.path],
                "the document deleted is missing, and the file with its number is new: an inode tells a file only on a volume that keeps it, with its size")
    }

    static let readOnly = 0o444
    static let writable = 0o644
}

extension Harness {
    var reconciler: ArchiveReconciler { ArchiveReconciler(services: services, coordinator: coordinator) }

    /// Moves `url` to `path` below the top of the archive, from wherever it is, as the user would in Finder, making the
    /// folders it needs.
    func moveIntoArchive(_ url: URL, to path: String) throws -> URL {
        let target = env.archive.appendingPathComponent(path).standardizedFileURL
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Moves `url` out of the archive, keeping its name; where it is now.
    func moveOutOfArchive(_ url: URL) throws -> URL {
        let away = env.root.appendingPathComponent("Away", isDirectory: true).appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: away.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: away)
        return away
    }

    /// The documents search by meaning finds for what `StubAnalyzer` embeds every document as; none before it holds a
    /// vector of that model.
    func foundByMeaning() async -> [Int64] {
        let found = try? await services.vectors.topK(StubAnalyzer.embedding, model: StubAnalyzer.embeddingModel, k: env.config.interface.pageSize)
        return (found ?? []).map(\.docID)
    }
}
