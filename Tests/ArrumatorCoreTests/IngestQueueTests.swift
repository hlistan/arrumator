@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// The ingest queue takes files in the order they arrived (`JobStore.nextDue`). A file stopped part way, as when the app
/// quits while the model reads it, keeps its stage and its place, and carries on first at the next start; one waiting to
/// be tried again holds up none behind it. Quitting stops the queues before the app ends, and a stop never separates a
/// move into the archive from its record.
@Suite struct IngestQueueTests {
    /// The pipeline over files read by an analyzer that holds the reading `holding` names until the worker is stopped.
    func world(_ holding: Holding) async throws -> (h: Harness, analyzer: StubAnalyzer) {
        let analyzer = StubAnalyzer(during: { try await holding.read($0) })
        let h = try await Harness.make(analyzer: analyzer)
        return (h, analyzer)
    }

    @Test func aFileStoppedPartWayCarriesOnFirstAtTheNextStartBeforeTheFilesThatArrivedAfterIt() async throws {
        let holding = Holding()
        let (h, analyzer) = try await world(holding)
        defer { h.env.cleanup() }
        for name in ["a.txt", "b.txt", "c.txt"] {
            await h.coordinator.enqueue(try h.env.drop(name, text: "EDP electricity, \(name)"))
            h.env.time.advance(by: 60)
        }

        // The app runs, and is quit while the model reads the first file.
        let follower = IngestFollower()
        let updates = await h.coordinator.statusUpdates()
        let following = Task { for await status in updates { await follower.add(status) } }
        defer { following.cancel() }
        await holding.hold("a.txt")
        await h.coordinator.start()
        #expect(await Patience.until { await holding.held == "a.txt" }, "the worker takes the first file to arrive, and the model reads it")
        let reading = try await h.jobs()
        let a = try #require(reading.first?.id)
        let reader = try await h.services.settings.current.modelProfile().chatModel
        let inHand = IngestStatus.Current(job: a, path: try #require(reading.first?.sourcePath), stage: .analysing,
                                          since: h.env.time.now(), reader: reader)
        let status = await h.coordinator.status
        #expect(status.current == inHand, "the status names the file in hand and the stage it is at")
        #expect(await Patience.until { await follower.received.last?.current == inHand }, "and a subscriber, as the app is one, is sent it")
        #expect(reading.map { status.progress(of: $0) } == [.working(JobWork(stage: .analysing, model: reader, since: h.env.time.now())), .waiting, .waiting],
                "the file in hand is the one being worked on; the others wait their turn")
        await h.coordinator.stop()
        let stopped = try await h.jobs()
        #expect(stopped.map(\.state) == [.analysing, .pending, .pending], "the file in hand stays at the stage it was stopped in")
        #expect(try stopped.first?.payload.content != nil && stopped.first?.attempt == 0 && stopped.first?.lastError == nil,
                "with what was read of it kept, and no attempt spent and no error recorded: being stopped is no failure")
        let afterStop = await h.coordinator.status
        #expect(afterStop.current == nil, "a stopped worker has nothing in hand")
        #expect(stopped.map { afterStop.progress(of: $0) } == [.resuming(.analysing), .waiting, .waiting],
                "the file stopped part way waits with the others, to carry on where it stopped: nothing is being worked on")

        // Started again a minute later, as a new process, and quit again while the model reads the second file.
        h.env.time.advance(by: 60)
        await holding.hold("b.txt")
        let second = Harness(env: h.env, services: h.services).coordinator
        await second.start()
        #expect(await Patience.until { await holding.held == "b.txt" }, "the worker takes the second file")
        await second.stop()
        let readAfterRestart = await analyzer.calls.files
        #expect(readAfterRestart == ["a.txt", "a.txt", "b.txt"],
                "started again, the worker carries on first with the file it was stopped in, before those that arrived after it")
        let restarted = try await h.jobs().map(\.state)
        #expect(restarted == [.done, .analysing, .pending], "the first is filed, the second stopped part way in its turn")

        // Started once more, it carries on with the second file, then files the third, and nothing is left part way.
        h.env.time.advance(by: 60)
        let third = Harness(env: h.env, services: h.services).coordinator
        await third.start()
        #expect(try await Patience.until { try await h.jobs().allSatisfy { !$0.state.isActive } }, "the queue drains")
        await third.stop()
        let read = await analyzer.calls.files
        #expect(read == ["a.txt", "a.txt", "b.txt", "b.txt", "c.txt"],
                "each file stopped part way is the next one read, and the files are read in the order they arrived")
        let drained = try await h.jobs().map(\.state)
        #expect(drained == [.done, .done, .done], "once the queue has drained no file is left part way")
        let filed = try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 10)
        #expect(filed.count == 3 && filed.allSatisfy { $0.url.deletingLastPathComponent().standardizedFileURL == h.env.archive.standardizedFileURL },
                "every file is filed in the archive")
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.env.incoming.path).isEmpty, "and Incoming is left empty")
        let extracted = try await h.services.history.events(limit: 10, kinds: [.extracted]).count
        #expect(extracted == 3, "a file stopped while the model read it carries on from its last finished stage: it is not extracted again")
    }

    @Test func whatAFileInTheQueueAndTheOneInHandShowIsTheTagTheyWillBeGivenThroughAStopAndARestart() async throws {
        let holding = Holding()
        let (h, _) = try await world(holding)
        defer { h.env.cleanup() }
        let tag = DocumentLabel(kind: .tag, value: "Taxes 2024")
        for name in ["Taxes 2024/a.txt", "b.txt", "Taxes 2024/sub/c.txt"] {
            await h.coordinator.enqueue(try h.env.drop(name, text: "EDP electricity, \(name)"))
        }
        #expect(try await h.jobs().map(\.tags) == [[tag], [], [tag]],
                "each file waiting shows the tag it will be given before it is read; one put directly in Incoming shows none")
        await holding.hold("a.txt")
        await h.coordinator.start()
        #expect(await Patience.until { await holding.held == "a.txt" }, "the worker takes the first file, and the model reads it")
        #expect(await h.coordinator.status.current?.tags == [tag], "the file in hand shows its tag too")
        await h.coordinator.stop()
        let stopped = try await h.jobs()
        #expect(stopped.map(\.tags) == [[tag], [], [tag]] && stopped.first?.state == .analysing,
                "a stop keeps the tag with its job, as it keeps what the finished stages found")
        let stoppedDocument = try #require(stopped.first?.docId)
        let waiting = try #require(try await h.services.documents.document(id: stoppedDocument))
        #expect(waiting.labels == [tag] && !waiting.isLabelled, "the document has its tag while it waits to be read, though it is not labelled yet")

        let restarted = Harness(env: h.env, services: h.services).coordinator
        await restarted.start()
        #expect(try await Patience.until { try await h.jobs().allSatisfy { !$0.state.isActive } }, "the queue drains")
        await restarted.stop()
        let filed = try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 10)
        #expect(filed.filter { $0.labels?.contains(tag) == true }.map(\.originalFilename).sorted() == ["a.txt", "c.txt"]
                    && filed.first { $0.originalFilename == "b.txt" }?.labels == StubAnalyzer.edpBill,
                "started again, the files in the folder are filed with its tag, and the other with none")
    }

    /// Reads a file as `PlainTestExtractor` does, taking `seconds` of test time to read it, as OCR of a scan does.
    struct SlowExtractor: ContentExtracting {
        let time: TestTime
        let seconds: Double

        func extract(_ url: URL, sha256: String, context: ExtractionContext, trace: TraceContext) async throws -> ExtractedContent {
            time.advance(by: seconds)
            return try await PlainTestExtractor().extract(url, sha256: sha256, context: context, trace: trace)
        }
    }

    @Test func theFileTheModelReadsNamesTheModelAndCountsFromWhenItsReadingBegan() async throws {
        let holding = Holding()
        let (world, _) = try await world(holding)
        defer { world.env.cleanup() }
        var services = world.services
        let extracting = 45.0
        services.extractor = SlowExtractor(time: world.env.time, seconds: extracting)
        let h = Harness(env: world.env, services: services)
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP electricity July"))
        let reader = try await h.services.settings.current.modelProfile().chatModel
        h.env.time.advance(by: 60)
        // The file is taken now, and its text read for `extracting` seconds before the model begins to read it.
        let began = h.env.time.now().addingTimeInterval(extracting)
        await holding.hold("bill.txt")
        await h.coordinator.start()
        #expect(await Patience.until { await holding.held == "bill.txt" }, "the worker takes the file, and the model reads it")
        // The model takes its time, as the first reading after a start waits for the model to load.
        h.env.time.advance(by: 90)
        let job = try #require(try await h.jobs().first)
        let progress = await h.coordinator.status.progress(of: job)
        #expect(progress == .working(JobWork(stage: .analysing, model: reader, since: began)),
                "read by the profile's model since its reading began, not since the file was taken or the status read: \(String(describing: progress))")
        await h.coordinator.stop()
    }

    @Test func aFileWaitingToBeTriedAgainHoldsUpNoneBehindItAndThenTakesItsPlaceByWhenItArrived() async throws {
        let stumbles = Stumbles(once: "a.txt")
        let analyzer = StubAnalyzer(during: { if await stumbles.stumble($0) { throw TestFailure("the model stumbled") } })
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        let jobs = h.services.jobs
        let a = try #require(await h.coordinator.enqueue(try h.env.drop("a.txt", text: "EDP electricity, July")))
        await h.coordinator.enqueue(try h.env.drop("b.txt", text: "EDP electricity, August"))
        await h.coordinator.drain()
        let waiting = try #require(try await jobs.job(id: a))
        #expect(waiting.state == .analysing && waiting.attempt == 1 && waiting.lastError == "the model stumbled",
                "the file whose reading failed waits to be tried again from that stage")
        #expect(waiting.nextRunAt == h.env.time.now().addingTimeInterval(h.env.config.ingest.retryDelays.first),
                "after the first of ingest.retryDelays")
        let meanwhile = try await h.jobs().map(\.state)
        #expect(meanwhile == [.analysing, .done], "and the file behind it is filed meanwhile")
        let readFirst = await analyzer.calls.files
        #expect(readFirst == ["a.txt", "b.txt"], "it is not tried again before its time")

        // While it waits, the index is rebuilt (the filed document is read again for search) and another file arrives.
        let filed = try #require(try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 5).first)
        let reindex = try await jobs.enqueue(path: filed.path, kind: .reindex, docID: filed.id).id
        let c = try #require(await h.coordinator.enqueue(try h.env.drop("c.txt", text: "EDP electricity, September")))
        let beforeItsTime = try await Self.next(in: jobs)
        #expect(beforeItsTime == c,
                "a file that arrives meanwhile is not held up by the one waiting, and reading again for search gives way to it")
        h.env.time.advance(by: try #require(waiting.nextRunAt).timeIntervalSince(h.env.time.now()))
        let atItsTime = try await Self.next(in: jobs)
        #expect(atItsTime == a,
                "once its time has come, the file that waited takes its place by when it arrived: before the file that came after it")
        await h.coordinator.drain(.everything)
        let read = await analyzer.calls.files
        #expect(read == ["a.txt", "b.txt", "a.txt", "c.txt"], "it is read again, then the file that arrived after it")
        let reread = try await jobs.job(id: reindex)?.state
        #expect(reread == .done, "and the document is read again for search once no file waits")
        let drained = try await h.jobs().map(\.state)
        #expect(drained == [.done, .done, .done, .done], "nothing is left in the queue")
    }

    @Test func aFileQueuedAgainWithATagIsGivenItWhetherItWaitsOrIsInHandAndArrivesOnce() async throws {
        let holding = Holding()
        let (h, _) = try await world(holding)
        defer { h.env.cleanup() }
        let (waiting, inHand) = (try h.env.drop("waiting.txt", text: IngestTests.bill), try h.env.drop("inhand.txt", text: IngestTests.bill + " 2"))
        await h.coordinator.enqueue(inHand)
        await h.coordinator.enqueue(waiting)
        await holding.hold("inhand.txt")
        let app = Task { await h.coordinator.drain() }
        #expect(await Patience.until { await holding.held == "inhand.txt" }, "the worker has the first file in hand, the model reading it")

        // `arrumatorcli ingest --tag Taxes` for both, as a rescan finds them again too.
        for url in [inHand, waiting] {
            await h.coordinator.enqueue(url, tags: ["Taxes"])
            await h.coordinator.enqueue(url)
        }
        let tag = DocumentLabel(kind: .tag, value: "Taxes")
        #expect(try await h.jobs().map(\.tags) == [[tag], [tag]], "each job, the one in hand too, does all the requests asked")
        await holding.letGo()
        _ = await app.value
        await h.coordinator.drain()
        let filed = try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 5)
        #expect(filed.count == 2 && filed.allSatisfy { $0.labels?.contains(tag) == true },
                "both are filed with the tag, given while one was in hand and the other waited: \(filed.map { $0.labels ?? [] })")
        let arrivals = try await h.services.history.events(limit: 10, kinds: [.arrived]).count
        #expect(arrivals == 2, "and each file arrived once, however often it was asked for")
    }

    @Test func whichFileIsInHandAndWhichWaitIsWhatTheStatusSaysOfThem() async throws {
        let store = JobStore(database: try AppDatabase.inMemory(), time: TestTime(.advances))
        func job(_ name: String, _ state: JobState) async throws -> JobRecord {
            let id = try await store.enqueue(path: "/Incoming/\(name)", kind: .ingest).id
            var job = try #require(try await store.job(id: id))
            job.state = state
            try await store.update(job)
            return job
        }
        let (waiting, stopped) = (try await job("waiting.pdf", .pending), try await job("stopped.pdf", .analysing))
        var failed = try await job("failed.pdf", .extracting)
        failed.lastError = "the file could not be read"
        let idle = IngestStatus.idle
        #expect(idle.progress(of: waiting) == .waiting, "a file not begun waits its turn")
        #expect(idle.progress(of: stopped) == .resuming(.analysing),
                "a file stored at a stage the worker does not name was stopped part way: it waits, to carry on from that stage")
        #expect(idle.progress(of: failed) == .retrying("the file could not be read", at: TestTime.start),
                "one whose stage failed waits to be tried again, with why and when")

        let (reader, since) = ("qwen3.5:9b", TestTime.start.addingTimeInterval(90))
        func working(_ job: JobRecord, at stage: JobState) throws -> IngestStatus {
            var status = IngestStatus.idle
            status.current = IngestStatus.Current(job: try #require(job.id), path: job.sourcePath, stage: stage, since: since, reader: reader)
            return status
        }
        let onStopped = try working(stopped, at: .analysing)
        #expect(onStopped.progress(of: stopped) == .working(JobWork(stage: .analysing, model: reader, since: since)),
                "the file the worker names is in hand, at the stage it names, read by the model that reads it, since the stage began")
        #expect(onStopped.progress(of: waiting) == .waiting && onStopped.progress(of: failed) == idle.progress(of: failed),
                "while the others wait as they did")
        #expect(try working(stopped, at: .filing).progress(of: stopped) == .working(JobWork(stage: .filing, model: nil, since: since)),
                "the worker's stage is the one shown, newer than a list read before, naming no model at a stage no model reads it at")
        #expect(try working(failed, at: .extracting).progress(of: failed) == .working(JobWork(stage: .extracting, model: nil, since: since)),
                "a file tried again is in hand while it is")
        #expect(try working(stopped, at: .done).progress(of: stopped) == nil,
                "a file the worker has just finished is no longer in the queue, whatever a list read before says")
        var done = stopped
        done.state = .done
        #expect(idle.progress(of: done) == nil, "nor is a file filed")
        #expect(JobProgress.working(JobWork(stage: .hashing, model: nil, since: since)).isWorking
                    && ![JobProgress.resuming(.analysing), .retrying("", at: nil), .waiting].contains(where: \.isWorking),
                "only the file in hand is said to be worked on")
    }

    @Test func aDocumentAskedToBeReadAgainWaitsItsTurnNotBegunAndIsReadFromItsFile() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        try await h.review.retry(id)
        let queued = try #require(try await h.services.jobs.active().first)
        #expect(IngestStatus.idle.progress(of: queued) == .waiting,
                "a document asked to be read again waits its turn as not begun: it did not stop anywhere to carry on from")
        await h.coordinator.drain()
        let events = try await h.services.history.events(limit: 20, kinds: [.extracted, .analysed], docID: id).map(\.kind)
        #expect(events.filter { $0 == .analysed }.count == 2 && events.filter { $0 == .extracted }.count == 2,
                "taken, it is read again from the start, its text read from its file again, as a file that arrives is")
        #expect(try await h.jobs().map(\.state) == [.done, .done], "and filed")
    }

    @Test func quittingWaitsForTheStopToEndButNoLongerThanItsTime() async throws {
        let stop = Ending()
        #expect(await TestTime(.blocks).wait(atMost: 5) { await stop.end() }, "a stop that ends in time is said to have")
        #expect(await stop.ended == [false], "and it has ended when the wait returns, so the app quits only after it")

        let time = TestTime(.advances)
        let (holding, letGo) = AsyncStream<Void>.makeStream()
        let hung = Ending()
        let inTime = await time.wait(atMost: 5) {
            for await _ in holding {}
            await hung.end()
        }
        #expect(!inTime && time.now() == TestTime.start.addingTimeInterval(5),
                "a stop that hangs is waited for its time on the clock and no longer, so it cannot keep the app from quitting")
        letGo.finish()
        #expect(await Patience.until { await hung.ended == [false] }, "it is left to go on, never cancelled")
    }

    @Test func aStopWhileADocumentIsMovedIntoTheArchiveLetsTheMoveBeRecorded() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let url = try h.env.drop("bill.txt", text: "EDP electricity July")
        let (fingerprint, sha) = (try FileFingerprint.of(url), try HashService.sha256(of: url))
        let document = try await h.services.documents.save(.arrived(path: url.path, sha256: sha, size: fingerprint.size, uttype: "public.plain-text",
                                                                    inode: fingerprint.inode, modified: fingerprint.modified, now: h.env.time.now()))
        let id = try #require(document.id)
        let settings = await h.env.settings.current
        let stopper = Stopper()
        // Stopped, as the app quitting stops the worker, as soon as the file has been moved and before the move is recorded.
        let traced = try await h.services.startTrace(docID: id, jobID: nil, attempt: 0, source: .ingest, settings: settings)
        let trace = TraceContext(traceID: traced.traceID, sink: StopAfterPlacing(stopper: stopper))
        let filing = Task {
            _ = await Patience.until { await stopper.holds }
            return try await h.services.filer.file(document, archive: h.services.archive, analysis: DocumentAnalysis(fileName: StubAnalyzer.edpFileName, model: "stub"),
                                                   status: .filed, directory: h.env.archive, inPlace: false, fingerprint: fingerprint,
                                                   actor: .system, settings: settings, trace: trace, event: nil, keeping: nil)
        }
        await stopper.hold(filing)
        let filed = await filing.result
        #expect(await stopper.stopped, "the stop came after the file was moved")
        #expect(throws: Never.self, "filing that had begun is finished, though its caller was stopped") { try filed.get() }
        let moved = h.env.archive.appendingPathComponent(StubAnalyzer.edpFileName + ".txt").standardizedFileURL
        #expect(FileManager.default.fileExists(atPath: moved.path) && !FileManager.default.fileExists(atPath: url.path), "the file was moved")
        let record = try #require(try await h.services.documents.document(id: id))
        #expect(record.path == moved.path && record.status == .filed,
                "and the move is recorded with it, though the stop came between the two: a file is never in the archive while its record says it is in Incoming")
        let recorded = try await h.services.history.events(limit: 5, kinds: [.filed], docID: id).count
        #expect(recorded == 1, "the filing is in History")
    }
}

/// A subscriber to the ingest worker's status, as the app is one: everything it was sent, in order.
actor IngestFollower {
    private(set) var received: [IngestStatus] = []
    func add(_ status: IngestStatus) { received.append(status) }
}

/// While the archive is away the worker begins nothing, and a file in hand stops at its next stage.
@Suite struct ArchiveAwayIngestTests {
    @Test func whileTheArchiveIsAwayNothingInIncomingIsReadOrSentToTheModelAndOnceBackItIsFiled() async throws {
        let read = Reads()
        let h = try await Harness.make(analyzer: StubAnalyzer(during: { await read.add($0) }))
        defer { h.env.cleanup() }
        await h.coordinator.archive(isAway: true)
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP electricity"))
        await h.coordinator.start()
        #expect(await Patience.until { await h.coordinator.waits }, "the worker looks at its queue and waits")
        #expect((try? await h.jobs())?.map(\.state) == [.pending], "the archive away, the worker begins nothing: Incoming waits")
        #expect(await read.files.isEmpty, "and nothing is sent to the model")
        await h.coordinator.archive(isAway: false)
        #expect(await Patience.until { (try? await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 5).count) == 1 },
                "once it is back, the file is taken in by itself")
        #expect(await read.files.count == 1, "and read once")
        await h.coordinator.stop()
    }

    @Test func aFileInHandWhenTheArchiveGoesAwayStopsAtItsNextStageWithoutSpendingAnAttempt() async throws {
        let away = AwayOnRead()
        let h = try await Harness.make(analyzer: StubAnalyzer(during: { _ in await away.go() }))
        defer { h.env.cleanup() }
        await away.set(h.coordinator)
        await h.coordinator.enqueue(try h.env.drop("bill.txt", text: "EDP electricity"))
        await h.coordinator.start()
        // The archive goes away while the model reads the file.
        #expect(await Patience.until { (try? await h.jobs().first?.lastError) != nil }, "the file in hand stops at its next stage")
        let job = try? await h.jobs().first
        #expect(job?.state == .filing && job?.attempt == 0, "before it is filed, waiting for the archive without spending an attempt")
        #expect((try? await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 5))?.isEmpty == true, "nothing is filed")
        await h.coordinator.archive(isAway: false)
        #expect(await Patience.until { (try? await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 5).count) == 1 },
                "once it is back, it is filed")
        await h.coordinator.stop()
    }
}

/// Sends the archive away when the model reads a file, as a disk taken out then.
actor AwayOnRead {
    private var coordinator: IngestCoordinator?

    func set(_ coordinator: IngestCoordinator) { self.coordinator = coordinator }

    func go() async { await coordinator?.archive(isAway: true) }
}

/// The files the model was given, in the order it was.
actor Reads {
    private(set) var files: [String] = []

    func add(_ file: String) { files.append(file) }
}

/// Holds the model's reading of a file, when told to, until it is let go or the worker is stopped, as a model still
/// thinking when the app quits; what it holds now.
actor Holding {
    private var holding: String?
    private(set) var held: String?
    private var release: AsyncStream<Void>.Continuation?

    func hold(_ file: String) { holding = file }

    /// Lets the reading held go on, as a model that has finished thinking.
    func letGo() { release?.finish() }

    func read(_ file: String) async throws {
        guard file == holding else { return }
        holding = nil
        held = file
        defer { held = nil }
        let (until, release) = AsyncStream<Void>.makeStream()
        self.release = release
        for await _ in until {}
        try Task.checkCancellation()
    }
}

/// The model stumbles once over a file's reading, with an error that is no sign of Ollama being away.
actor Stumbles {
    private var file: String?

    init(once file: String) { self.file = file }

    func stumble(_ read: String) -> Bool {
        guard read == file else { return false }
        file = nil
        return true
    }
}

/// Stops a filing task when told to, as the app quitting stops its worker.
actor Stopper {
    private var task: Task<DocumentRecord, any Error>?
    private(set) var stopped = false

    var holds: Bool { task != nil }

    func hold(_ task: Task<DocumentRecord, any Error>) { self.task = task }

    func stop() {
        task?.cancel()
        stopped = true
    }
}

/// A trace sink that stops the filing once the file has been placed in the archive: between the move and its record.
struct StopAfterPlacing: TraceSink {
    let stopper: Stopper

    func append(traceID: Int64, step: TraceStep) async {
        if step.stage == .place { await stopper.stop() }
    }
}

/// Reads a file as the plain extractor does, under a deadline of a second that passes at once the first time, as a PDF that
/// PDFKit parses past its time: the first reading waits at `hold`, unaware of being cancelled, until the test opens it.
struct Stuck: ContentExtracting {
    let hold: Hold

    func extract(_ url: URL, sha256: String, context: ExtractionContext, trace: TraceContext) async throws -> ExtractedContent {
        // Only the first reading runs out of time; a later one is waited for.
        try await Deadline.run(1, time: TestTime(hold.arrivals == 0 ? .advances : .blocks), expired: { DeadlineExceeded(seconds: 1) }) {
            await hold.arrive()
            return try await PlainTestExtractor().extract(url, sha256: sha256, context: context, trace: trace)
        }
    }
}
