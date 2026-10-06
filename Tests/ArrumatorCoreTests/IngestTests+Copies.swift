@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// An exact copy is handed over to its original once it is decided, whatever becomes of the original meanwhile, and a
/// file in the archive is never taken for an arrival (the review of the fix of the final review of #17).
extension IngestTests {
    /// How the original stops being in the archive as itself while its copy is compared with it: undone, back in
    /// Incoming; found missing; or recorded elsewhere than the archive.
    enum Gone: String, CaseIterable, Sendable { case undone, missing, elsewhere }

    /// An exact copy of a document the user undoes while the copy is compared with it is no copy of it any more: it is
    /// read in as a document of its own, the original left as the user left it.
    @Test(arguments: Gone.allCases)
    func aCopyOfADocumentUndoneMeanwhileIsADocumentOfItsOwn(_ gone: Gone) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        // A Trash that would refuse it: the copy, a document of its own, is filed, never sent there.
        var services = base.services
        services.trash = RefusingTrash()
        let h = Harness(env: base.env, services: services)
        let originalID = try #require(original.id)
        // Undone as the copy is found to be one, its bytes compared: as the user's undo in that instant leaves it.
        let incoming = h.env.incoming.appendingPathComponent("bill.txt").path.replacingOccurrences(of: "'", with: "''")
        // Recorded elsewhere, its file there too: only that it is not in the archive tells it from an original.
        if gone == .elsewhere { _ = try base.env.drop("bill.txt", text: Self.bill) }
        let change = switch gone {
        case .undone: "status = 'undone', path = '\(incoming)'"
        case .missing: "status = 'missing'"
        case .elsewhere: "path = '\(incoming)'"
        }
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER undone_as_compared AFTER INSERT ON trace_steps WHEN NEW.stage = 'dedupe' BEGIN
                  UPDATE documents SET \(change) WHERE id = \(originalID);
                END
                """)
        }
        let copy = try #require(await h.coordinator.enqueue(try h.env.drop("copy.txt", text: Self.bill)))
        await h.coordinator.drain()
        let job = try #require(try await h.services.jobs.job(id: copy))
        #expect(job.state == .done && job.docId != nil && job.docId != originalID, "\(gone): the copy is read in as a document of its own")
        #expect(job.lastError == nil, "\(gone): and nothing is sent to the Trash, which would refuse it")
        let again = try await h.jobs().filter { $0.kind == .reanalyse }
        #expect(again.isEmpty, "and is not read again for it: \(again)")
    }

    /// A copy found one before a stop, still in Incoming, whose original the user undid meanwhile is no copy of it any
    /// more at the next start: it is read in as a document of its own, kept with its job as no copy.
    @Test func aCopyFoundBeforeAStopWhoseOriginalIsUndoneMeanwhileIsADocumentOfItsOwn() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: Self.bill)
        let originalID = try #require(original.id)
        let copy = try h.env.drop("copy.txt", text: Self.bill)
        let id = try #require(await h.coordinator.enqueue(copy))
        // As a stop leaves it once the copy was found one, kept with what it was when it was hashed, before it went to
        // the Trash; the original then undone.
        var job = try #require(try await h.services.jobs.job(id: id))
        var payload = try job.payload
        let hashed = try FileFingerprint.of(copy)
        (payload.copyOf, payload.size, payload.mtime, payload.inode) = (originalID, hashed.size, hashed.modified, hashed.inode)
        try job.setPayload(payload)
        job.state = .hashing
        let stopped = job
        let incoming = h.env.incoming.appendingPathComponent("bill.txt")
        try FileManager.default.moveItem(at: original.url, to: incoming)
        try await h.env.database.writer.write { db in
            try stopped.update(db)
            try db.execute(sql: "UPDATE documents SET status = 'undone', path = ? WHERE id = ?",
                           arguments: [incoming.spelledOnDisk.path, originalID])
        }
        await h.coordinator.drain()
        let read = try #require(try await h.services.jobs.job(id: id))
        #expect(read.state == .done && read.docId != nil && read.docId != originalID, "the copy is read in as a document of its own")
        #expect(try read.payload.copyOf == nil, "and its job no longer says it is a copy")
        #expect(h.env.trashed().isEmpty, "nothing goes to the Trash")
    }

    /// What becomes of an original once its copy is in the Trash, before its reading is queued: undone back into
    /// Incoming, where the copy was; its file removed from the archive; or kept, while the user puts another file where
    /// the copy was.
    enum Meanwhile: String, CaseIterable, Sendable { case undone, removed, replaced }

    /// A copy is done with once it is in the Trash, whatever becomes of its original meanwhile, as though the user did it
    /// after: it stays there, recorded under its original, which is read again only while it is in the archive as
    /// itself; and the file put where the copy was is never taken for it.
    @Test(arguments: Meanwhile.allCases)
    func aCopyInTheTrashIsHandedOverWhateverBecomesOfItsOriginalMeanwhile(_ meanwhile: Meanwhile) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        let originalID = try #require(original.id)
        // Where the original was when it came, which undoing it gives back once the copy has left it.
        let copy = try base.env.drop("bill.txt", text: Self.bill)
        var services = base.services
        let analyzer = StubAnalyzer()
        services.analyzer = analyzer
        services.trash = TrashThen(trash: base.env.trash) {
            switch meanwhile {
            case .undone:
                try FileManager.default.moveItem(at: original.url, to: copy)
                try base.env.database.writer.write { db in
                    try db.execute(sql: "UPDATE documents SET status = 'undone', path = ? WHERE id = ?",
                                   arguments: [copy.spelledOnDisk.path, originalID])
                }
            case .removed: try FileManager.default.removeItem(at: original.url)
            case .replaced: try Data("Water bill August".utf8).write(to: copy)
            }
        }
        let coordinator = IngestCoordinator(services: services)
        let id = try #require(await coordinator.enqueue(copy))
        await coordinator.drain()

        let job = try #require(try await services.jobs.job(id: id))
        let copyOf = try job.payload.copyOf
        #expect(job.state == .duplicate && copyOf == originalID, "\(meanwhile): the copy is handed over")
        #expect(base.env.trashed().count == 1, "\(meanwhile): and stays in the Trash")
        let read = meanwhile == .replaced
        let said = read ? "which is read again" : "which has left the archive since, and is not read again"
        let events = try await services.history.events(limit: 5, kinds: [.duplicate])
        #expect(events.map(\.docId) == [originalID]
                    && events.first?.summary == "bill.txt is a copy of \(original.filename), \(said); the copy is in the Trash",
                "\(meanwhile): History records it once, under its original: \(events.map(\.summary))")
        let others = try await services.documents.list(DocumentFilter(), limit: 5).filter { $0.id != originalID }
        let files = await analyzer.calls.files
        if read {
            #expect(Set(files) == [original.filename, "bill.txt"] && files.count == 2,
                    "its original is read again, and the file put in the copy's place read in its own turn: \(files)")
            #expect(others.count == 1 && others.first?.sha256 != original.sha256 && others.first?.status == .filed,
                    "a document of its own: \(others.map(\.path))")
        } else {
            #expect(files.isEmpty, "\(meanwhile): its original is not read again, nor its file taken for the copy: \(files)")
            #expect(others.isEmpty, "\(meanwhile): and no second document is made of it: \(others.map(\.path))")
        }
        if meanwhile == .undone {
            let undone = try #require(try await services.documents.document(id: originalID))
            #expect(undone.status == .undone && FileManager.default.fileExists(atPath: copy.path),
                    "the original stays as the user left it, back in Incoming")
        }
    }

    /// What is at a copy's path at the next start, the copy in the Trash since a stop: its original, undone back where
    /// it was; the same, but alike in all that a volume that keeps no file numbers tells, as a copy that kept its date;
    /// the same, then left for later; or another file the user put there, of the copy's size and date, its original
    /// still in the archive.
    enum AtTheCopysPath: String, CaseIterable, Sendable { case undone, undoneAlike, leftForLaterAlike, another }

    /// A copy in the Trash when a stop came, before its original's reading was queued, is still handed over at the next
    /// start, whatever is at its path then: History never says the copy disappeared, and the file there is never taken
    /// for the copy, an undone original neither read again nor made a second document.
    @Test(arguments: AtTheCopysPath.allCases)
    func aCopyInTheTrashAtAStopIsHandedOverWhateverIsAtItsPathAtTheNextStart(_ found: AtTheCopysPath) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        let originalID = try #require(original.id)
        var services = base.with { $0.ingest.retryDelays = NonEmpty(60, []) }.services
        let analyzer = StubAnalyzer()
        services.analyzer = analyzer
        let coordinator = IngestCoordinator(services: services)
        // Queueing the original to be read again fails once the copy is in the Trash, as a stop there leaves it.
        try await base.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER queueing_fails BEFORE INSERT ON jobs WHEN NEW.kind = '\(JobKind.reanalyse.rawValue)'
                  AND (SELECT COUNT(*) FROM events WHERE kind = '\(EventKind.retry.rawValue)') = 0
                BEGIN SELECT RAISE(ABORT, 'the queue is briefly unavailable'); END
                """)
        }
        let copy = try base.env.drop("bill.txt", text: Self.bill)
        let date = try #require(try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copy.path)
        let id = try #require(await coordinator.enqueue(copy))
        await coordinator.drain()
        #expect(base.env.trashed().count == 1, "\(found): the copy went to the Trash before the stop")
        switch found {
        case .undone, .undoneAlike, .leftForLaterAlike:
            let review = ReviewActions(services: services, coordinator: coordinator)
            try await review.undo(originalID)
            #expect(FileManager.default.fileExists(atPath: copy.path), "\(found): the original is back where the copy was")
            if found == .leftForLaterAlike { try await review.hold(originalID) }
            if found != .undone {
                try await base.env.database.writer.write { db in
                    try db.execute(sql: "UPDATE jobs SET payload_json = json_remove(payload_json, '$.inode') WHERE id = ?", arguments: [id])
                }
            }
        case .another:
            try Data("Water bill of August".utf8).write(to: copy)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copy.path)
        }
        base.env.time.advance(by: 60)
        await coordinator.drain()

        let job = try #require(try await services.jobs.job(id: id))
        let copyOf = try job.payload.copyOf
        #expect(job.state == .duplicate && copyOf == originalID, "\(found): the copy is handed over")
        let events = try await services.history.events(limit: 10, kinds: [.duplicate, .missing])
        let said = found == .another ? "bill.txt is a copy of \(original.filename), which is read again"
            : "bill.txt is a copy of bill.txt, which has left the archive since, and is not read again"
        #expect(events.map(\.kind) == [.duplicate] && events.first?.docId == originalID && events.first?.summary == said,
                "\(found): recorded once, under its original, named as it is now, never as a file that disappeared: \(events.map(\.summary))")
        #expect(base.env.trashed().count == 1, "\(found): the copy stays in the Trash, and nothing else goes there")
        let documents = try await services.documents.list(DocumentFilter(), limit: 5)
        let files = await analyzer.calls.files
        if found == .another {
            #expect(Set(files) == [original.filename, "bill.txt"] && files.count == 2,
                    "its original is read again, and the file put in the copy's place read in its own turn: \(files)")
            #expect(documents.count == 2 && documents.allSatisfy { $0.status == .filed }, "a document of its own: \(documents.map(\.path))")
        } else {
            #expect(files.isEmpty, "\(found): the undone original is neither read again nor read as the copy: \(files)")
            #expect(documents.map(\.id) == [originalID] && documents.first?.status.isSetAside == true,
                    "\(found): it stays as the user left it, and no second document is made of it: \(documents.map(\.path))")
        }
    }

    /// What follows a copy that is a document of its own, as one the Trash would not take, read again once it does,
    /// handed over: a stop once it is in the Trash, at whose next start its original, undone back where it was, is that
    /// file or alike in all that a volume that keeps no file numbers tells; or no stop, its original undone afterwards,
    /// found there by a rescan.
    enum Afterwards: String, CaseIterable, Sendable { case stopped, stoppedAlike, rescanned }

    /// The original of a copy that was a document of its own, undone back where the copy was, is never taken for the
    /// copy, nor read in as a new document, though the copy's own document is recorded at that path too.
    @Test(arguments: Afterwards.allCases)
    func anOriginalUndoneWhereItsCopyOfItsOwnWasIsNeverReadInForIt(_ afterwards: Afterwards) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        let originalID = try #require(original.id)
        let copy = try base.env.drop("bill.txt", text: Self.bill)
        let date = try #require(try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copy.path)
        // Left in Incoming as a document of its own, as the Trash would not take it.
        var refusing = base.services
        refusing.trash = RefusingTrash()
        let refused = IngestCoordinator(services: refusing)
        await refused.enqueue(copy)
        await refused.drain()
        let own = try #require(try await base.services.documents.list(DocumentFilter(), limit: 5).first { $0.id != originalID }?.id)
        var services = base.with { $0.ingest.retryDelays = NonEmpty(60, []) }.services
        let analyzer = StubAnalyzer()
        services.analyzer = analyzer
        let coordinator = IngestCoordinator(services: services)
        let review = ReviewActions(services: services, coordinator: coordinator)
        // Read again once the Trash takes it; a stop, once it is in the Trash, before its original's reading is queued.
        let stops = afterwards != .rescanned
        if stops {
            try await base.env.database.writer.write { db in
                try db.execute(sql: """
                    CREATE TEMP TRIGGER queueing_fails BEFORE INSERT ON jobs WHEN NEW.kind = '\(JobKind.reanalyse.rawValue)'
                    BEGIN SELECT RAISE(ABORT, 'the queue is briefly unavailable'); END
                    """)
            }
        }
        try await review.retry(own)
        await coordinator.drain()
        #expect(base.env.trashed().count == 1, "\(afterwards): the copy is in the Trash")
        try await review.undo(originalID)
        #expect(FileManager.default.fileExists(atPath: copy.path), "\(afterwards): the original is back where the copy was")
        try await base.env.database.writer.write { db in
            if stops { try db.execute(sql: "DROP TRIGGER queueing_fails") }
            if afterwards == .stoppedAlike {
                try db.execute(sql: "UPDATE jobs SET payload_json = json_remove(payload_json, '$.inode') WHERE doc_id = ?", arguments: [own])
            }
        }
        base.env.time.advance(by: 60)
        if afterwards == .rescanned { await coordinator.enqueue(copy) }
        await coordinator.drain()

        let documents = try await services.documents.list(DocumentFilter(), limit: 5)
        #expect(Set(documents.map(\.id)) == [originalID, own], "\(afterwards): no other document is made: \(documents.map(\.path))")
        let undone = try #require(documents.first { $0.id == originalID })
        #expect(undone.status == .undone && FileManager.default.fileExists(atPath: undone.path),
                "\(afterwards): the original stays as the user left it, its file where it is")
        #expect(documents.first { $0.id == own }?.status == .duplicate, "\(afterwards): the copy's own document ends a copy")
        #expect(await analyzer.calls.files == (stops ? [] : [original.filename]),
                "\(afterwards): the original is read again only while it was in the archive, never as the copy")
        let events = try await services.history.events(limit: 10, kinds: [.duplicate, .missing])
        #expect(events.map(\.kind) == [.duplicate] && events.first?.docId == originalID,
                "\(afterwards): the copy is recorded once, under its original: \(events.map(\.summary))")
    }

    /// A copy of a document in the archive waiting for the user, set aside after failing, left for later, or being read
    /// again is handed over to it, which is read again in its place, once.
    @Test(arguments: [DocumentStatus.needsReview, .failed, .held, .processing])
    func aCopyOfADocumentInTheArchiveHasItReadAgainWhereverItStands(_ status: DocumentStatus) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        let originalID = try #require(original.id)
        try await base.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET status = ? WHERE id = ?", arguments: [status.rawValue, originalID])
        }
        var services = base.services
        let analyzer = StubAnalyzer()
        services.analyzer = analyzer
        let coordinator = IngestCoordinator(services: services)
        let id = try #require(await coordinator.enqueue(try base.env.drop("bill copy.txt", text: Self.bill)))
        await coordinator.drain()

        let job = try #require(try await services.jobs.job(id: id))
        let copyOf = try job.payload.copyOf
        #expect(job.state == .duplicate && copyOf == originalID, "\(status): the copy is handed over")
        #expect(base.env.trashed().map(\.lastPathComponent) == ["bill copy.txt"], "\(status): and goes to the Trash")
        #expect(await analyzer.calls.files == [original.filename], "\(status): its original is read again in its place")
    }

    /// Two copies of a document left for later, put into Incoming together, are both handed over to it, though the
    /// first has it read again: it is read again once, and no second document is made of it.
    @Test func twoCopiesOfADocumentLeftForLaterAreBothHandedOverToIt() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        let originalID = try #require(original.id)
        try await base.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET status = 'held' WHERE id = ?", arguments: [originalID])
        }
        var services = base.services
        let analyzer = StubAnalyzer()
        services.analyzer = analyzer
        let coordinator = IngestCoordinator(services: services)
        let first = try #require(await coordinator.enqueue(try base.env.drop("bill copy.txt", text: Self.bill)))
        let second = try #require(await coordinator.enqueue(try base.env.drop("bill copy 2.txt", text: Self.bill)))
        await coordinator.drain()

        for id in [first, second] {
            let job = try #require(try await services.jobs.job(id: id))
            let copyOf = try job.payload.copyOf
            #expect(job.state == .duplicate && copyOf == originalID, "each copy is handed over: \(job.sourcePath)")
        }
        let documents = try await services.documents.list(DocumentFilter(), limit: 5)
        #expect(documents.map(\.id) == [originalID], "no second document is made of it: \(documents.map(\.path))")
        #expect(await analyzer.calls.files == [original.filename], "it is read again once")
    }

    /// A copy whose hand-over stopped once its original, left for later, was queued to be read again finishes at the
    /// next attempt saying its original is read again, as it is.
    @Test func aCopyOfADocumentLeftForLaterStoppedOnceItsReadingWasQueuedSaysItIsReadAgain() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        let originalID = try #require(original.id)
        var services = base.with { $0.ingest.retryDelays = NonEmpty(0, []) }.services
        let analyzer = StubAnalyzer()
        services.analyzer = analyzer
        let coordinator = IngestCoordinator(services: services)
        // Left for later; recording the copy fails once, after its original's reading was queued.
        try await base.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET status = 'held' WHERE id = ?", arguments: [originalID])
            try db.execute(sql: """
                CREATE TEMP TRIGGER recording_fails_once BEFORE INSERT ON events
                WHEN NEW.kind = '\(EventKind.duplicate.rawValue)' AND (SELECT COUNT(*) FROM events WHERE kind = '\(EventKind.retry.rawValue)') = 0
                BEGIN SELECT RAISE(ABORT, 'History is briefly unavailable'); END
                """)
        }
        let id = try #require(await coordinator.enqueue(try base.env.drop("bill copy.txt", text: Self.bill)))
        await coordinator.drain()

        let job = try #require(try await services.jobs.job(id: id))
        #expect(job.state == .duplicate, "the copy is handed over at the next attempt")
        let events = try await services.history.events(limit: 5, kinds: [.duplicate]).map(\.summary)
        #expect(events == ["bill copy.txt is a copy of \(original.filename), which is read again"],
                "History says its original is read again: \(events)")
        #expect(await analyzer.calls.files == [original.filename], "as it is, once")
    }

    /// A copy put where documents set aside one after another were, their files gone since, is handed over once, and
    /// goes to the Trash: every document set aside there is ended as the copy comes, not the one named first alone, so
    /// none is left recorded where its file is not, to be taken for the copy's file.
    @Test func aCopyPutWhereDocumentsSetAsideOneAfterAnotherWereIsHandedOverOnce() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        let originalID = try #require(original.id)
        let path = base.env.incoming.appendingPathComponent("scan.txt").spelledOnDisk.path
        var aside: [Int64] = []
        for _ in 0..<2 {
            var record = DocumentRecord.arrived(path: path, sha256: "another", size: 1, uttype: "public.plain-text", inode: nil,
                                                modified: nil, now: base.env.time.now())
            record.status = .undone
            aside.append(try #require(try await base.services.documents.save(record).id))
        }
        var services = base.services
        let analyzer = StubAnalyzer()
        services.analyzer = analyzer
        let coordinator = IngestCoordinator(services: services)
        let id = try #require(await coordinator.enqueue(try base.env.drop("scan.txt", text: Self.bill)))
        await coordinator.drain()

        let job = try #require(try await services.jobs.job(id: id))
        let copyOf = try job.payload.copyOf
        #expect(job.state == .duplicate && copyOf == originalID, "the copy is handed over")
        #expect(base.env.trashed().map(\.lastPathComponent) == ["scan.txt"], "and goes to the Trash")
        let events = try await services.history.events(limit: 10, kinds: [.duplicate]).map(\.summary)
        #expect(events == ["scan.txt is a copy of \(original.filename), which is read again; the copy is in the Trash"],
                "recorded once: \(events)")
        #expect(await analyzer.calls.files == [original.filename], "its original is read again once")
        for document in aside {
            #expect(try await services.documents.document(id: document)?.status == .missing, "each set aside there is ended")
        }
    }

    /// Of the documents recorded at one path, as an original undone back where its copy, a document of its own, was
    /// before the copy went to the Trash, the path names one whose file may be there before any that ended there:
    /// missing, or a copy gone to the Trash.
    @Test func aPathNamesADocumentWhoseFileMayBeThereBeforeOnesThatEndedThere() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let path = h.env.incoming.appendingPathComponent("bill.txt").path
        var ids: [Int64] = []
        for status in [DocumentStatus.undone, .duplicate, .missing] {
            var record = DocumentRecord.arrived(path: path, sha256: "sha", size: 1, uttype: "public.plain-text", inode: nil,
                                                modified: nil, now: h.env.time.now())
            record.status = status
            ids.append(try #require(try await h.services.documents.save(record).id))
        }
        #expect(try await h.services.documents.document(path: path)?.id == ids.first, "the undone one, though those that ended are newer")
    }

    /// What a file in the archive is to a request to file it, as `arrumatorcli ingest` makes: a document's own, named
    /// as it is recorded or through `/private`, or one the user put there, not read yet.
    enum InArchive: String, CaseIterable, Sendable { case own, ownSpelledOtherwise, put }

    /// A file in the archive is never queued as an arrival: a document's own is that document, never a second one, and
    /// one the user put there is read where it is, never sent to the Trash as a copy.
    @Test(arguments: InArchive.allCases)
    func aFileInTheArchiveIsNeverQueuedAsAnArrival(_ file: InArchive) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let document = try await h.ingest("bill.txt", text: Self.bill)
        let put = h.env.archive.appendingPathComponent("bill copy.txt")
        try Data(Self.bill.utf8).write(to: put)
        let path = document.path
        let url = switch file {
        case .own: document.url
        case .ownSpelledOtherwise: URL(fileURLWithPath: path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path)
        case .put: put
        }
        #expect(await h.coordinator.enqueue(url) == nil, "\(file): it is not queued")
        await h.coordinator.drain()
        let documents = try await h.services.documents.list(DocumentFilter(), limit: 5)
        #expect(documents.map(\.id) == [document.id], "\(file): no document is made of it: \(documents.map(\.path))")
        #expect(FileManager.default.fileExists(atPath: put.path) && h.env.trashed().isEmpty, "\(file): nothing goes to the Trash")
    }
}

/// A Trash that takes a file as `trash` does, then has the user act in that instant, as on the copy's original.
private struct TrashThen: Trashing {
    let trash: any Trashing
    let then: @Sendable () throws -> Void

    func trash(_ url: URL) throws -> URL? {
        let put = try trash.trash(url)
        try then()
        return put
    }
}
