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

    @Test func whileOllamaIsAwayNoOtherFileIsTakenUntilTheOneThatFoundItIsTriedAgain() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(error: OllamaError.unreachable("connection refused")))
        defer { h.env.cleanup() }
        for name in ["a.txt", "b.txt", "c.txt"] { await h.coordinator.enqueue(try h.env.drop(name, text: "\(IngestTests.bill) \(name)")) }
        await h.coordinator.drain()
        #expect(try await h.jobs().map(\.state) == [.analysing, .pending, .pending],
                "the first waits for Ollama where it stopped, and the others are not read for their text only to wait too")
        let wait = await h.coordinator.idleWait(paused: false, power: false, archiveThere: true, queueUnread: false)
        #expect(wait == h.env.config.ingest.retryDelays.last, "the worker waits until it is tried again, rather than take the others")
        let retry = h.env.time.now().addingTimeInterval(h.env.config.ingest.retryDelays.last)
        let status = await h.coordinator.status
        let progress = try await h.jobs().dropFirst().map { status.progress(of: $0) }
        #expect(status.waitingForOllama && status.retryAt == retry && progress == [.waitingForOllama(until: retry), .waitingForOllama(until: retry)],
                "and Incoming says the others wait for Ollama until then, not only when they arrived: \(progress)")

        h.env.time.advance(by: h.env.config.ingest.retryDelays.last)
        await h.coordinator.drain()
        #expect(try await h.jobs().map(\.state) == [.analysing, .pending, .pending], "tried again while Ollama is still away, it waits again alone")
        let said = try await h.services.history.events(limit: 20, kinds: [.extracted, .retry]).map(\.summary)
        #expect(said.count == 2 && said.first?.hasPrefix("Waiting for Ollama") == true,
                "History says once that its text was read and once that it waits, however often it is tried: \(said)")
    }

    /// The file that found Ollama away is left for later meanwhile, and nothing else is queued: nothing waits for Ollama
    /// any more, which the status says, rather than wait for it until another file comes (the review of the fix of
    /// QA 2026-10-05, RA-1).
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
