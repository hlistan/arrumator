@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// Reads each document as the analyzer for its turn reads it: the first reading as `readings[0]`, the next as
/// `readings[1]`, and every later one as the last.
struct Readings: DocumentAnalyzing {
    actor Count {
        private(set) var made = 0
        func next() -> Int {
            made += 1
            return made - 1
        }
    }

    let readings: [StubAnalyzer]
    let count = Count()

    func analyse(_ content: ExtractedContent, guidance: LabelGuidance, settings: AppSettings, config: PipelineConfig,
                 trace: TraceContext) async throws -> AnalysisOutcome {
        let turn = min(await count.next(), readings.count - 1)
        return try await readings[turn].analyse(content, guidance: guidance, settings: settings, config: config, trace: trace)
    }

    func embedding(for content: ExtractedContent, senders: [String], settings: AppSettings, config: PipelineConfig,
                   trace: TraceContext) async throws -> (vector: [Float], model: String)? { nil }
}

/// A Trash that refuses one file, as one on a share without a Trash refuses what is there, and takes the rest into
/// `folder`.
struct RefusingOne: Trashing {
    let refused: URL
    let folder: FolderTrash

    func trash(_ url: URL) throws -> URL? {
        guard url.spelledOnDisk.path != refused.spelledOnDisk.path else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: RefusingTrash.reason])
        }
        return try folder.trash(url)
    }
}

/// What is not filed, and why: a refusal that will not change, a reading taken back when its file changed, what Incoming
/// never takes in, an archive whose folder is gone; and that a document left in Incoming is no document of the archive.
@Suite struct NotFiledTests {
    static let bill = "EDP electricity July"

    /// The pipeline over a model that fails to read every file, tried again without delay, and waiting for what is away
    /// the last of `ingest.retryDelays`.
    private static func failing() async throws -> (base: Harness, h: Harness) {
        let base = try await Harness.make(analyzer: StubAnalyzer(error: TestFailure("boom")))
        return (base, base.with { $0.ingest.retryDelays = NonEmpty(0, [0, 30]) })
    }

    @Test func aFileThatKeepsFailingWaitsForTheArchiveToBeSetAsideThereNeverLeftInIncoming() async throws {
        let (base, h) = try await Self.failing()
        defer { base.env.cleanup() }
        let url = try base.env.drop("bad.txt", text: "x")
        let id = try #require(await h.coordinator.enqueue(url))
        try FileManager.default.removeItem(at: base.env.archive)
        await h.coordinator.drain()
        let waiting = try #require(try await h.services.jobs.job(id: id))
        #expect(waiting.state.isActive && waiting.nextRunAt == base.env.time.now().addingTimeInterval(base.env.config.ingest.retryDelays.last),
                "its last attempt spent, it waits for the archive's folder to set it aside there: \(waiting.state)")
        let docID = try #require(waiting.docId)
        let document = try #require(try await h.services.documents.document(id: docID))
        #expect(document.status == .processing && FileManager.default.fileExists(atPath: url.path),
                "rather than being left in Incoming as failed for good")

        try FileManager.default.createDirectory(at: base.env.archive, withIntermediateDirectories: true)
        base.env.time.advance(by: base.env.config.ingest.retryDelays.last)
        await h.coordinator.drain()
        let parked = try #require(try await h.services.documents.document(id: docID))
        #expect(parked.status == .failed && base.env.archive.holds(parked.path), "once the folder is back, it is set aside in the archive")
    }

    @Test func aFailureToRecordAFileThatKeepsFailingIsInHistory() async throws {
        let (base, h) = try await Self.failing()
        defer { base.env.cleanup() }
        let id = try #require(await h.coordinator.enqueue(try base.env.drop("bad.txt", text: "x")))
        try await base.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER failing_cannot_be_recorded BEFORE UPDATE OF status ON documents WHEN NEW.status = 'failed'
                BEGIN SELECT RAISE(ABORT, 'the index is full'); END
                """)
        }
        await h.coordinator.drain()
        let job = try #require(try await h.services.jobs.job(id: id))
        #expect(job.state == .failed, "the job fails")
        let said = try await h.services.history.events(limit: 5, kinds: [.failed]).map(\.summary)
        #expect(said.count == 1 && said.allSatisfy { $0.hasPrefix("bad.txt failed (boom), and that could not be recorded with it: ") },
                "and that what it failed with could not be recorded is said in History, not only in the log: \(said)")
    }

    /// Every move crosses a volume.
    private static let otherVolume: FileOperations.VolumeCheck = { _, _ in false }

    /// The pipeline over `base` with `analyzer` reading, every move to another volume when `crossing`, `trash` as the
    /// Trash and `change` made to the configuration.
    private func pipeline(_ base: Harness, analyzer: any DocumentAnalyzing = StubAnalyzer(), crossing: Bool = false,
                          trash: (any Trashing)? = nil, _ change: (inout PipelineConfig) -> Void = { _ in }) -> Harness {
        var config = base.env.config
        change(&config)
        let sameVolume = crossing ? Self.otherVolume : FileOperations.onOneVolume
        return Harness(env: base.env, services: Harness.services(base.env, analyzer: analyzer, config: config, sameVolume: sameVolume, trash: trash))
    }

    /// Appends to `file`, as the user saving another version of it does, from a task of their own.
    private static func change(_ file: URL, to text: String? = nil) async throws {
        try await Task {
            if let text {
                try Data(text.utf8).write(to: file)
            } else {
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(" and a corrected total".utf8))
                try handle.close()
            }
        }.value
    }

    // MARK: A copy, however its path is spelled

    @Test func anExactCopyIsKnownByThePathItWasNamedByHoweverItIsSpelled() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        _ = try await h.ingest("bill.txt", text: Self.bill)
        // As `arrumatorcli eval` names what it drops into Incoming: as the settings spell Incoming.
        let dropped = await h.env.settings.current.incomingURL.appendingPathComponent("bill copy.txt")
        try Data(Self.bill.utf8).write(to: dropped)
        await h.coordinator.enqueue(dropped)
        await h.coordinator.drain()
        let event = try #require(try await h.services.history.events(limit: 1, kinds: [.duplicate]).first)
        let copy = try #require(JSON.decode(CopyPayload.self, from: event.payloadJson))
        #expect(copy.isCopy(at: dropped) && copy.isCopy(at: dropped.spelledOnDisk),
                "the copy recorded is the file dropped, however the path to it is spelled, so an evaluation scores it as a copy")
        #expect(!copy.isCopy(at: h.env.incoming.appendingPathComponent("bill.txt")), "and no other file")
    }

    // MARK: A reading taken back

    @Test func aFileGoneAfterItChangedEndsItsDocumentWithNothingOfItsFirstReading() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let (bill, changed) = (base.env.incoming.appendingPathComponent("bill.txt"), Signal())
        let h = pipeline(base, analyzer: StubAnalyzer(during: { _ in
            guard !changed.fired else { return }
            changed.fire()
            try await Self.change(bill)
        }))
        // Stands in for a stop right after the job went back to the start: it is not due again in this run.
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER not_again AFTER UPDATE ON jobs WHEN NEW.state = 'pending' AND OLD.state = 'filing'
                BEGIN UPDATE jobs SET next_run_at = 99999999999 WHERE id = NEW.id; END
                """)
        }
        try h.env.drop("bill.txt", text: Self.bill)
        await h.coordinator.enqueue(bill)
        await h.coordinator.drain()
        let id = try #require(try await h.services.documents.list(DocumentFilter(), limit: 5).first?.id)
        let taken = try #require(try await h.services.documents.document(id: id))
        #expect(taken.status == .processing && taken.labels == nil && taken.analysis == nil && taken.contentJson == nil,
                "a document whose file changed is an arrival again: nothing the first reading found stays with it")
        #expect(try await h.services.index.body(docID: id) == nil, "nor in the full-text index")
        try FileManager.default.removeItem(at: bill)
        try await h.env.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER not_again")
            try db.execute(sql: "UPDATE jobs SET next_run_at = NULL")
        }
        await IngestCoordinator(services: h.services).drain()
        let ended = try #require(try await h.services.documents.document(id: id))
        #expect(ended.status == .missing, "its file gone before it was read again, the document ends, missing, not processing for good")
        #expect(try await h.services.history.events(limit: 5, kinds: [.missing], docID: id).count == 1, "said once")
        #expect(try await h.jobs().map(\.state) == [.cancelled], "and its job ends")
    }

    @Test func aFileThatChangedIntoACopyOfADocumentInTheArchiveEndsTheDocumentItWas() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        let (scan, changed) = (base.env.incoming.appendingPathComponent("scan.txt"), Signal())
        let h = pipeline(base, analyzer: StubAnalyzer(during: { name in
            guard name == "scan.txt", !changed.fired else { return }
            changed.fire()
            // Saved over with what the archive holds already.
            try await Self.change(scan, to: Self.bill)
        }))
        try h.env.drop("scan.txt", text: "A scan of something else")
        await h.coordinator.enqueue(scan)
        await h.coordinator.drain()
        let ended = try #require(try await h.services.documents.list(DocumentFilter(), limit: 5).first { $0.id != original.id })
        #expect(ended.status == .duplicate && ended.duplicateOf == original.id && ended.labels == nil,
                "the document the file was ends as a copy of the one in the archive, with nothing of its reading")
        #expect(try await h.services.index.body(docID: try #require(ended.id)) == nil, "and nothing in the full-text index")
        let copies = try await h.services.history.events(limit: 5, kinds: [.duplicate])
        #expect(copies.map(\.docId) == [original.id], "the file is a copy of the document in the archive, said once, under it")
        #expect(base.env.trashed().map(\.lastPathComponent) == ["scan.txt"], "and it went to the Trash")
    }

    @Test func aFileThatChangedAndIsThenReadWithNoValidAnswerKeepsNothingOfTheFirstReading() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let bill = base.env.incoming.appendingPathComponent("bill.txt")
        let h = pipeline(base, analyzer: Readings(readings: [StubAnalyzer(during: { _ in try await Self.change(bill) }),
                                                             StubAnalyzer(labels: nil, fileName: nil)]), { $0.ingest.retryDelays = NonEmpty(0, []) })
        try h.env.drop("bill.txt", text: Self.bill)
        await h.coordinator.enqueue(bill)
        await h.coordinator.drain()
        let document = try #require(try await h.services.documents.list(DocumentFilter(), limit: 5).first)
        #expect(document.status == .needsReview && document.labels == nil,
                "read again as a new arrival with no valid answer, it waits for the user labelled with nothing the first reading gave")
        #expect(document.analysis?.problems == ["the model gave no valid answer"], "for the second reading's reason alone")
    }

    // MARK: Left in Incoming

    @Test func aDocumentLeftInIncomingIsNoOriginalOfACopyNorADocumentOfTheArchive() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let bill = base.env.incoming.appendingPathComponent("bill.txt")
        let analyzer = StubAnalyzer()
        let h = pipeline(base, analyzer: analyzer, crossing: true, trash: RefusingOne(refused: bill, folder: base.env.trash),
                         { $0.ingest.retryDelays = NonEmpty(0, []) })
        try h.env.drop("bill.txt", text: Self.bill)
        await h.coordinator.enqueue(bill)
        await h.coordinator.drain()
        let left = try #require(try await h.services.documents.list(DocumentFilter(), limit: 5).first)
        #expect(left.status == .failed && left.path == bill.spelledOnDisk.path, "the Trash refused the file: it is left in Incoming")
        let copy = try h.env.drop("Taxes 2024/bill copy.txt", text: Self.bill)
        await h.coordinator.enqueue(copy)
        await h.coordinator.drain()
        #expect(try await h.services.history.events(limit: 5, kinds: [.duplicate]).isEmpty,
                "a copy of it is no copy of a document of the archive")
        #expect(await analyzer.calls.files == ["bill.txt", "bill copy.txt"], "so the copy is read as a document of its own")
        let filed = try #require(try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 5).first)
        #expect(FileManager.default.fileExists(atPath: filed.path) && FileManager.default.fileExists(atPath: bill.path),
                "and filed, while the one left in Incoming stays there")
        let matcher = SearchPlanMatcher(database: h.env.database, archive: h.env.archive, limit: 10)
        let plan = SearchPlan(title: "", labels: [DocumentLabel(kind: .sender, value: "EDP Comercial")], words: [], grouping: [])
        #expect(try await matcher.documents(plan) == [filed.id], "a search task finds the document in the archive, not the one left in Incoming")
        await #expect(throws: IngestError.notInArchive(try #require(left.id)),
                      "nor can one left in Incoming be confirmed as filed") {
            try await h.review.confirm(try #require(left.id))
        }
    }

    @Test func aDocumentLeftForLaterInIncomingIsNoDocumentOfTheArchiveATaskFinds() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: Self.bill).id)
        let matcher = SearchPlanMatcher(database: h.env.database, archive: h.env.archive, limit: 10)
        let plan = SearchPlan(title: "", labels: [DocumentLabel(kind: .sender, value: "EDP Comercial")], words: [], grouping: [])
        #expect(try await matcher.documents(plan) == [id], "filed, it is found")
        try await h.review.undo(id)
        try await h.review.hold(id)
        #expect(try await matcher.documents(plan).isEmpty,
                "undone into Incoming and left for later there, it is not, though left for later is a status of documents in the archive")
        let actions = h.searchTasks(StubInterpreter(plans: [:])).actions
        let task = try await actions.create(prompt: "EDP bills").id
        #expect(try await actions.add(task, labelled: plan.labels).isEmpty, "nor is it added to a task by its labels")
    }

    @Test func aDocumentTheTrashRefusedReadsAsNotProcessedNotAsLeftForLater() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let h = pipeline(base, crossing: true, trash: RefusingTrash())
        let bill = try h.env.drop("bill.txt", text: Self.bill)
        await h.coordinator.enqueue(bill)
        await h.coordinator.drain()
        let stats = StatsService(database: h.env.database, config: h.env.config.stats, time: h.env.time)
        let stops = try await stats.funnel(days: h.env.config.stats.defaultWindowDays).steps.flatMap(\.stoppedHere)
        #expect(stops.map(\.status) == [.failed] && stops.first?.reason == StatsService.stopReason(for: .failed).text,
                "Statistics counts it as a document that could not be processed, never as one the user left for later")
        let left = try #require(try await h.services.documents.list(DocumentFilter(), limit: 5).first)
        #expect(left.status.isReviewable && left.analysis?.problems.first?.hasPrefix("Not filed: ") == true,
                "and its row says why it waits, from its problems, as for any that failed")
    }

    // MARK: What is not taken

    @Test func aPackageOfMoreItemsThanAllowedIsRefusedWhereverItIsNamed() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let h = pipeline(base) { $0.watcher.maxPackageItems = 2 }
        // Three items: two files and a folder, outside Incoming, as `arrumatorcli ingest` may name it.
        let library = try writePackage(h.env.root.appendingPathComponent("Elsewhere/Library.rtfd"), notesPackage)
        let inside = library.appendingPathComponent("Pictures/boiler.png")
        #expect(await h.coordinator.enqueue(inside) == nil, "a file inside a package of more items than allowed is not queued")
        #expect(try await h.jobs().isEmpty && FileManager.default.fileExists(atPath: inside.path), "nothing is read or moved")
        let said = try await h.services.history.events(limit: 5, kinds: [.error]).map(\.summary)
        #expect(said == [FileOperationError.tooManyItems(library.spelledOnDisk.path, limit: 2).localizedDescription],
                "History says why: \(said)")
        #expect(throws: FileOperationError.self, "and the command line is refused before it reads anything") {
            try h.services.arrival(inside, settings: try AppSettings.bundledDefaults())
        }
    }

    @Test func aLinkNamedToBeFiledIsRefusedAndWhatItPointsToIsLeftAlone() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let target = try h.env.put("../Elsewhere/hosts.txt", text: "a file of the user's, outside Incoming")
        let link = h.env.incoming.appendingPathComponent("alias.txt")
        try FileManager.default.createDirectory(at: h.env.incoming, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(link.spelledOnDisk.lastPathComponent == "alias.txt", "the path of a link names the link, never what it points to")
        #expect(await h.coordinator.enqueue(link) == nil, "a link is not queued, as the watcher takes none")
        await h.coordinator.drain()
        #expect(try await h.jobs().isEmpty && FileManager.default.fileExists(atPath: target.path), "what it points to stays where it is")
        let refusal = IngestError.notTaken(link.spelledOnDisk.path, reason: "symbolic link")
        #expect(try await h.services.history.events(limit: 5, kinds: [.error]).map(\.summary) == [refusal.localizedDescription],
                "History says why")
        #expect(throws: refusal, "and the command line is refused, saying why") {
            try h.services.arrival(link, settings: try AppSettings.bundledDefaults())
        }
    }

    // MARK: An archive whose folder is gone

    @Test func aFileWaitsForAnArchiveWhoseFolderIsGoneAndIsFiledWhenItIsBack() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let analyzer = StubAnalyzer()
        let h = pipeline(base, analyzer: analyzer)
        let away = h.env.root.appendingPathComponent("Archive renamed", isDirectory: true)
        try FileManager.default.moveItem(at: h.env.archive, to: away)
        let bill = try h.env.drop("bill.txt", text: Self.bill)
        await h.coordinator.enqueue(bill)
        let delay = h.services.config.ingest.retryDelays.last
        for wait in 1...2 {
            await h.coordinator.drain()
            h.env.time.advance(by: delay)
            #expect(!FileManager.default.fileExists(atPath: h.env.archive.path), "wait \(wait): the archive's folder is not made again")
            #expect(FileManager.default.fileExists(atPath: bill.path), "wait \(wait): the file stays in Incoming, untouched")
            let job = try #require(try await h.jobs().first)
            #expect(job.state == .filing && job.attempt == 0, "wait \(wait): its job waits to file it, spending no attempt")
        }
        let said = try await h.services.history.events(limit: 10, kinds: [.retry, .failed, .needsReview]).map(\.summary)
        #expect(said == ["Waiting for the archive: \(FileOperationError.folderMissing(h.env.archive.path).localizedDescription)"],
                "History says so once: \(said)")
        try FileManager.default.moveItem(at: away, to: h.env.archive)
        await h.coordinator.drain()
        let filed = try #require(try await h.services.documents.list(DocumentFilter(), limit: 5).first)
        #expect(filed.status == .filed && FileManager.default.fileExists(atPath: filed.path) && !FileManager.default.fileExists(atPath: bill.path),
                "once the folder is back, the file is filed into it")
        #expect(await analyzer.calls.files == ["bill.txt"], "read once: the wait is for the folder, not for another reading")
    }
}
