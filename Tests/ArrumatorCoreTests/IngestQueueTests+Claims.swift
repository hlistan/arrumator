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

    /// How a reading fails, each a path of its own through the failure of a job (`handleFailure`).
    enum Failing: String, CaseIterable, Sendable {
        case retried, lastAttempt, ollamaAway, modelMissing, archiveAway, refused, unreadablePayload, changed

        var error: any Error & Sendable {
            switch self {
            case .retried, .lastAttempt: TestFailure("boom")
            case .ollamaAway: OllamaError.unreachable("connection refused")
            case .modelMissing: OllamaError.modelNotFound("not-installed")
            case .archiveAway: FileOperationError.folderMissing("/archive")
            case .refused: IngestError.notTrashed("bill.txt", reason: "the Trash refused it")
            case .unreadablePayload: IngestError.unreadablePayload(0, reason: "garbled")
            case .changed: FileOperationError.sourceChanged("bill.txt")
            }
        }
    }

    /// A job cancelled while it is read, whichever way its reading then fails, is no longer the worker's when the
    /// failure would be saved: nothing of it is saved, its file stays where it is, its trace ends as cancelled, and the
    /// drain records no failure of it (the reviews of the fix of the final review of #17).
    @Test(arguments: Failing.allCases)
    func aJobCancelledWhileReadIsNoFailureHoweverItsReadingFails(_ failing: Failing) async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let jobs = JobStore(database: env.database, time: env.time)
        let analyzer = StubAnalyzer(during: { _ in
            try await jobs.cancelActive(kinds: [.ingest])
            throw failing.error
        })
        let h = Harness(env: env, services: Harness.services(env, analyzer: analyzer, config: env.config))
        let url = try env.drop("bill.txt", text: IngestTests.bill)
        let id = try #require(await h.coordinator.enqueue(url))
        if failing == .lastAttempt, var job = try await jobs.job(id: id) {
            job.attempt = env.config.ingest.maxAttempts - 1
            try await jobs.update(job)
        }
        #expect(await h.coordinator.drain().isEmpty, "\(failing): no failure the drain recorded")
        let job = try await jobs.job(id: id)
        #expect(job?.state == .cancelled && FileManager.default.fileExists(atPath: url.path),
                "\(failing): the job stays cancelled, its file where it was: \(String(describing: job))")
        let ended = try await env.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT outcome FROM traces WHERE job_id = ? ORDER BY id DESC LIMIT 1", arguments: [id])
        }
        #expect(ended == JobOutcome.cancelled.rawValue, "\(failing): its trace ends as cancelled")
        let document = try #require(try await h.services.documents.list(DocumentFilter(), limit: 5).first, "\(failing): its document is there")
        #expect(document.status == .processing, "\(failing): its document is as it was, not marked failed: \(document.status)")
        let said = try await h.services.history.events(limit: 20, kinds: [.failed, .retry, .error]).map(\.summary)
        #expect(said.isEmpty, "\(failing): History records no failure of it: \(said)")
    }

    /// A job whose last attempt is kept, a failure recorded, then is cancelled as its file is set aside: as it is moved
    /// into the archive, or as the archive's folder is found gone, the failure stands, and its trace ends as it was left.
    @Test(arguments: [true, false])
    func aFailureKeptStandsThoughTheJobIsCancelledAsItsFileIsSetAside(_ archiveThere: Bool) async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        var config = env.config
        config.ingest.maxAttempts = 1
        let archive = env.archive
        let analyzer = StubAnalyzer(during: { _ in
            if !archiveThere { try FileManager.default.removeItem(at: archive) }
            throw TestFailure("boom")
        })
        let h = Harness(env: env, services: Harness.services(env, analyzer: analyzer, config: config))
        // The job is cancelled once its failed attempt is kept and its claim checked just before its file is moved: the
        // move is made, or finds the folder gone, and what follows is saved after.
        try await env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TABLE saves (count INTEGER);
                INSERT INTO saves VALUES (0);
                CREATE TEMP TRIGGER cancelled_after_kept AFTER UPDATE ON jobs WHEN NEW.claim IS NOT NULL AND NEW.last_error IS NOT NULL BEGIN
                  UPDATE saves SET count = count + 1;
                  UPDATE jobs SET state = 'cancelled', claim = NULL, claimed_by = NULL
                  WHERE id = NEW.id AND (SELECT count FROM saves) = 2;
                END
                """)
        }
        let id = try #require(await h.coordinator.enqueue(try env.drop("bill.txt", text: IngestTests.bill)))
        #expect(await h.coordinator.drain() == [id], "the failure kept stands as one the drain recorded")
        let ended = try await env.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT outcome FROM traces WHERE job_id = ? ORDER BY id DESC LIMIT 1", arguments: [id])
        }
        // Set aside, it failed; waiting for the archive to be set aside, it waits for nothing of this worker's now.
        let left = archiveThere ? JobOutcome.failed : JobOutcome.cancelled
        #expect(ended == left.rawValue, "and its trace ends as it was left: \(String(describing: ended))")
    }

    /// A document read again whose last attempt fails as the user leaves it for later stays as the user left it: it is
    /// marked failed only while the job is still the worker's, checked just before (the review of the fix of the final
    /// review of #17).
    @Test func aDocumentLeftForLaterAsItsReadingAgainFailsStaysAsTheUserLeftIt() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let filed = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(), config: env.config))
        let document = try await filed.ingest("bill.txt", text: IngestTests.bill)
        let docID = try #require(document.id)
        var config = env.config
        config.ingest.maxAttempts = 1
        let h = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(error: TestFailure("boom")), config: config))
        _ = try await h.services.queueReadingAgain(try #require(document.id), settings: await h.services.settings.current)
        // The user leaves it for later as its failed attempt is kept, as `ReviewActions.hold` does it.
        try await env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER left_for_later AFTER UPDATE OF last_error ON jobs
                WHEN NEW.kind = 'reanalyse' AND NEW.claim IS NOT NULL AND NEW.last_error IS NOT NULL BEGIN
                  UPDATE documents SET status = 'held' WHERE id = NEW.doc_id;
                  UPDATE jobs SET state = 'cancelled', claim = NULL, claimed_by = NULL WHERE id = NEW.id;
                END
                """)
        }
        #expect(await h.coordinator.drain(.everything).isEmpty, "the drain records no failure of a job no longer its")
        #expect(try await h.services.documents.document(id: docID)?.status == .held, "the document stays left for later")
        let failed = try await h.services.history.events(limit: 10, kinds: [.failed])
        #expect(failed.isEmpty, "and History records no failure of it: \(failed.map(\.summary))")
    }

    /// A file that fails before it is a document, as one nobody may read, whose job is cancelled as it would be set aside,
    /// records nothing of its failure: it is checked, with History's record of it, in one write (the review of the fix
    /// of the final review of #17).
    @Test(.fileModesKeepOut) func aFileThatFailsBeforeItIsADocumentRecordsNothingOnceItsJobIsCancelled() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        var config = env.config
        config.ingest.maxAttempts = 1
        let h = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(), config: config))
        let url = try env.drop("locked.txt", text: IngestTests.bill)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        // Cancelled once its failed attempt is kept, before what is left of it is recorded.
        try await env.database.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER cancelled_once_kept AFTER UPDATE OF last_error ON jobs
                WHEN NEW.last_error IS NOT NULL AND NEW.claim IS NOT NULL
                BEGIN UPDATE jobs SET state = 'cancelled', claim = NULL, claimed_by = NULL WHERE id = NEW.id; END
                """)
        }
        let id = try #require(await h.coordinator.enqueue(url))
        #expect(await h.coordinator.drain().isEmpty, "a failure no longer the worker's to record is none it recorded")
        #expect(try await h.services.jobs.job(id: id)?.docId == nil, "the file never became a document")
        let failed = try await h.services.history.events(limit: 10, kinds: [.failed]).map(\.summary)
        #expect(failed.isEmpty, "and History records no failure of it: \(failed)")
    }

    /// A document still being read in, as its file has just come, cannot be left for later: its reading would file it
    /// over the user's choice, which the app never offers; once read, it can (the review of the fix of the final review
    /// of #17).
    @Test func aDocumentBeingReadInIsNotLeftForLaterUntilItIsRead() async throws {
        let holding = Holding()
        let h = try await Harness.make(analyzer: StubAnalyzer(during: { try await holding.read($0) }))
        defer { h.env.cleanup() }
        let read = try #require(try await h.ingest("read.txt", text: "\(IngestTests.bill) read").id)
        await holding.hold("bill.txt")
        let jobID = try #require(await h.coordinator.enqueue(try h.env.drop("bill.txt", text: IngestTests.bill)))
        var worker = Task { await h.coordinator.drain() }
        #expect(await Patience.until { await holding.held == "bill.txt" }, "the file is being read in")
        let docID = try #require(try await h.services.jobs.job(id: jobID)?.docId)
        await #expect(throws: IngestError.beingReadIn(docID, name: "bill.txt"), "it is refused, by its name, while it is read in") {
            try await h.review.hold(docID)
        }
        try await h.review.hold(read)
        #expect(try await h.services.documents.document(id: read)?.status == .held, "another document, read, is left for later meanwhile")
        await holding.letGo()
        _ = await worker.value
        #expect(try await h.services.documents.document(id: docID)?.status == .filed, "the reading files it, as nothing was changed")
        try await h.review.hold(docID)
        #expect(try await h.services.documents.document(id: docID)?.status == .held, "and once read, it is left for later")

        // A file put into the archive by hand is read in where it is, and is refused as long, too.
        let adopted = try h.env.put("Kept/adopted.txt", text: "\(IngestTests.bill) adopted")
        await holding.hold("adopted.txt")
        let adopting = try await h.services.jobs.enqueue(path: adopted.path, kind: .adopt).id
        worker = Task { await h.coordinator.drain() }
        #expect(await Patience.until { await holding.held == "adopted.txt" }, "the file put into the archive is being read in")
        let adoptedID = try #require(try await h.services.jobs.job(id: adopting)?.docId)
        await #expect(throws: IngestError.beingReadIn(adoptedID, name: "adopted.txt"), "it is refused while it is read in") {
            try await h.review.hold(adoptedID)
        }
        await holding.letGo()
        _ = await worker.value
    }

    /// A document whose reading in has not ended, as in the instant between its filing and its job's end, is not undone
    /// nor left for later, nor offered to be: that reading would file it again. Read Again is refused, and not offered,
    /// only where that reading's job is at the document's path, as for a file put into the archive filed where it is,
    /// whose job would take the request and read nothing more; one filed from Incoming is read again beside its reading
    /// in (the reviews of the fix of the final review of #17).
    @Test(arguments: [JobKind.ingest, .adopt])
    func aDocumentWhoseReadingInHasNotEndedIsNotUndoneLeftForLaterNorRemoved(_ kind: JobKind) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let document = try await h.ingest("bill.txt", text: IngestTests.bill)
        let docID = try #require(document.id)
        // Filed, and its job not yet saved as done: as when the app stops in that instant. A file put into the archive
        // is read in at the document's path, where it is filed.
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET state = 'filing', kind = ? WHERE doc_id = ? AND kind = 'ingest'", arguments: [kind.rawValue, docID])
            if kind == .adopt {
                try db.execute(sql: "UPDATE jobs SET source_path = ? WHERE doc_id = ?", arguments: [document.path, docID])
            }
        }
        #expect(try await h.review.choices(for: document).actions == [.confirm], "\(kind): the card offers no undo meanwhile")
        await #expect(throws: IngestError.beingReadIn(docID, name: document.filename), "\(kind): it is refused while its reading has not ended") {
            try await h.review.undo(docID)
        }
        await #expect(throws: IngestError.beingReadIn(docID, name: document.filename), "\(kind): and so is removing it") {
            try await h.review.remove(docID)
        }
        let kept = try await h.services.documents.document(id: docID)
        #expect(kept?.status == .filed && FileManager.default.fileExists(atPath: document.path), "\(kind): and it stays filed where it is")
        // Waiting for the user, its reading in not ended either: not left for later, nor offered to be.
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET status = 'needsReview' WHERE id = ?", arguments: [docID])
        }
        let waiting = try #require(try await h.services.documents.document(id: docID))
        let retried = { try await h.services.history.events(limit: 10, kinds: [.retry]).count }
        if kind == .adopt {
            #expect(try await h.review.choices(for: waiting).actions == [.confirm], "nor reading it again, where its reading in's job is")
            await #expect(throws: IngestError.beingReadIn(docID, name: document.filename), "reading it again is refused meanwhile") {
                try await h.review.retry(docID)
            }
            #expect(try await retried() == 0, "and nothing is said of it")
        } else {
            #expect(try await h.review.choices(for: waiting).actions == [.readAgain, .confirm], "it is offered to be read again")
            try await h.review.retry(docID)
            #expect(try await retried() == 1, "and is read again beside its reading in, which is at the path it came at")
        }
        // And once its job has ended, each is offered again, and reading it again is queued and recorded.
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET state = 'done' WHERE doc_id = ? AND kind = ?", arguments: [docID, kind.rawValue])
        }
        if kind == .adopt {
            #expect(try await h.review.choices(for: waiting).actions == [.hold, .readAgain, .confirm, .remove], "once its reading has ended")
            try await h.review.retry(docID)
            #expect(try await retried() == 1, "and Read Again then reads it again")
        }
    }

    /// A document read again whose last attempt fails, still the worker's, is marked failed with why, and History says
    /// so: it waits for the user (the review of the fix of the final review of #17).
    @Test func aDocumentWhoseReadingAgainFailsItsLastAttemptIsMarkedFailedSayingWhy() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let filed = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(), config: env.config))
        let document = try await filed.ingest("bill.txt", text: IngestTests.bill)
        let docID = try #require(document.id)
        var config = env.config
        config.ingest.maxAttempts = 1
        let h = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(error: TestFailure("boom")), config: config))
        _ = try await h.services.queueReadingAgain(try #require(document.id), settings: await h.services.settings.current)
        _ = await h.coordinator.drain(.everything)
        let failed = try #require(try await h.services.documents.document(id: docID))
        #expect(failed.status == .failed, "it is marked failed: \(failed.status)")
        let analysis = try JSON.decoder.decode(DocumentAnalysis.self, from: Data(try #require(failed.analysisJson).utf8))
        #expect(analysis.problems == ["Processing failed: boom"], "saying why: \(analysis.problems)")
        let said = try await h.services.history.events(limit: 10, kinds: [.failed])
        #expect(said.map(\.docId) == [docID] && said.map(\.summary) == ["bill.txt: boom"], "and History says so: \(said.map(\.summary))")
    }

    /// A document read again for search after a rebuild (`reindex`) whose reading fails is marked failed and waits for
    /// the user, to be read again, as one whose reading fails does; one the user left for later or undid stays so. History says
    /// its reading for search failed (the reviews of the fix of the final review of #17).
    @Test(arguments: [DocumentStatus.filed, .held, .undone])
    func aDocumentWhoseReadingForSearchFailsWaitsForTheUserUnlessSetAside(_ left: DocumentStatus) async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let filed = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(), config: env.config))
        let document = try await filed.ingest("bill.txt", text: IngestTests.bill)
        let docID = try #require(document.id)
        try await filed.services.jobs.enqueue(path: document.path, kind: .reindex, docID: docID, givesWay: true)
        // Set aside once its reading for search is queued: undoing it, its job follows its file into Incoming.
        if left == .held { try await filed.review.hold(docID) }
        if left == .undone { try await filed.review.undo(docID) }
        var config = env.config
        config.ingest.maxAttempts = 1
        let h = Harness(env: env, services: Harness.services(env, analyzer: StubAnalyzer(), extractor: Unreadable(), config: config))
        _ = await h.coordinator.drain(.everything)
        let after = try #require(try await h.services.documents.document(id: docID))
        #expect(after.status == (left == .filed ? .failed : left), "it waits for the user, unless set aside: \(after.status)")
        let said = try await h.services.history.events(limit: 10, kinds: [.failed]).map(\.summary)
        #expect(said == ["bill.txt could not be read again for search: boom"], "and History says its reading for search failed: \(said)")
    }

    /// A file read in whose last attempt fails where it is not moved, as one put into the archive (`adopt`), or one in
    /// Incoming gone meanwhile, is marked failed, to wait for the user (the review of the fix of the final review of #17).
    @Test(arguments: [true, false])
    func aFileReadInWhoseLastAttemptFailsWhereItIsIsMarkedFailed(_ adopted: Bool) async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        var config = env.config
        config.ingest.maxAttempts = 1
        let incoming = env.incoming.appendingPathComponent("gone.txt")
        let analyzer = StubAnalyzer(during: { _ in
            if !adopted { try FileManager.default.removeItem(at: incoming) }
            throw TestFailure("boom")
        })
        let h = Harness(env: env, services: Harness.services(env, analyzer: analyzer, config: config))
        let jobID: Int64
        if adopted {
            jobID = try await h.services.jobs.enqueue(path: try env.put("Kept/adopted.txt", text: IngestTests.bill).path, kind: .adopt).id
        } else {
            jobID = try #require(await h.coordinator.enqueue(try env.drop("gone.txt", text: IngestTests.bill)))
        }
        #expect(await h.coordinator.drain() == [jobID], "its failure is recorded")
        let docID = try #require(try await h.services.jobs.job(id: jobID)?.docId)
        #expect(try await h.services.documents.document(id: docID)?.status == .failed, "and it is marked failed, waiting for the user")
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

/// An extractor that cannot read any file.
private struct Unreadable: ContentExtracting {
    func extract(_ url: URL, sha256: String, context: ExtractionContext, trace: TraceContext) async throws -> ExtractedContent {
        throw TestFailure("boom")
    }
}
