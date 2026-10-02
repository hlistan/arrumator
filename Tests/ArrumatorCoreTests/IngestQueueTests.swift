@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The ingest queue takes files in the order they arrived (`JobStore.nextDue`). A file stopped part way, as when the app
/// quits while the model reads it, keeps its stage and its place, and carries on first at the next start; one waiting to
/// be tried again holds up none behind it. Quitting stops the queues before the app ends, and a stop never separates a
/// move into the archive from its record.
@Suite struct IngestQueueTests {
    /// Whether the worker takes files on this Mac now, with pausing on battery turned off as these tests turn it off: a
    /// Mac too hot to work makes it wait.
    static func workerRuns() throws -> Bool {
        var settings = try AppSettings.bundledDefaults()
        settings.pauseOnBattery = false
        return PowerState.current().pauseReason(settings: settings, config: try PipelineConfig.bundledDefaults().power) == nil
    }

    /// The pipeline over files read by an analyzer that holds the reading `holding` names until the worker is stopped,
    /// with an archive to file into and a worker that runs on battery too.
    private func world(_ holding: Holding) async throws -> (h: Harness, analyzer: StubAnalyzer) {
        let analyzer = StubAnalyzer(during: { try await holding.read($0) })
        let h = try await Harness.make(analyzer: analyzer)
        try await h.env.settings.update { $0.pauseOnBattery = false }
        try FileManager.default.createDirectory(at: h.env.archive, withIntermediateDirectories: true)
        return (h, analyzer)
    }

    @Test(.enabled("the worker waits while the Mac is too hot to work") { try IngestQueueTests.workerRuns() })
    func aFileStoppedPartWayCarriesOnFirstAtTheNextStartBeforeTheFilesThatArrivedAfterIt() async throws {
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
        let inHand = IngestStatus.Current(job: a, path: try #require(reading.first?.sourcePath), stage: .analysing)
        let status = await h.coordinator.status
        #expect(status.current == inHand, "the status names the file in hand and the stage it is at")
        #expect(await Patience.until { await follower.received.last?.current == inHand }, "and a subscriber, as the app is one, is sent it")
        #expect(reading.map { status.progress(of: $0) } == [.working(.analysing), .waiting, .waiting],
                "the file in hand is the one being worked on; the others wait their turn")
        await h.coordinator.stop()
        let stopped = try await h.jobs()
        #expect(stopped.map(\.state) == [.analysing, .pending, .pending], "the file in hand stays at the stage it was stopped in")
        #expect(stopped.first?.payload.content != nil && stopped.first?.attempt == 0 && stopped.first?.lastError == nil,
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

    @Test(.enabled("the worker waits while the Mac is too hot to work") { try IngestQueueTests.workerRuns() })
    func whatAFileInTheQueueAndTheOneInHandShowIsTheTagTheyWillBeGivenThroughAStopAndARestart() async throws {
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

    @Test func aFileWaitingToBeTriedAgainHoldsUpNoneBehindItAndThenTakesItsPlaceByWhenItArrived() async throws {
        let stumbles = Stumbles(once: "a.txt")
        let analyzer = StubAnalyzer(during: { if await stumbles.stumble($0) { throw IngestError.invalidState("the model stumbled") } })
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        let jobs = h.services.jobs
        let a = try #require(await h.coordinator.enqueue(try h.env.drop("a.txt", text: "EDP electricity, July")))
        await h.coordinator.enqueue(try h.env.drop("b.txt", text: "EDP electricity, August"))
        await h.coordinator.drain()
        let waiting = try #require(try await jobs.job(id: a))
        #expect(waiting.state == .analysing && waiting.attempt == 1 && waiting.lastError == "the model stumbled",
                "the file whose reading failed waits to be tried again from that stage")
        let meanwhile = try await h.jobs().map(\.state)
        #expect(meanwhile == [.analysing, .done], "and the file behind it is filed meanwhile")
        let readFirst = await analyzer.calls.files
        #expect(readFirst == ["a.txt", "b.txt"], "it is not tried again before its time")

        // While it waits, the index is rebuilt (the filed document is read again for search) and another file arrives.
        let filed = try #require(try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 5).first)
        let reindex = try #require(try await jobs.enqueue(path: filed.path, kind: .reindex, docID: filed.id))
        let c = try #require(await h.coordinator.enqueue(try h.env.drop("c.txt", text: "EDP electricity, September")))
        let beforeItsTime = try await jobs.nextDue()?.id
        #expect(beforeItsTime == c,
                "a file that arrives meanwhile is not held up by the one waiting, and reading again for search gives way to it")
        h.env.time.advance(by: try #require(waiting.nextRunAt).timeIntervalSince(h.env.time.now()))
        let atItsTime = try await jobs.nextDue()?.id
        #expect(atItsTime == a,
                "once its time has come, the file that waited takes its place by when it arrived: before the file that came after it")
        await h.coordinator.drain()
        let read = await analyzer.calls.files
        #expect(read == ["a.txt", "b.txt", "a.txt", "c.txt"], "it is read again, then the file that arrived after it")
        let reread = try await jobs.job(id: reindex)?.state
        #expect(reread == .done, "and the document is read again for search once no file waits")
        let drained = try await h.jobs().map(\.state)
        #expect(drained == [.done, .done, .done, .done], "nothing is left in the queue")
    }

    @Test func whichFileIsInHandAndWhichWaitIsWhatTheStatusSaysOfThem() async throws {
        let store = JobStore(database: try AppDatabase.inMemory(), time: TestTime(.advances))
        func job(_ name: String, _ state: JobState) async throws -> JobRecord {
            let id = try #require(try await store.enqueue(path: "/Incoming/\(name)", kind: .ingest))
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

        func working(_ job: JobRecord, at stage: JobState) throws -> IngestStatus {
            var status = IngestStatus.idle
            status.current = IngestStatus.Current(job: try #require(job.id), path: job.sourcePath, stage: stage)
            return status
        }
        let onStopped = try working(stopped, at: .analysing)
        #expect(onStopped.progress(of: stopped) == .working(.analysing), "the file the worker names is in hand, at the stage it names")
        #expect(onStopped.progress(of: waiting) == .waiting && onStopped.progress(of: failed) == idle.progress(of: failed),
                "while the others wait as they did")
        #expect(try working(stopped, at: .filing).progress(of: stopped) == .working(.filing),
                "the worker's stage is the one shown, newer than a list read before")
        #expect(try working(failed, at: .extracting).progress(of: failed) == .working(.extracting), "a file tried again is in hand while it is")
        #expect(try working(stopped, at: .done).progress(of: stopped) == nil,
                "a file the worker has just finished is no longer in the queue, whatever a list read before says")
        var done = stopped
        done.state = .done
        #expect(idle.progress(of: done) == nil, "nor is a file filed")
        #expect(JobProgress.working(.hashing).isWorking
                    && ![JobProgress.resuming(.analysing), .retrying("", at: nil), .waiting].contains(where: \.isWorking),
                "only the file in hand is said to be worked on")
    }

    @Test func aDocumentAskedToBeReadAgainWaitsItsTurnNotBegunAndStartsFromTheTextItArrivedWith() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        try await h.review.retry(id)
        let queued = try #require(try await h.services.jobs.active().first)
        #expect(IngestStatus.idle.progress(of: queued) == .waiting,
                "a document asked to be read again waits its turn as not begun: it did not stop anywhere to carry on from")
        await h.coordinator.drain()
        let events = try await h.services.history.events(limit: 20, kinds: [.extracted, .analysed], docID: id).map(\.kind)
        #expect(events.filter { $0 == .analysed }.count == 2 && events.filter { $0 == .extracted }.count == 1,
                "taken, it is read again from the text it arrived with, which is not extracted again")
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
        let source = SourceFile(path: url.path, originalFilename: "bill.txt", fileExtension: "txt", utType: "public.plain-text",
                                byteSize: fingerprint.size, createdAt: nil, modifiedAt: fingerprint.modified, sha256: sha)
        let settings = await h.env.settings.current
        let stopper = Stopper()
        // Stopped, as the app quitting stops the worker, as soon as the file has been moved and before the move is recorded.
        let traced = try await h.services.startTrace(docID: id, jobID: nil, attempt: 0, source: .ingest, settings: settings)
        let trace = TraceContext(traceID: traced.traceID, sink: StopAfterPlacing(stopper: stopper))
        let filing = Task {
            _ = await Patience.until { await stopper.holds }
            return try await h.services.filer.file(document, source: source, analysis: DocumentAnalysis(fileName: StubAnalyzer.edpFileName, model: "stub"),
                                                   status: .filed, directory: h.env.archive, inPlace: false, actor: .system,
                                                   settings: settings, trace: trace, event: nil, recording: nil)
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

/// A stop that ends: whether its task was cancelled, each time it ended.
actor Ending {
    private(set) var ended: [Bool] = []
    func end() { ended.append(Task.isCancelled) }
}

/// Holds the model's reading of a file, when told to, until the worker is stopped, as a model still thinking when the
/// app quits; what it holds now.
actor Holding {
    private var holding: String?
    private(set) var held: String?

    func hold(_ file: String) { holding = file }

    func read(_ file: String) async throws {
        guard file == holding else { return }
        holding = nil
        held = file
        defer { held = nil }
        try await TestTime(.blocks).sleep(seconds: 1)
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
