@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// How a worker takes a job: in the write that claims it, so no other worker, of this process or another, works on it,
/// and a claim that holds no more is taken again.
extension IngestQueueTests {
    @Test func aFileOneProcessHasInHandIsNeverWorkedOnByAnotherUntilItIsLetGo() async throws {
        let holding = Holding()
        let analyzer = StubAnalyzer(during: { try await holding.read($0) })
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        // `arrumatorcli` beside the app: another process over the same index, for which the app's process runs.
        let command = IngestCoordinator(services: Harness.services(h.env, analyzer: analyzer, config: h.env.config,
                                                                   claims: JobClaims(processes: TestProcesses(pid: TestProcesses.otherPID, running: [Harness.claims.processes.current]))))
        let id = try #require(await h.coordinator.enqueue(try h.env.drop("bill.txt", text: IngestTests.bill)))
        await holding.hold("bill.txt")
        let app = Task { await h.coordinator.drain() }
        #expect(await Patience.until { await holding.held == "bill.txt" }, "the app takes the file, and the model reads it")

        await command.drain()
        #expect(await analyzer.calls.files == ["bill.txt"], "the command leaves the file the app has in hand: it is read once, not twice at once")
        let inHand = try #require(try await h.services.jobs.job(id: id))
        #expect(inHand.state == .analysing && inHand.claimedBy == Harness.claims.processes.current.description,
                "and the job stays the app's, where the app has it")

        app.cancel()
        #expect(await app.value.isEmpty, "a job stopped part way is no failure the drain recorded")
        let letGo = try #require(try await h.services.jobs.job(id: id))
        #expect(letGo.claim == nil && letGo.state == .analysing, "the app, stopped, lets go of the job where it stopped")
        await command.drain()
        #expect(await analyzer.calls.files == ["bill.txt", "bill.txt"], "and the command then takes it up")
        let done = try #require(try await h.services.jobs.job(id: id))
        #expect(done.state == .done && done.claim == nil && done.claimedBy == nil, "and files it; a job that has ended is no one's")
    }

    @Test func twoWorkersOfOneProcessNeverWorkOnOneFileAndAClaimNoWorkerHasInHandIsTakenAgain() async throws {
        let holding = Holding()
        let (h, analyzer) = try await world(holding)
        defer { h.env.cleanup() }
        let other = IngestCoordinator(services: h.services)
        let id = try #require(await h.coordinator.enqueue(try h.env.drop("bill.txt", text: IngestTests.bill)))
        await holding.hold("bill.txt")
        let first = Task { await h.coordinator.drain() }
        #expect(await Patience.until { await holding.held == "bill.txt" }, "one worker has the file in hand")
        await other.drain()
        #expect(await analyzer.calls.files == ["bill.txt"], "the other worker of the same process leaves it to it")
        await holding.letGo()
        _ = await first.value
        // A claim of this process that no worker has in hand, as one whose letting go could not be written.
        let left = try #require(await h.coordinator.enqueue(try h.env.drop("left.txt", text: IngestTests.bill + " left")))
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET claim = 'gone', claimed_by = ? WHERE id = ?", arguments: [Harness.claims.processes.current.description, left])
        }
        await other.drain()
        #expect(try await [id, left].asyncMap { try await h.services.jobs.job(id: $0)?.state } == [.done, .done],
                "and a claim no worker of the process has in hand holds nothing: that file is filed too")
    }

    @Test func aJobCancelledWhileInHandIsLeftAsItWasCancelledAndItsFileWhereItIs() async throws {
        let holding = Holding()
        let (h, _) = try await world(holding)
        defer { h.env.cleanup() }
        let url = try h.env.drop("bill.txt", text: IngestTests.bill)
        let id = try #require(await h.coordinator.enqueue(url))
        await holding.hold("bill.txt")
        let worker = Task { await h.coordinator.drain() }
        #expect(await Patience.until { await holding.held == "bill.txt" }, "the worker has the file in hand, the model reading it")
        try await h.services.jobs.cancelActive(kinds: [.ingest])
        let cancelled = try #require(try await h.services.jobs.job(id: id))
        await holding.letGo()
        _ = await worker.value
        let after = try #require(try await h.services.jobs.job(id: id))
        #expect(after.state == .cancelled && after.payloadJson == cancelled.payloadJson && after.claim == nil,
                "the worker, its claim lost, saves nothing more of the job: \(after.state)")
        #expect(FileManager.default.fileExists(atPath: url.path), "and files nothing: the file stays where it is")
    }

    @Test func aMoveMadeAfterItsJobWasCancelledIsStillRecorded() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        // The job is cancelled as soon as its planned destination is kept, between that and the move's record.
        try await h.env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER cancelled_while_filing AFTER UPDATE OF payload_json ON jobs
                WHEN json_extract(NEW.payload_json, '$.plannedPath') IS NOT NULL AND NEW.claim IS NOT NULL
                BEGIN UPDATE jobs SET state = 'cancelled', claim = NULL, claimed_by = NULL WHERE id = NEW.id; END
                """)
        }
        let id = try #require(await h.coordinator.enqueue(try h.env.drop("bill.txt", text: IngestTests.bill)))
        await h.coordinator.drain()
        let job = try #require(try await h.services.jobs.job(id: id))
        let docID = try #require(job.docId)
        let document = try #require(try await h.services.documents.document(id: docID))
        #expect(job.state == .cancelled, "the job stays cancelled")
        #expect(document.status == .filed && FileManager.default.fileExists(atPath: document.path) && h.env.archive.holds(document.path),
                "but the file, moved, is recorded where it went, never left in the archive with a record saying Incoming")
    }

    @Test func anIdleWorkerLooksAgainAfterAWhileWhileAnotherProcessHoldsAJob() async throws {
        let processes = TestProcesses()
        let other = processes.start(pid: TestProcesses.otherPID)
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let h = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(), config: env.config,
                                                             claims: JobClaims(processes: processes)))
        let id = try #require(await h.coordinator.enqueue(try env.drop("bill.txt", text: IngestTests.bill)))
        try await env.database.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET claim = 'c', claimed_by = ? WHERE id = ?", arguments: [other.description, id])
        }
        let wait = await h.coordinator.idleWait(paused: false, power: false, archiveThere: true, queueUnread: false)
        #expect(wait == env.config.ingest.heldElsewhereRecheckSeconds,
                "while another process holds a job, the idle worker looks again after ingest.heldElsewhereRecheckSeconds: \(String(describing: wait))")
        processes.end(other)
        await h.coordinator.drain()
        #expect(try await h.services.jobs.job(id: id)?.state == .done, "and, that process ended, takes the job up then")
    }

    @Test func aFailingFileWhoseJobIsCancelledJustBeforeItIsSetAsideIsNotMoved() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        var config = env.config
        config.ingest.maxAttempts = 1
        let h = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(error: TestFailure("boom")), config: config))
        // The job is cancelled as soon as its failed attempt is saved: after the worker last found it its own, before the
        // file would be set aside in the archive.
        try await env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER cancelled_before_setting_aside AFTER UPDATE OF last_error ON jobs
                WHEN NEW.last_error IS NOT NULL AND NEW.claim IS NOT NULL
                BEGIN UPDATE jobs SET state = 'cancelled', claim = NULL, claimed_by = NULL WHERE id = NEW.id; END
                """)
        }
        let url = try env.drop("bill.txt", text: IngestTests.bill)
        let id = try #require(await h.coordinator.enqueue(url))
        #expect(await h.coordinator.drain().isEmpty, "a failure no longer the worker's to set aside is none it recorded")
        #expect(try await h.services.jobs.job(id: id)?.state == .cancelled, "the job stays cancelled")
        let ended = try await env.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT outcome FROM traces WHERE job_id = ? ORDER BY id DESC LIMIT 1", arguments: [id])
        }
        #expect(ended == JobOutcome.cancelled.rawValue, "and its trace ends there, as cancelled")
        let archived = try FileManager.default.contentsOfDirectory(atPath: env.archive.path)
        #expect(FileManager.default.fileExists(atPath: url.path) && archived.isEmpty,
                "the file is not moved: the claim is checked again in the write just before the move")
    }

    /// A job cancelled while its failure is looked at, as while Ollama is probed for a request that took too long, is
    /// no longer the worker's when the failure would be saved: nothing is saved, and the drain records no failure of it.
    @Test func aJobCancelledAsItsFailureIsSavedIsNoFailureTheDrainRecorded() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let jobs = JobStore(database: env.database, time: env.time)
        let ollama = MockOllama { _ in "" }
        await ollama.whileProbed { _ = try? await jobs.cancelActive(kinds: [.ingest]) }
        let h = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(error: OllamaError.timeout("took too long")),
                                                             ollama: ollama, config: env.config))
        let id = try #require(await h.coordinator.enqueue(try env.drop("bill.txt", text: IngestTests.bill)))
        #expect(await h.coordinator.drain().isEmpty, "the attempt is not saved, so the drain failed nothing")
        let job = try await h.services.jobs.job(id: id)
        #expect(job?.state == .cancelled && job?.attempt == 0, "the job stays as it was cancelled: \(String(describing: job))")
        let ended = try await env.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT outcome FROM traces WHERE job_id = ? ORDER BY id DESC LIMIT 1", arguments: [id])
        }
        #expect(ended == JobOutcome.cancelled.rawValue, "and its trace ends there, as cancelled, rather than run on")
    }

    @Test func aFailureOfAJobCancelledMeanwhileChangesNothingOfItsFileOrItsDocument() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let jobs = JobStore(database: env.database, time: env.time)
        let analyzer = StubAnalyzer(during: { _ in
            try await jobs.cancelActive(kinds: [.ingest])
            throw TestFailure("boom")
        })
        var config = env.config
        config.ingest.maxAttempts = 1
        let h = Harness(env: env, services: Harness.services(env, analyzer: analyzer, config: config))
        let url = try env.drop("bill.txt", text: IngestTests.bill)
        let id = try #require(await h.coordinator.enqueue(url))
        #expect(await h.coordinator.drain().isEmpty, "a failure of a job no longer the worker's is none it recorded")
        #expect(try await h.services.jobs.job(id: id)?.state == .cancelled, "the job stays cancelled")
        #expect(FileManager.default.fileExists(atPath: url.path), "its file is not set aside in the archive as failed")
        let failed = try await h.services.history.events(limit: 5, kinds: [.failed, .retry]).count
        #expect(failed == 0, "and no failure is recorded for a job that is no longer the worker's")
    }

    @Test func aFileAJobOfAProcessThatHasEndedHeldIsWaitedForUntilItIsDue() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(await h.coordinator.enqueue(try h.env.drop("bill.txt", text: IngestTests.bill)))
        let crashed = ProcessTag(pid: Harness.claims.processes.current.pid, started: Harness.claims.processes.current.started - 1)
        let due = h.env.time.now().addingTimeInterval(30)
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET claim = 'gone', claimed_by = ?, next_run_at = ? WHERE id = ?",
                           arguments: [crashed.description, due.unixSeconds, id])
        }
        #expect(try await h.services.jobs.earliestDue(claiming: Harness.claims) == due,
                "the worker waits until the job a crashed process held is due")
        let wait = await h.coordinator.idleWait(paused: false, power: false, archiveThere: true, queueUnread: false)
        #expect(wait == 30, "and looks for it then, rather than waiting for a ring that may never come")
    }

    @Test func aFileAProcessThatHasEndedHadInHandIsTakenAgain() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(await h.coordinator.enqueue(try h.env.drop("bill.txt", text: IngestTests.bill)))
        // Taken by a process that has since crashed: its id is this one's, and it started at another time.
        let crashed = ProcessTag(pid: Harness.claims.processes.current.pid, started: Harness.claims.processes.current.started - 1)
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET claim = 'gone', claimed_by = ? WHERE id = ?", arguments: [crashed.description, id])
        }
        await h.coordinator.drain()
        let job = try #require(try await h.services.jobs.job(id: id))
        #expect(job.state == .done, "the job a crashed process held is taken again and filed, never left for ever")
    }

    /// The job a worker would take now, let go again at once, so the queue is as it was.
    static func next(in jobs: JobStore) async throws -> Int64? {
        guard let job = try await jobs.nextDue(claiming: Harness.claims) else { return nil }
        try await jobs.release(job, claims: Harness.claims)
        return job.id
    }
}
