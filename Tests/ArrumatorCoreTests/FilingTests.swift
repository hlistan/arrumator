import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// How a document is moved into the archive and named there: a package whole, a file to another volume through the Trash
/// the app was given, a file changed since it was read not as what was read, and a document read again under the name it
/// already has without being moved.
@Suite struct FilingTests {
    /// The pipeline as after the user chose a profile whose model gives `analyzer`'s answers, and what the user does
    /// with documents through it.
    private func reading(_ h: Harness, with analyzer: StubAnalyzer) -> (coordinator: IngestCoordinator, review: ReviewActions) {
        var services = h.services
        services.analyzer = analyzer
        let coordinator = IngestCoordinator(services: services)
        return (coordinator, ReviewActions(services: services, coordinator: coordinator))
    }

    /// How a file moved before a crash is known where it went: by the identity the move gave it, or, when the crash came
    /// before that, by its bytes; and a file there that says it is another document, or whose path another document's row
    /// holds, is not taken for it.
    enum KnownBy: String, CaseIterable { case identity, bytes, anotherIdentity, anotherRow }

    @Test(arguments: KnownBy.allCases)
    func aFileMovedBeforeACrashIsRecordedWhereItWentOnlyWhenItIsThatDocument(_ known: KnownBy) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let retry = 30.0
        let h = base.with { $0.ingest.retryDelays = NonEmpty(retry, []) }
        try await base.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER record_cut_off_once BEFORE UPDATE OF path ON documents
                WHEN NEW.path != OLD.path AND (SELECT COUNT(*) FROM events WHERE kind = '\(EventKind.retry.rawValue)') = 0
                BEGIN SELECT RAISE(ABORT, 'the process ended'); END
                """)
        }
        let id = try #require(await h.coordinator.enqueue(try base.env.drop("bill.txt", text: "EDP electricity July")))
        await h.coordinator.drain()
        let moved = base.env.archive.appendingPathComponent(StubAnalyzer.edpFileName + ".txt").standardizedFileURL
        switch known {
        case .identity: break
        case .bytes: #expect(removexattr(moved.path, Xattr.documentID, 0) == 0, "the crash came before the file was given its identity")
        case .anotherIdentity: try Xattr.set(Xattr.documentID, UUID().uuidString, on: moved)
        case .anotherRow:
            try await h.services.documents.save(.arrived(path: moved.path, sha256: "another", size: 1, uttype: "public.plain-text",
                                                         inode: nil, modified: nil, now: base.env.time.now()))
        }
        base.env.time.advance(by: retry)
        await h.coordinator.drain()
        let job = try #require(try await h.services.jobs.job(id: id))
        let docID = try #require(job.docId)
        let document = try #require(try await h.services.documents.document(id: docID))
        if [.anotherIdentity, .anotherRow].contains(known) {
            #expect(job.state != .done && document.path != moved.path,
                    "a file that says it is another document is never recorded as this one: \(job.state)")
        } else {
            #expect(job.state == .done && document.status == .filed && document.path == moved.path,
                    "known by its \(known), the file is recorded where it went")
        }
    }

    @Test func aReadingThatGivesNoNameLeavesADocumentInTheArchiveTheNameItHasThere() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("scan_0042.txt", text: "EDP electricity July").id)
        let filed = try #require(try await h.services.documents.document(id: id))
        #expect(filed.filename == StubAnalyzer.edpFileName + ".txt", "filed under the name the model gave")
        for analyzer in [StubAnalyzer(labels: nil, fileName: nil), StubAnalyzer(fileName: nil)] {
            let other = reading(h, with: analyzer)
            try await other.review.retry(id)
            await other.coordinator.drain()
            let read = try #require(try await h.services.documents.document(id: id))
            #expect(read.path == filed.path,
                    "read again, by a model that gives no name (with \(analyzer.labels == nil ? "no valid answer" : "labels")), it keeps the name it has in the archive, not the one it arrived with")
        }
    }

    @Test func aDocumentReadAgainUnderTheNameItHasGainsNoNewSuffixAndKeepsItsCase() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let first = try await h.ingest("bill.txt", text: "EDP electricity July")
        let second = try await h.ingest("bill 2.txt", text: "EDP electricity August")
        let suffixed = StubAnalyzer.edpFileName + " (2).txt"
        #expect(first.filename == StubAnalyzer.edpFileName + ".txt" && second.filename == suffixed,
                "two documents the model names alike: the second gets the collision suffix")
        let id = try #require(second.id)
        for time in 1...2 {
            try await h.review.retry(id)
            await h.coordinator.drain()
            let read = try #require(try await h.services.documents.document(id: id))
            #expect(read.filename == suffixed && FileManager.default.fileExists(atPath: read.path),
                    "read again (\(time)), it keeps its suffix: its own file is not the one in the way, so no “(3)”")
        }
        let cased = try h.env.put("Mine/" + StubAnalyzer.edpFileName.lowercased() + ".txt", text: "EDP electricity September")
        try await ArchiveReconciler(services: h.services, coordinator: h.coordinator).apply([.found(path: cased.path)])
        await h.coordinator.drain()
        let adopted = try #require(try await h.services.documents.document(path: cased.path)?.id)
        try await h.review.retry(adopted)
        await h.coordinator.drain()
        #expect(try await h.services.documents.document(id: adopted)?.path == cased.path,
                "one whose name the model writes in another case only keeps the name it has, and is not moved to another")
    }

    @Test func aPackageIsFiledWholeAsOneDocument() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let notes = try writePackage(h.env.incoming.appendingPathComponent("Notes.rtfd"), notesPackage)
        let sha = try HashService.sha256(of: notes)
        await h.coordinator.enqueue(notes)
        await h.coordinator.drain()
        let documents = try await h.services.documents.list(DocumentFilter(), limit: 5)
        let filed = try #require(documents.first)
        #expect(documents.count == 1 && filed.status == .filed, "a package is one document, filed")
        #expect(filed.filename == StubAnalyzer.edpFileName + ".rtfd" && filed.sha256 == sha,
                "under the model's name with its own extension, known by the digest of what it holds")
        #expect(try HashService.sha256(of: filed.url) == sha && !FileManager.default.fileExists(atPath: notes.path),
                "moved whole into the archive, with everything it holds")
        #expect(filed.size == Int64(notesPackage.map(\.text.utf8.count).reduce(0, +)), "and weighed by what it holds")
    }

    @Test func aDocumentFiledIntoAnArchiveOnAnotherVolumeLeavesItsOriginalInTheTrashTheAppWasGiven() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let h = Harness(env: base.env, services: Harness.services(base.env, analyzer: StubAnalyzer(), config: base.env.config,
                                                                  sameVolume: { _, _ in false }))
        let doc = try await h.ingest("scan_0042.txt", text: "EDP electricity July")
        #expect(doc.status == .filed && FileManager.default.fileExists(atPath: doc.path), "the document is filed as a copy")
        #expect(h.env.trashed().map(\.lastPathComponent) == ["scan_0042.txt"],
                "and the file it was copied from went to the Trash the app was given, as ARRUMATOR_TRASH asks, not the user's")
    }

    /// Every move crosses a volume.
    private static let otherVolume: FileOperations.VolumeCheck = { _, _ in false }

    /// The pipeline over `base`, moving files as onto another volume when `crossing`, with `trash` as the Trash, retries
    /// due at once, and `analyzer` reading.
    private func pipeline(_ base: Harness, crossing: Bool, trash: (any Trashing)? = nil, analyzer: StubAnalyzer = StubAnalyzer()) -> Harness {
        var config = base.env.config
        config.ingest.retryDelays = NonEmpty(0, [])
        let sameVolume = crossing ? Self.otherVolume : FileOperations.onOneVolume
        return Harness(env: base.env, services: Harness.services(base.env, analyzer: analyzer, config: config, sameVolume: sameVolume, trash: trash))
    }

    /// Works the queue for as many attempts as a job has, so a job that would be tried again is.
    private func drainEveryAttempt(_ h: Harness) async {
        for _ in 0..<h.services.config.ingest.maxAttempts { await h.coordinator.drain() }
    }

    /// Everything in the archive, by name.
    private func archived(_ h: Harness) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: h.env.archive.path)) ?? []).sorted()
    }

    /// Appends to the file `name` in Incoming, as the user saving another version of it does, from a task of their own.
    private static func change(_ name: String, in incoming: URL) async throws {
        try await Task {
            let handle = try FileHandle(forWritingTo: incoming.appendingPathComponent(name))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" and a corrected total".utf8))
            try handle.close()
        }.value
    }

    @Test(arguments: [false, true])
    func aFileChangedAfterItWasReadIsReadAgainFromTheStartAndFiledAsItIsNow(crossing: Bool) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let (incoming, changed) = (base.env.incoming, Signal())
        // The user saves another version over the file while the model reads the first one, once.
        let analyzer = StubAnalyzer(during: { name in
            guard !changed.fired else { return }
            changed.fire()
            try await Self.change(name, in: incoming)
        })
        let h = pipeline(base, crossing: crossing, analyzer: analyzer)
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP electricity July"))
        await drainEveryAttempt(h)
        let documents = try await h.services.documents.list(DocumentFilter(), limit: 5)
        let filed = try #require(documents.first)
        #expect(documents.count == 1 && filed.status == .filed, "one document, filed")
        #expect(try String(contentsOf: filed.url, encoding: .utf8).hasSuffix("and a corrected total")
                    && filed.sha256 == HashService.sha256(of: filed.url),
                "it is what the file holds now, hashed as it is now, not what was read of it before it changed")
        #expect(await analyzer.calls.files == ["bill.txt", "bill.txt"], "it was read again, from the start, once")
        let said = try await h.services.history.events(limit: 10, kinds: [.retry, .failed]).map(\.summary)
        #expect(said == ["bill.txt changed after it was read; it is read again from the start"], "and History says so once: \(said)")
        #expect(try await h.jobs().map(\.state) == [.done], "in one job")
    }

    @Test(arguments: [false, true])
    func aFileThatChangesAtEveryReadingEndsAfterItsAttemptsAndIsNeverFiledAsRead(crossing: Bool) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let incoming = base.env.incoming
        let analyzer = StubAnalyzer(during: { name in try await Self.change(name, in: incoming) })
        let h = pipeline(base, crossing: crossing, analyzer: analyzer)
        let bill = try h.env.drop("bill.txt", text: "EDP electricity July")
        await h.coordinator.enqueue(bill)
        await drainEveryAttempt(h)
        let attempts = h.services.config.ingest.maxAttempts
        #expect(await analyzer.calls.files.count == attempts, "it is read again at most ingest.maxAttempts times, then no more")
        let document = try #require(try await h.services.documents.list(DocumentFilter(), limit: 5).first)
        #expect(document.status == .failed,
                "never filed as what was read: parked as failed, or, when its copy no longer matches it, left failed where it is")
        #expect(FileManager.default.fileExists(atPath: document.path) && FileManager.default.fileExists(atPath: bill.path) == crossing,
                "parked in the archive on one volume; left in Incoming when it could not be copied as it is")
        let failed = try await h.services.history.events(limit: 10, kinds: [.failed], docID: document.id)
        let retried = try await h.services.history.events(limit: 10, kinds: [.retry], docID: document.id)
        #expect(failed.count == 1 && retried.count == attempts - 1, "each change said once, and the end once")
        #expect(try await h.jobs().map(\.state) == [.failed], "and the job ends")
    }

    @Test(arguments: [true, false])
    func aFileTheTrashRefusesStaysInIncomingSayingWhyOnceAndARescanLeavesIt(copyTakenBack: Bool) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let analyzer = StubAnalyzer()
        // The Trash of Incoming's volume takes nothing, as on a network share without one; the archive's takes what it
        // is given, or nothing either.
        let trash: any Trashing = copyTakenBack ? PickyTrash(refusing: [base.env.incoming], folder: base.env.trash) : RefusingTrash()
        let h = pipeline(base, crossing: true, trash: trash, analyzer: analyzer)
        let bill = try h.env.drop("bill.txt", text: "EDP electricity July")
        let filedName = StubAnalyzer.edpFileName + ".txt"
        for arrival in ["arrives", "is found again by a rescan"] {
            await h.coordinator.enqueue(bill)
            await drainEveryAttempt(h)
            #expect(FileManager.default.fileExists(atPath: bill.path), "when it \(arrival), the file stays in Incoming")
            #expect(archived(h) == (copyTakenBack ? [] : [filedName]),
                    "when it \(arrival), no second copy is ever made: \(copyTakenBack ? "the copy went to the Trash" : "the one copy stays, said")")
            #expect(h.env.trashed().count == (copyTakenBack ? 1 : 0), "when it \(arrival), one copy went to the Trash at most")
            #expect(await analyzer.calls.files == ["bill.txt"], "when it \(arrival), the model read it once")
            let documents = try await h.services.documents.list(DocumentFilter(), limit: 5)
            let left = try #require(documents.first)
            #expect(documents.count == 1 && left.status == .failed && left.path == bill.spelledOnDisk.path,
                    "when it \(arrival), it is one document, left where it is, not filed, which a rescan leaves alone")
            #expect(try await h.services.documents.reviewQueue().map(\.id) == [left.id], "in Needs You")
            let failed = try await h.services.history.events(limit: 10, kinds: [.failed, .retry], docID: left.id)
            #expect(failed.map(\.kind) == [.failed] && left.analysis?.problems.count == 1, "said once, as failed, never tried again")
            let summary = try #require(failed.first?.summary)
            #expect(summary.hasPrefix("bill.txt stays in Incoming: ") && summary.contains(RefusingTrash.reason)
                        && summary.contains(h.env.archive.appendingPathComponent(filedName).lastPathComponent) == !copyTakenBack,
                    "with why, and where the copy is when the Trash would not take it either: \(summary)")
            #expect(try await h.jobs().map(\.state) == [.failed], "one job, ended")
        }
    }

    // MARK: One path, however it is named

    /// Incoming named in the settings through a link to the folder that holds the files, as the user may choose it.
    private func linkedIncoming(_ h: Harness) async throws -> URL {
        let real = h.env.root.appendingPathComponent("Real Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = h.env.root.appendingPathComponent("Scans", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try await h.env.settings.update { $0.incomingPath = link.path }
        return real
    }

    @Test func aDocumentUndoneIntoAnIncomingNamedThroughALinkIsLeftThereByARescan() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let real = try await linkedIncoming(h)
        let bill = real.appendingPathComponent("bill.txt")
        try Data("EDP electricity July".utf8).write(to: bill)
        // As the watcher reports it: as the file system spells it.
        let reported = bill.spelledOnDisk
        await h.coordinator.enqueue(reported)
        await h.coordinator.drain()
        let id = try #require(try await h.services.documents.list(DocumentFilter(), limit: 5).first?.id)
        try await h.review.undo(id)
        let undone = try #require(try await h.services.documents.document(id: id))
        #expect(undone.status == .undone && undone.path == reported.path && FileManager.default.fileExists(atPath: undone.path),
                "undone, it is back in Incoming at its path as the watcher names it, which holds the file")
        #expect(await h.coordinator.enqueue(reported) == nil, "so the rescan that finds it there leaves it alone")
        await h.coordinator.drain()
        let (jobs, documents) = (try await h.jobs(), try await h.services.documents.list(DocumentFilter(), limit: 5))
        #expect(jobs.count == 1 && documents.count == 1, "and it is neither queued nor filed a second time")
    }

    @Test func aFileNamedThroughALinkInAnotherCaseOrByTheWatcherIsOneJob() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let real = try await linkedIncoming(h)
        let bill = real.appendingPathComponent("bill.txt")
        try Data("EDP electricity July".utf8).write(to: bill)
        let link = URL(fileURLWithPath: await h.env.settings.current.incomingPath).appendingPathComponent("bill.txt")
        var spellings = [link, bill.spelledOnDisk]
        if WatchingTests.temporaryVolumeIgnoresCase { spellings.append(URL(fileURLWithPath: bill.spelledOnDisk.path.lowercased())) }
        var queued: Set<Int64> = []
        for named in spellings { queued.insert(try #require(await h.coordinator.enqueue(named), "queued as \(named.path)")) }
        let jobs = try await h.jobs()
        #expect(queued.count == 1 && jobs.map(\.sourcePath) == [bill.spelledOnDisk.path],
                "arrumatorcli ingest through the link, the watcher, or a path in another case: one file, one job, at one path")
    }

    @Test func aPathInsideAPackageQueuesThePackage() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let notes = try writePackage(h.env.incoming.appendingPathComponent("Notes.rtfd"), notesPackage)
        await h.coordinator.enqueue(notes.appendingPathComponent("Pictures/boiler.png"))
        await h.coordinator.enqueue(notes.appendingPathComponent("TXT.rtf"))
        #expect(try await h.jobs().map(\.sourcePath) == [notes.spelledOnDisk.path],
                "arrumatorcli ingest given a file inside a package queues the package, once, as the watcher does")
    }

    @Test func anIncomingInsideAFolderOfAPackageTypeQueuesItsFilesNotTheFolder() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let holder = h.env.root.appendingPathComponent("Scans.bundle", isDirectory: true)
        let incoming = holder.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try #require(try holder.resourceValues(forKeys: [.isPackageKey]).isPackage == true, "macOS shows the folder as a package")
        try await h.env.settings.update { $0.incomingPath = incoming.path }
        let bill = incoming.appendingPathComponent("bill.txt")
        try Data("EDP electricity July".utf8).write(to: bill)
        await h.coordinator.enqueue(bill)
        #expect(try await h.jobs().map(\.sourcePath) == [bill.spelledOnDisk.path],
                "a package is looked for below Incoming only, so a file in it is never taken for the folder that holds Incoming")
    }
}
