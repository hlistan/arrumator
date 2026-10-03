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
}
