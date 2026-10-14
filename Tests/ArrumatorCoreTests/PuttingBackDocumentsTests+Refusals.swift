@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// What refuses a put-back, each on its own: the action throws an error that names the document by its file and says what to
/// do, nothing changes (the file stays in the Trash, nothing is written where it was, the index and History are as they
/// were), and the History listing says the very same before it is asked (`ReviewActions.putBackRefusals`).
extension PuttingBackDocumentsTests {
    /// A document in a world of its own, removed.
    private func removed(status: DocumentStatus = .filed) async throws
        -> (h: Harness, doc: DocumentRecord, event: EventRecord, removal: RemovedPayload) {
        let (h, doc, _, _) = try await Self.world(status: status)
        let docID = try #require(doc.id)
        try await h.review.remove(docID)
        let (event, removal) = try await Self.removal(h)
        return (h, doc, event, removal)
    }

    /// Asserts that putting back `event`'s document throws `error`, naming `name`, that nothing changed, and that the listing
    /// says it too, unless `listed` is false (what only the action sees).
    private func expectRefused(_ error: PutBackError, _ h: Harness, _ event: EventRecord, _ removal: RemovedPayload, name: String,
                               inTrash: Bool = true, listed: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let (id, eventID) = (removal.document, try #require(event.id))
        let (documents, putBacks) = (try await h.services.documents.list(DocumentFilter(), limit: 50).count, try await Self.events(h, .documentPutBack).count)
        await #expect(throws: error, "it is refused so", sourceLocation: sourceLocation) { try await h.review.putBack(id) }
        await #expect(throws: error, "also by the removal's own number", sourceLocation: sourceLocation) {
            try await h.review.putBack(removal: eventID)
        }
        #expect(error.localizedDescription.contains(name), "it names the document by its file: \(error.localizedDescription)", sourceLocation: sourceLocation)
        if let trashed = removal.trashed, inTrash {
            #expect(FileManager.default.fileExists(atPath: trashed), "the file stays in the Trash", sourceLocation: sourceLocation)
        }
        #expect(!FileManager.default.fileExists(atPath: removal.from), "nothing is written where it was", sourceLocation: sourceLocation)
        let after = (try await h.services.documents.list(DocumentFilter(), limit: 50).count, try await Self.events(h, .documentPutBack).count)
        #expect(after == (documents, putBacks) && after.1 == 0, "the index and History are as they were", sourceLocation: sourceLocation)
        if listed {
            let refusals = try await h.review.putBackRefusals(of: [event])
            #expect(refusals == [eventID: error], "the listing says what the action then says", sourceLocation: sourceLocation)
        }
    }

    @Test func aNumberNeverRemovedIsRefused() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        await #expect(throws: PutBackError.notRemoved(document: id), "a document in the archive was never removed") { try await h.review.putBack(id) }
        await #expect(throws: PutBackError.notRemoved(document: 42), "nor was a number that was never a document") { try await h.review.putBack(42) }
        #expect(PutBackError.notRemoved(document: 42).localizedDescription.contains("42"), "the refusal names the number")
        #expect(try await Self.events(h, .documentPutBack).isEmpty, "nothing is recorded")
    }

    /// The three ways an event number is no removal that can be put back: there is no such event, it is of another kind,
    /// and it is a removal whose payload cannot be read.
    @Test func anEventThatIsNoRemovalIsRefusedAsSuchNotAsADocumentNumber() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        try await h.review.remove(id)
        let (removal, _) = try await Self.removal(h)
        let unreadable = try #require(removal.id)
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE events SET payload_json = 'not json' WHERE id = ?", arguments: [unreadable])
        }
        let other = try #require(try await h.services.history.events(limit: 50, kinds: [.arrived]).first?.id)
        for event in [other, unreadable, 424_242] {
            let error = try await #require(throws: PutBackError.self, "event \(event) is no removal") { try await h.review.putBack(removal: event) }
            #expect(error == .noSuchRemoval(event: event), "it says so: \(error)")
            #expect(error.localizedDescription.contains("\(event)") && !error.localizedDescription.contains("Document"),
                    "naming the event number, never as a document's: \(error.localizedDescription)")
        }
        #expect(try await Self.events(h, .documentPutBack).isEmpty && h.env.trashed().count == 1, "nothing is recorded or moved")
        // The listing says what the action says: a removal it cannot read is refused as such, an event of another kind is no row.
        let unreadableEvent = try #require(try await Self.events(h, .documentRemoved).first)
        let otherEvent = try #require(try await h.services.history.events(limit: 50, kinds: [.arrived]).first)
        let refusals = try await h.review.putBackRefusals(of: [unreadableEvent, otherEvent])
        #expect(refusals == [unreadable: .noSuchRemoval(event: unreadable)], "the listing refuses the unreadable removal alone: \(refusals)")
    }

    @Test func aRemovalThatRecordedNoPlaceInTheTrashIsRefused() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        try FileManager.default.removeItem(at: doc.url)
        let docID = try #require(doc.id)
        try await h.review.remove(docID)
        let (event, removal) = try await Self.removal(h)
        #expect(removal.trashed == nil, "the document was missing, so the removal moved nothing")
        try await expectRefused(.nothingInTrash(name: doc.filename), h, event, removal, name: doc.filename)
    }

    @Test func aFileNoLongerInTheTrashIsRefused() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        let trashed = try #require(removal.trashed)
        // Taken out by hand, as Finder's Put Back does.
        let away = h.env.root.appendingPathComponent("Away.txt")
        try FileManager.default.moveItem(atPath: trashed, toPath: away.path)
        try await expectRefused(.noLongerInTrash(name: doc.filename, trashed: trashed), h, event, removal, name: doc.filename, inTrash: false)
        #expect(FileManager.default.fileExists(atPath: away.path), "and the file taken out is not touched")
    }

    /// A file with no identifier, as a copy or a synchronisation leaves one (it is the document's own, as `remove` takes it), is
    /// known by its size and checksum alone: of other content it is not the document's file, though the listing, which never
    /// hashes, cannot tell.
    @Test func aFileInTheTrashWithoutAnIdentifierAndOfOtherContentIsNotMoved() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        let trashed = try #require(removal.trashed)
        let url = URL(fileURLWithPath: trashed)
        try Xattr.remove(Xattr.documentID, from: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(String(repeating: "x", count: Int(doc.size)).utf8))
        try handle.close()
        try await expectRefused(.notItsFile(name: doc.filename, trashed: trashed), h, event, removal, name: doc.filename, listed: false)
    }

    @Test func aFileInTheTrashWithAnotherIdentifierIsNotMoved() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        let trashed = try #require(removal.trashed)
        try Xattr.set(Xattr.documentID, "another-document", on: URL(fileURLWithPath: trashed))
        try await expectRefused(.notItsFile(name: doc.filename, trashed: trashed), h, event, removal, name: doc.filename)
    }

    @Test func aFileInTheTrashOfAnotherSizeIsNotMoved() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        let trashed = try #require(removal.trashed)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: trashed))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" and more".utf8))
        try handle.close()
        try await expectRefused(.notItsFile(name: doc.filename, trashed: trashed), h, event, removal, name: doc.filename)
    }

    @Test func aFileInTheTrashOfTheSameSizeButOtherBytesIsNotMovedThoughTheListingCannotTell() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        let trashed = try #require(removal.trashed)
        // Overwritten in place with other bytes of the same length, its identifier kept: only hashing it tells.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: trashed))
        try handle.write(contentsOf: Data(String(repeating: "x", count: Int(doc.size)).utf8))
        try handle.close()
        #expect(try await h.review.putBackRefusals(of: [event]).isEmpty, "the listing, which never hashes, does not see it")
        try await expectRefused(.notItsFile(name: doc.filename, trashed: trashed), h, event, removal, name: doc.filename, listed: false)
    }

    @Test func aRemovalPutBackAlreadyIsRefused() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        let eventID = try #require(event.id)
        try await h.review.putBack(id)
        await #expect(throws: PutBackError.alreadyPutBack(name: doc.filename), "put back twice") { try await h.review.putBack(id) }
        await #expect(throws: PutBackError.alreadyPutBack(name: doc.filename), "and by the removal's own number") {
            try await h.review.putBack(removal: eventID)
        }
        let listed = try await h.review.putBackRefusals(of: [event])
        #expect(listed == [eventID: .alreadyPutBack(name: doc.filename)], "the listing says it too, so History offers it no more")
        #expect(try await Self.events(h, .documentPutBack).count == 1 && h.env.trashed().isEmpty && removal.trashed != nil,
                "one event, and the file is not moved again")
    }

    @Test func aDocumentOfTheSameIdentityInTheIndexIsRefusedNamingIt() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        // Another document, filed beside it under a name of its own, takes its identity once it is removed, as a copy of the
        // file made and filed again would.
        let other = try await h.ingest("other.txt", text: "Another letter about something else.")
        try await h.review.remove(try #require(doc.id))
        let (event, removal) = try await Self.removal(h)
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET uid = ? WHERE id = ?", arguments: [doc.uid, other.id])
        }
        let otherID = try #require(other.id)
        let there = try #require(try await h.services.documents.document(id: otherID))
        try await expectRefused(.sameDocumentThere(name: doc.filename, other: there.filename), h, event, removal, name: doc.filename)
        #expect(PutBackError.sameDocumentThere(name: doc.filename, other: there.filename).localizedDescription.contains(there.filename),
                "it names the document the archive holds")
    }

    @Test func aRemovalAnEarlierReleaseRecordedIsRefusedSayingHowToHaveItBackByHand() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        // As the release before the entry was kept recorded it.
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE events SET payload_json = json_remove(payload_json, '$.entry') WHERE id = ?", arguments: [event.id])
        }
        let earlier = try #require(try await Self.events(h, .documentRemoved).first)
        let error = PutBackError.removedBeforeEntriesKept(name: doc.filename)
        try await expectRefused(error, h, earlier, removal, name: doc.filename)
        #expect(error.localizedDescription.contains("put its file into Incoming from the Trash"), "and says what to do")
    }

    @Test func anArchiveWhoseFolderIsNotThereIsRefusedNamingIt() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        try FileManager.default.moveItem(at: h.env.archive, to: h.env.root.appendingPathComponent("ArchiveAway"))
        let error = PutBackError.archiveNotThere(h.services.archive.path)
        try await expectRefused(error, h, event, removal, name: h.services.archive.path)
        #expect(!FileManager.default.fileExists(atPath: h.env.archive.path), "and the folder is not made again")
        _ = doc
    }

    @Test func aFolderInNeitherTheArchiveNorIncomingAsTheyAreNowIsRefusedNamingIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        try await h.review.undo(id)
        let doc = try #require(try await h.services.documents.document(id: id))
        try await h.review.remove(id)
        let (event, removal) = try await Self.removal(h)
        // Incoming changed in Settings while it was removed.
        let elsewhere = h.env.root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try await h.env.settings.update { $0.incomingPath = elsewhere.path }
        let folder = URL(fileURLWithPath: removal.from).deletingLastPathComponent().path
        try await expectRefused(.outsideFolders(name: doc.filename, folder: folder), h, event, removal, name: folder)
    }

    @Test func removedPutBackAndRemovedAgainThePutBackIsOfTheLatestRemoval() async throws {
        let (h, doc, _, _) = try await Self.world()
        defer { h.env.cleanup() }
        let id = try #require(doc.id)
        try await h.review.remove(id)
        let first = try #require(try await Self.events(h, .documentRemoved).first)
        try await h.review.putBack(id)
        try await h.review.remove(id)
        let second = try #require(try await Self.events(h, .documentRemoved).first)
        #expect(first.id != second.id, "two removals are recorded")
        let back = try await h.review.putBack(id)
        #expect(back.removal == second.id, "the latest removal not yet put back is the one put back")
        let firstID = try #require(first.id)
        await #expect(throws: PutBackError.alreadyPutBack(name: doc.filename), "the earlier one is reported as put back already") {
            try await h.review.putBack(removal: firstID)
        }
        #expect(try await Self.events(h, .documentPutBack).count == 2, "each put-back is recorded once")
    }

    /// Where a record somebody edited puts the file it names.
    enum CraftedPlace: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case elsewhere, throughDotDotOutOfTheTrash, besideTheTrashWithItsBeginningInItsName
        var testDescription: String { rawValue }
    }

    /// History is a record file a person can edit: what it names as the place in the Trash is not trusted to name any file.
    @Test(arguments: CraftedPlace.allCases)
    func aPlaceOutsideTheTrashIsRefusedAndNothingThereIsTouched(_ place: CraftedPlace) async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        let trashed = try #require(removal.trashed)
        // A file the record names with the document's size, checksum and identifier: all else it says is true of it.
        let folder = place == .besideTheTrashWithItsBeginningInItsName ? h.env.trash.folder.appendingPathExtension("other")
            : h.env.root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = folder.appendingPathComponent("secret.txt")
        try FileManager.default.copyItem(atPath: trashed, toPath: outside.path)
        #expect(Xattr.get(Xattr.documentID, from: outside) == doc.uid, "the copy carries the document's identifier")
        let named = place == .throughDotDotOutOfTheTrash ? h.env.trash.folder.path + "/../Elsewhere/secret.txt" : outside.path
        let edited = try await Self.rewrite(h, event) { $0.trashed = named }
        var crafted = removal
        crafted.trashed = named
        try await expectRefused(.notInTrash(name: doc.filename, trashed: named), h, edited, crafted, name: named)
        #expect(FileManager.default.fileExists(atPath: outside.path) && FileManager.default.fileExists(atPath: trashed),
                "the file it names, and the one in the Trash, are where they were")
    }

    @Test func aLinkInTheTrashIsNotItsFileThoughItPointsAtOneThatIs() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        let trashed = try #require(removal.trashed)
        let target = h.env.root.appendingPathComponent("Target.txt")
        try FileManager.default.copyItem(atPath: trashed, toPath: target.path)
        try FileManager.default.removeItem(atPath: trashed)
        try FileManager.default.createSymbolicLink(atPath: trashed, withDestinationPath: target.path)
        // The record names the link's own size, as one made to pass the size check would; the target hashes as the document.
        let linkSize = try #require((try FileManager.default.attributesOfItem(atPath: trashed)[.size] as? NSNumber)?.int64Value)
        let edited = try await Self.rewrite(h, event) { $0.entry?.size = linkSize }
        try await expectRefused(.notItsFile(name: doc.filename, trashed: trashed), h, edited, removal, name: doc.filename)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: trashed) == target.path && FileManager.default.fileExists(atPath: target.path),
                "the link and its target are where they were")
    }

    @Test func aPackageInTheTrashOfMoreItemsThanADocumentMayHoldIsNotWeighedAndIsNotItsFile() async throws {
        let (whole, doc, event, removal) = try await removed()
        let h = whole.with { $0.watcher.maxPackageItems = 3 }
        defer { h.env.cleanup() }
        let package = URL(fileURLWithPath: try #require(removal.trashed)).deletingLastPathComponent().appendingPathComponent("notes.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for index in 1...5 { try Data("0123456789".utf8).write(to: package.appendingPathComponent("part\(index).txt")) }
        try Xattr.set(Xattr.documentID, doc.uid, on: package)
        // Its size is what the record says: only the walk that stops at the limit refuses it.
        let edited = try await Self.rewrite(h, event) {
            $0.trashed = package.path
            $0.entry?.size = 50
        }
        var crafted = removal
        crafted.trashed = package.path
        try await expectRefused(.notItsFile(name: doc.filename, trashed: package.path), h, edited, crafted, name: doc.filename)
    }

    @Test func aMovedArchiveIsRefusedNamingTheFolderTheDocumentWasIn() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        let archive = h.env.root.appendingPathComponent("New Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let moved = h.env.with(archive: archive)
        let after = Harness(env: moved, services: Harness.services(moved, analyzer: h.services.analyzer, config: h.services.config))
        let folder = URL(fileURLWithPath: removal.from).deletingLastPathComponent().path
        try await expectRefused(.outsideFolders(name: doc.filename, folder: folder), after, event, removal, name: folder)
    }

    @Test func everyRefusalNamesTheDocumentByTheFileTheAppShowedNotTheNameOfAPlannedMove() async throws {
        let (h, doc, event, removal) = try await removed()
        defer { h.env.cleanup() }
        // Removed while reading it again had planned its move: the place recorded is the planned one, with another name.
        let planned = URL(fileURLWithPath: removal.from).deletingLastPathComponent().appendingPathComponent("Planned name.txt").path
        let edited = try await Self.rewrite(h, event) { $0.from = planned }
        var crafted = removal
        crafted.from = planned
        let trashed = try #require(removal.trashed)
        try FileManager.default.removeItem(atPath: trashed)
        try await expectRefused(.noLongerInTrash(name: doc.filename, trashed: trashed), h, edited, crafted, name: doc.filename, inTrash: false)
        #expect(doc.filename != "Planned name.txt" && Removal(edited)?.name == doc.filename, "by the entry's file, the one the removal row shows")
    }

    @Test func aFolderRecordedThroughALinkToTheArchiveComesBackToItsFolderBelowIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let filed = try await h.ingest("bill.txt", text: IngestTests.bill)
        let id = try #require(filed.id)
        let moved = try h.moveIntoArchive(filed.url, to: "Taxes/\(filed.filename)")
        try await h.reconciler.apply([.found(path: moved.path), .gone(path: filed.path)])
        try await h.review.remove(id)
        // The record spells the archive by a link to it, as when the archive was moved and a link left at its old place.
        let link = h.env.root.appendingPathComponent("Old Archive Place")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: h.env.archive)
        let (event, _) = try await Self.removal(h)
        try await Self.rewrite(h, event) { $0.from = link.path + "/Taxes/" + filed.filename }

        let back = try await h.review.putBack(id)
        #expect(back.to == moved.spelledOnDisk.path, "it is in its folder, Taxes, below the archive: \(back.to)")
        let put = try #require(try await Self.events(h, .documentPutBack).first)
        #expect(!put.summary.contains("its folder is gone"), "and History does not say its folder is gone: \(put.summary)")
    }
}
