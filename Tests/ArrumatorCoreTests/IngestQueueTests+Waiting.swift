@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// How the worker waits when it takes no job: paused, too hot, without the archive, or for work given up on to end.
extension IngestQueueTests {
    /// The pipeline over a clock that never passes on its own, as `SleepLog` keeps it, on the Mac's `power`, with one file
    /// waiting in Incoming.
    func waitingWorld(power: @escaping @Sendable () -> PowerState = { Harness.cool }) async throws
        -> (h: Harness, log: SleepLog, job: Int64) {
        let env = try await TestEnvironment.make()
        let log = SleepLog(env.time)
        var services = Harness.services(env, analyzer: StubAnalyzer(), config: env.config, power: power)
        services.time = log
        let h = Harness(env: env, services: services)
        let job = try #require(await h.coordinator.enqueue(try env.drop("bill.txt", text: IngestTests.bill)))
        return (h, log, job)
    }

    @Test func whilePausedTheWorkerTakesNothingAndWaitsToBeToldItIsResumed() async throws {
        let looked = Mutex(0)
        let (h, _, id) = try await waitingWorld(power: {
            looked.withLock { $0 += 1 }
            return Harness.cool
        })
        defer { h.env.cleanup() }
        try await h.env.settings.update { $0.paused = true }
        await h.coordinator.start()
        #expect(await Patience.until { looked.withLock { $0 } > 0 }, "the worker looks while paused")
        #expect(try await h.services.jobs.job(id: id)?.state == .pending, "and takes nothing")
        let paused = await h.coordinator.idleWait(paused: true, power: false, archiveThere: true, queueUnread: false)
        #expect(paused == nil, "paused, it waits to be told it is resumed, never looking again on a timer while the file is due")
        try await h.env.settings.update { $0.paused = false }
        await h.coordinator.wake()
        #expect(try await Patience.until { try await h.services.jobs.job(id: id)?.state == .done }, "resumed, it files the file")
        await h.coordinator.stop()
    }

    @Test func whileTheArchiveIsAwayTheWorkerWaitsAsLongAsAJobWaitsForItAndTakesNothing() async throws {
        let (h, log, id) = try await waitingWorld()
        defer { h.env.cleanup() }
        try FileManager.default.removeItem(at: h.env.archive)
        await h.coordinator.start()
        #expect(await Patience.until { !log.sleeps.isEmpty }, "the worker waits")
        #expect(log.sleeps == [h.env.config.ingest.retryDelays.last],
                "as long as a job waits for the archive's folder, rather than looking again at once: \(log.sleeps)")
        try FileManager.default.createDirectory(at: h.env.archive, withIntermediateDirectories: true)
        await h.coordinator.wake()
        #expect(try await Patience.until { try await h.services.jobs.job(id: id)?.state == .done }, "once it is there, the file is filed")
        await h.coordinator.stop()
    }

    @Test func whileTheMacIsTooHotTheWorkerTakesNothingAndLooksAgainAfterItsTime() async throws {
        let hot = Mutex(true)
        let (h, log, id) = try await waitingWorld(power: {
            let thermal: ThermalLevel = hot.withLock { $0 } ? .critical : .nominal
            return PowerState(onBattery: false, batteryPercent: nil, thermal: thermal, lowPowerMode: false)
        })
        defer { h.env.cleanup() }
        await h.coordinator.start()
        #expect(await Patience.until { await h.coordinator.status.powerPauseReason == "thermal state critical" },
                "the status says why the worker waits")
        #expect(await Patience.until { !log.sleeps.isEmpty } && log.sleeps == [h.env.config.power.recheckSeconds],
                "and it looks again after power.recheckSeconds: \(log.sleeps)")
        #expect(try await h.services.jobs.job(id: id)?.state == .pending, "taking nothing meanwhile")
        hot.withLock { $0 = false }
        await h.coordinator.wake()
        #expect(try await Patience.until { try await h.services.jobs.job(id: id)?.state == .done }, "cooled, it files the file")
        #expect(await h.coordinator.status.powerPauseReason == nil, "and no longer says it waits")
        await h.coordinator.stop()
    }

    @Test func aFileWhoseReadingWasGivenUpOnIsNotReadAgainWhileThatReadingStillRuns() async throws {
        let stuck = Hold()
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        var config = env.config
        config.ingest.retryDelays = NonEmpty(0, [])
        let h = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(), extractor: Stuck(hold: stuck), config: config))
        let id = try #require(await h.coordinator.enqueue(try env.drop("scan.txt", text: IngestTests.bill)))
        await h.coordinator.drain()
        #expect(await Patience.until { stuck.arrivals == 1 }, "the first reading is stuck, and its deadline gave up on it")
        let waiting = try #require(try await h.services.jobs.job(id: id))
        #expect(waiting.attempt == 1 && waiting.state == .extracting,
                "the job, due again at once, is not read again while the reading given up on still runs")

        stuck.open()
        #expect(try await Patience.until {
            await h.coordinator.drain()
            return try await h.services.jobs.job(id: id)?.state == .done
        }, "once it has ended, the file is read again and filed")
        #expect(stuck.arrivals == 2, "read twice in all, never two at once")
    }

    @Test func aFileWhoseReadingGivenUpOnNeverEndsFailsSayingWhyAfterItsTime() async throws {
        let stuck = Hold()
        let env = try await TestEnvironment.make()
        defer {
            stuck.open()
            env.cleanup()
        }
        var config = env.config
        config.ingest.retryDelays = NonEmpty(0, [])
        let h = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(), extractor: Stuck(hold: stuck), config: config))
        let url = try env.drop("scan.txt", text: IngestTests.bill)
        let id = try #require(await h.coordinator.enqueue(url))
        await h.coordinator.drain()
        #expect(await Patience.until { stuck.arrivals == 1 }, "the reading is stuck, and its deadline gave up on it")
        let bound = config.ingest.abandonedWorkSeconds
        #expect(await h.coordinator.idleWait(paused: false, power: false, archiveThere: true, queueUnread: false) == bound,
                "the worker looks again when the reading has had its time")
        env.time.advance(by: bound)
        await h.coordinator.drain()
        let failed = try #require(try await h.services.jobs.job(id: id))
        #expect(failed.state == .failed && failed.lastError == IngestError.workLeftRunning(seconds: bound).localizedDescription,
                "past ingest.abandonedWorkSeconds the job fails, saying why, rather than waiting for ever: \(failed.lastError ?? "")")
        #expect(stuck.arrivals == 1 && FileManager.default.fileExists(atPath: url.path),
                "it is never read again beside the reading that has not ended, and the file stays in Incoming, in Needs You")
    }

    @Test func whileOllamaIsAwayNoOtherFileIsReadForItsTextUntilTheOneThatFoundItIsTriedAgain() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(error: OllamaError.unreachable("connection refused")))
        defer { h.env.cleanup() }
        for name in ["a.txt", "b.txt", "c.txt"] { await h.coordinator.enqueue(try h.env.drop(name, text: "\(IngestTests.bill) \(name)")) }
        await h.coordinator.drain()
        let retry = h.env.time.now().addingTimeInterval(h.env.config.ingest.retryDelays.last)
        #expect(try await h.jobs().map(\.state) == [.analysing, .extracting, .extracting],
                "the first waits for Ollama where it stopped, and the others, looked at, are not read for their text only to wait too")
        #expect(try await h.jobs().dropFirst().map(\.nextRunAt) == [retry, retry], "they wait until the first is tried again")
        let wait = await h.coordinator.idleWait(paused: false, power: false, archiveThere: true, queueUnread: false)
        #expect(wait == h.env.config.ingest.retryDelays.last, "the worker waits until it is tried again, rather than take the others")
        let status = await h.coordinator.status
        let progress = try await h.jobs().dropFirst().map { status.progress(of: $0) }
        #expect(status.waitingForOllama && status.retryAt == retry && progress == [.waitingForOllama(until: retry), .waitingForOllama(until: retry)],
                "and Incoming says the others wait for Ollama until then, not only when they arrived: \(progress)")

        h.env.time.advance(by: h.env.config.ingest.retryDelays.last)
        await h.coordinator.drain()
        #expect(try await h.jobs().map(\.state) == [.analysing, .extracting, .extracting],
                "tried again while Ollama is still away, it waits again alone")
        let said = try await h.services.history.events(limit: 20, kinds: [.extracted, .retry]).map(\.summary)
        #expect(said.count == 2 && said.first?.hasPrefix("Waiting for Ollama") == true,
                "History says once that its text was read and once that it waits, however often it is tried: \(said)")
    }

    /// While Ollama is away a file that comes is still looked at, which needs no model: an exact copy of a document is
    /// handed over to it and goes to the Trash, and a file gone before it is read is recorded as gone; only a document
    /// read again, or another file's text, waits for Ollama (the review of #17 found a copy left in Incoming meanwhile).
    @Test func whileOllamaIsAwayAFileThatComesIsStillHandedOverToItsOriginalOrRecordedGone() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer { name in
            if name != "bill.txt" { throw OllamaError.unreachable("connection refused") }
        })
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: IngestTests.bill)
        await h.coordinator.enqueue(try h.env.drop("away.txt", text: "\(IngestTests.bill) away"))
        await h.coordinator.drain()
        let copy = try h.env.drop("bill copy.txt", text: IngestTests.bill)
        let gone = try h.env.drop("gone.txt", text: "\(IngestTests.bill) gone")
        let other = try h.env.drop("other.txt", text: "\(IngestTests.bill) other")
        for url in [copy, gone, other] { await h.coordinator.enqueue(url) }
        try FileManager.default.removeItem(at: gone)
        await h.coordinator.drain()
        #expect(h.env.trashed().map(\.lastPathComponent) == ["bill copy.txt"] && !FileManager.default.fileExists(atPath: copy.path),
                "the copy is handed over to its original and leaves Incoming for the Trash")
        let states = Dictionary(uniqueKeysWithValues: try await h.jobs().filter { $0.kind != .reanalyse }
            .map { (URL(fileURLWithPath: $0.sourcePath).lastPathComponent, $0.state) })
        #expect(states["gone.txt"] == .cancelled && states["other.txt"] == .extracting && states["away.txt"] == .analysing,
                "a file gone is done with, and another waits, unread, beside the one that found Ollama away: \(states)")
        let again = try await h.jobs().filter { $0.kind == .reanalyse }.map { ($0.docId, $0.state) }
        #expect(again.count == 1 && again.first?.0 == original.id && again.first?.1 == .pending,
                "the original is to be read again for its copy, once Ollama is back: \(again)")
        let said = try await h.services.history.events(limit: 20, kinds: [.duplicate, .missing, .extracted]).map(\.kind)
        #expect(said.filter { $0 == .duplicate }.count == 1 && said.filter { $0 == .missing }.count == 1,
                "History records the copy and the file gone: \(said)")
        #expect(try await h.services.history.events(limit: 20, kinds: [.extracted]).count == 2,
                "and reads no text but the original's and that of the file that found Ollama away")
    }

    /// A file taken while Ollama is away that fails before the model, as one that cannot be read, says nothing of
    /// Ollama: the wait stays as it is, and no other file is read for its text only to wait too (the review of the fix
    /// of the final review of #17).
    @Test(.fileModesKeepOut)
    func aFileThatFailsWhileOllamaIsAwayLeavesTheWaitAsItIs() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer { name in
            if name != "bill.txt" { throw OllamaError.unreachable("connection refused") }
        })
        defer { h.env.cleanup() }
        _ = try await h.ingest("bill.txt", text: IngestTests.bill)
        await h.coordinator.enqueue(try h.env.drop("away.txt", text: "\(IngestTests.bill) away"))
        await h.coordinator.drain()
        let retry = h.env.time.now().addingTimeInterval(h.env.config.ingest.retryDelays.last)
        let copy = try h.env.drop("bill copy.txt", text: IngestTests.bill)
        let locked = try h.env.drop("locked.txt", text: "\(IngestTests.bill) locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        for url in [copy, locked] { await h.coordinator.enqueue(url) }
        await h.coordinator.drain()
        let failed = try await h.jobs().first { $0.sourcePath.hasSuffix("locked.txt") }
        #expect(failed?.lastError != nil, "the file that cannot be read fails its attempt")
        let status = await h.coordinator.status
        #expect(status.waitingForOllama && status.retryAt == retry, "and the wait for Ollama stays as it was: \(status)")
        let again = try await h.jobs().filter { $0.kind == .reanalyse }.map(\.state)
        #expect(again == [.pending], "the original, to be read again for its copy, is not read only to wait: \(again)")
        #expect(try await h.services.history.events(limit: 20, kinds: [.extracted]).count == 2, "no other text is read")
    }

    /// While Ollama is away only a job whose next stage needs no model is taken (`JobStore.beforeTheModel`): a file that
    /// came, in Incoming or put into the archive, not hashed yet; not one at a later stage, nor a document read again or
    /// indexed again, whose next stage reads its text for the model.
    @Test func whileOllamaIsAwayOnlyAFileThatCameAndIsNotHashedYetIsTaken() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let jobs = h.services.jobs
        func queued(_ name: String, _ kind: JobKind, at state: JobState = .pending) async throws -> Int64 {
            let id = try await jobs.enqueue(path: h.env.incoming.appendingPathComponent(name).path, kind: kind).id
            if state != .pending, var job = try await jobs.job(id: id) {
                job.state = state
                try await jobs.update(job)
            }
            return id
        }
        func taken() async throws -> Int64? {
            let job = try await jobs.nextDue(claiming: Harness.claims, beforeTheModel: true)
            if let job { try await jobs.release(job, claims: Harness.claims) }
            return job?.id
        }
        let extracting = try await queued("a.pdf", .ingest, at: .extracting)
        let reading = try await queued("b.pdf", .reanalyse)
        let indexing = try await queued("c.pdf", .reindex)
        #expect(try await taken() == nil, "a file at a later stage, a document read again or indexed again waits for Ollama")
        let came = try await queued("d.pdf", .ingest)
        #expect(try await taken() == came, "a file that came, not hashed yet, is looked at")
        let hashing = try await queued("e.pdf", .adopt, at: .hashing)
        if var done = try await jobs.job(id: came) {
            done.state = .done
            try await jobs.update(done)
        }
        #expect(try await taken() == hashing, "and so is one put into the archive, part way through its hashing")
        #expect(try await jobs.nextDue(claiming: Harness.claims)?.id == extracting && reading > extracting && indexing > reading,
                "once Ollama is back the first in the queue is taken, whatever it needs")
    }

    @Test func noWaitForOllamaIsSaidOnceNothingIsLeftThatWaits() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(error: OllamaError.unreachable("connection refused")))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("a.txt", text: IngestTests.bill))
        await h.coordinator.drain()
        #expect(await h.coordinator.status.waitingForOllama, "the file waits for Ollama")
        let job = try #require(try await h.jobs().first?.id)
        _ = try await h.services.jobs.cancelActive(kinds: [.ingest])
        await h.coordinator.drain()
        let status = await h.coordinator.status
        #expect(!status.waitingForOllama && status.retryAt == nil && status.queued == 0, "nothing is said to wait: \(status)")
        #expect(try await h.services.jobs.job(id: job)?.state == .cancelled, "its job was let go")
    }

    /// What the evaluation reads each fixture with: a file queued while another waits for Ollama, which is back by the
    /// time that one is tried again, is read then, not left unread (the second review of the fix of QA 2026-10-05,
    /// RA-1, which found a short restart of Ollama left a stretch of fixtures unread).
    @Test func aFileHeldWhileOllamaIsAwayIsReadOnceItIsBackWhenItsDrainWaitsForIt() async throws {
        let ollama = Reachability()
        let h = try await Harness.make(analyzer: StubAnalyzer(during: { _ in
            guard await ollama.up else {
                await ollama.set(up: true)
                throw OllamaError.unreachable("connection refused")
            }
        }))
        defer { h.env.cleanup() }
        await h.coordinator.enqueue(try h.env.drop("a.txt", text: "\(IngestTests.bill) a"))
        await h.coordinator.drain()
        let held = try #require(await h.coordinator.enqueue(try h.env.drop("b.txt", text: "\(IngestTests.bill) b")))
        let started = h.env.time.now()
        await h.coordinator.drain(waitingOutOllamaFor: held)
        #expect(try await h.jobs().map(\.state) == [.done, .done], "both are read once Ollama is back")
        #expect(h.env.time.now() == started.addingTimeInterval(h.env.config.ingest.retryDelays.last),
                "after waiting until the first was tried again, no longer")
    }

    /// A worker stopped while its file waits for Ollama no longer says it waits for it, as the queues of search tasks and
    /// questions do not (the second review of the fix of QA 2026-10-05, RA-1).
    @Test func aStoppedWorkerWaitsForNothingThoughItsFileWaitedForOllama() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(error: OllamaError.unreachable("connection refused")))
        defer { h.env.cleanup() }
        await h.coordinator.start()
        await h.coordinator.enqueue(try h.env.drop("a.txt", text: IngestTests.bill))
        #expect(await Patience.until { await h.coordinator.status.waitingForOllama }, "the running worker finds Ollama away")
        await h.coordinator.stop()
        let status = await h.coordinator.status
        #expect(!status.waitingForOllama && status.retryAt == nil, "stopped, it waits for nothing until it starts again: \(status)")
    }

    /// The third review of the fix of QA 2026-10-05, RA-1: while the file that found Ollama away was tried again, and read,
    /// the status kept saying when it would be tried, a time already past.
    @Test func whileAFileThatFoundOllamaAwayIsTriedAgainNoTimeIsSaid() async throws {
        let ollama = Reachability()
        let witness = IngestWitness()
        let h = try await Harness.make(analyzer: StubAnalyzer(during: { _ in
            await witness.look()
            guard await ollama.up else { throw OllamaError.unreachable("connection refused") }
        }))
        defer { h.env.cleanup() }
        await witness.watch(h.coordinator)
        await h.coordinator.enqueue(try h.env.drop("a.txt", text: IngestTests.bill))
        await h.coordinator.drain()
        await ollama.set(up: true)
        h.env.time.advance(by: h.env.config.ingest.retryDelays.last)
        await h.coordinator.drain()
        let tried = try #require(await witness.seen.last)
        #expect(tried.current != nil && tried.retryAt == nil, "the file in hand is being tried: no time to try it again is said")
        #expect(try await h.jobs().map(\.state) == [.done], "and it is filed")
    }

    /// The third review: a drain that waits for Ollama on behalf of a file, once the file that found it away is let go
    /// and its own turn is later, ends rather than look again and again for nothing.
    @Test(.timeLimit(.minutes(1))) func aDrainThatWaitsForOllamaEndsWhenNothingIsLeftToTakeOnceItsTimeHasCome() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(error: OllamaError.unreachable("connection refused")))
        defer { h.env.cleanup() }
        let first = try #require(await h.coordinator.enqueue(try h.env.drop("a.txt", text: "\(IngestTests.bill) a")))
        await h.coordinator.drain()
        let held = try #require(await h.coordinator.enqueue(try h.env.drop("b.txt", text: "\(IngestTests.bill) b")))
        var later = try #require(try await h.services.jobs.job(id: held))
        later.nextRunAt = h.env.time.now().addingTimeInterval(10 * h.env.config.ingest.retryDelays.last)
        try await h.services.jobs.update(later)
        var letGo = try #require(try await h.services.jobs.job(id: first))
        letGo.state = .cancelled
        try await h.services.jobs.update(letGo)
        await h.coordinator.drain(waitingOutOllamaFor: held)
        #expect(try await h.services.jobs.job(id: held)?.state == .pending, "it ends, leaving the file to its turn")
    }
}

/// What the ingest worker's status was each time a file was read.
actor IngestWitness {
    private var coordinator: IngestCoordinator?
    private(set) var seen: [IngestStatus] = []
    func watch(_ coordinator: IngestCoordinator) { self.coordinator = coordinator }
    func look() async {
        if let coordinator { seen.append(await coordinator.status) }
    }
}
