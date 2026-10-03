import ArrumatorCore
@testable import ArrumatorRuntime
import ArrumatorTesting
import Foundation
import Testing

/// Quitting stops the app's work before the process ends (`ArrumatorRuntime.stopBeforeQuitting()`), which the app waits
/// for by answering AppKit's `applicationShouldTerminate(_:)` with `.terminateLater`. A runtime runs once: what stops
/// it is told to stop before anything is waited for, nothing it began starts after it, and nothing starts it again.
@Suite struct QuittingTests {
    @Test func quittingStopsTheRunningAppBeforeItEnds() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        // A bound no stop comes near, on the Mac's own clock: the stop's own end, not the machine's speed, decides.
        try home.tune("ingest", ["quitTimeout": .number(RuntimeHome.longAfterAnyTest)])
        let runtime = try await home.open()
        await runtime.start()
        try await runtime.services.history.record(.paused, summary: "Paused just before quitting")
        // A task of the app's that goes on a while after it is stopped, as the settings being applied when it quits do.
        let (stopped, letGo) = (Signal(), OneShot<Void>())
        await runtime.tasks.run(Self.lingering) {
            await withTaskCancellationHandler { await letGo.wait() } onCancel: { stopped.fire() }
        }
        // Followed from a task of its own, so a stop that never ends fails the test instead of hanging the run.
        let quit = Signal()
        let quitting = Task {
            defer { quit.fire() }
            return await runtime.stopBeforeQuitting()
        }
        try #require(await Patience.until { await runtime.tasks.awaiting == Self.lingering }, "quitting stops the work and waits for it")
        #expect(stopped.fired && !quit.fired, "and does not return, which would let AppKit end the app, while the work still runs")
        letGo.fire(())
        try #require(await Patience.until { quit.fired }, "once the work has stopped, quitting returns")
        #expect(await quitting.value, "saying it stopped before ingest.quitTimeout")
        #expect(try home.historyWritten(in: runtime.archive).contains("Paused just before quitting"),
                "everything stopping does is done when it returns: the archive's history holds what happened last")
        let (ingest, tasks) = (await runtime.coordinator.status, await runtime.taskQueue.status)
        #expect(ingest.current == nil && tasks == .idle, "and nothing is in hand")
    }

    /// How many times the runtime started, as History says: each start records one event.
    private func starts(_ runtime: ArrumatorRuntime) async throws -> Int {
        try await runtime.services.history.events(limit: 10, kinds: [.appStarted]).count
    }

    @Test func aQuitWhileTheArchiveIsReadLeavesNothingStartedThenOrLater() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let runtime = try await home.bootstrap()
        let (reading, stopped, read) = (Signal(), Signal(), OneShot<Void>())
        // The archive is read as macOS reads a folder it holds behind its prompt for access: the read does not notice
        // being stopped, and ends only when it ends.
        let opening = Task {
            try await runtime.openAndStart {
                reading.fire()
                await withTaskCancellationHandler { await read.wait() } onCancel: { stopped.fire() }
            }
        }
        try #require(await Patience.until { reading.fired }, "the app opens the archive")
        let quitting = Task { await runtime.stop() }
        try #require(await Patience.until { stopped.fired }, "quitting stops what opens the archive")
        read.fire(())
        await quitting.value
        await #expect(throws: CancellationError.self, "the step that opens the archive and starts the work says it was stopped") {
            try await opening.value
        }
        #expect(try await starts(runtime) == 0, "and nothing started once the archive was read, after the app had stopped")
        await runtime.start()
        await #expect(throws: CancellationError.self, "a stopped runtime is not opened again") { try await runtime.openAndStart() }
        #expect(try await starts(runtime) == 0, "nor started again: a runtime runs once")
    }

    @Test func aRuntimeStartsOnceHoweverOftenItIsToldTo() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let runtime = try await home.open()
        await runtime.start()
        await runtime.start()
        #expect(try await starts(runtime) == 1, "a second start does nothing more: one worker per queue, one watcher per folder")
        await runtime.stop()
        await runtime.stop()

        let unstarted = try await home.open()
        let startedBefore = try await starts(unstarted)
        await unstarted.stop()
        await unstarted.start()
        #expect(try await starts(unstarted) == startedBefore, "a runtime stopped before it started never starts")
    }

    @Test func stoppingWaitsForEveryTaskItStoppedToEnd() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let runtime = try await home.open()
        await runtime.start()
        // A task that goes on a while after it is stopped, as the settings being applied when the app quits do, which
        // would start a watcher after the app had stopped them.
        let (stopped, letGo) = (Signal(), OneShot<Void>())
        let ended = Ending()
        await runtime.tasks.run(Self.lingering) {
            await withTaskCancellationHandler { await letGo.wait() } onCancel: { stopped.fire() }
            await ended.end()
        }
        let stopping = Task { await runtime.stop() }
        try #require(await Patience.until { stopped.fired }, "stopping stops the task")
        #expect(await Patience.until { await runtime.tasks.awaiting == Self.lingering },
                "stopping waits for the task it stopped to end")
        #expect(await ended.ended.isEmpty, "which has not yet")
        letGo.fire(())
        await stopping.value
        #expect(await ended.ended == [true], "so when stopping returns, every task it stopped has ended")
    }

    static let lingering = "lingering"

    @Test func stoppingTellsEveryQueueToStopBeforeItWaitsForAny() async throws {
        // The search task queue reads a request until it is stopped; the file the ingest worker reads meanwhile cannot be
        // stopped until that request is, as a file that waits for the generation lane the request holds.
        let (holding, requestStopped, waiting) = (Signal(), OneShot<Void>(), Signal())
        let h = try await Harness.make(analyzer: StubAnalyzer(during: { _ in
            waiting.fire()
            await requestStopped.wait()
        }))
        defer { h.env.cleanup() }
        let (queue, tasks) = h.searchTasks(StubInterpreter(plans: [:]) { _ in
            holding.fire()
            try await withTaskCancellationHandler { try await TestTime(.blocks).sleep(seconds: 1) } onCancel: { requestStopped.fire(()) }
        })
        _ = try await tasks.create(prompt: Self.request)
        await queue.start()
        try #require(await Patience.until { holding.fired }, "the search task queue reads the request")
        await h.coordinator.enqueue(try h.env.drop(Self.file, text: Self.text))
        await h.coordinator.start()
        try #require(await Patience.until { waiting.fired }, "the ingest worker reads the file, which waits for the request")
        let conversations = h.conversations(StubAnswerer(), interpreter: StubInterpreter(plans: [:])).queue
        await conversations.start()

        let stopped = Ending()
        let stopping = Task {
            await ArrumatorRuntime.stopTogether(h.coordinator, queue, conversations)
            await stopped.end()
        }
        try #require(await Patience.until { await stopped.ended.count == 1 },
                     "every queue is told to stop before any is waited for, so the file is not waited for while the request runs on")
        await stopping.value
        let waitingJobs = try await h.services.jobs.active()
        #expect(waitingJobs.map(\.state) == [.analysing] && waitingJobs.map(\.attempt) == [0],
                "and the file waits at the stage it was stopped in, no attempt spent: being stopped is no failure")
    }

    static let request = "electricity invoices"
    static let file = "bill.txt"
    static let text = "EDP electricity, July"

    @Test func quittingEndsTheOllamaServerTheAppStartedThoughTheRestOutlastsItsTime() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try home.tune("ingest", ["quitTimeout": .number(Self.shortQuit)])
        let runtime = try await home.bootstrap()
        let server = try home.standInServer()
        await runtime.lifecycle.configure(management: .spawnServe, binaryOverride: server.executable.path, address: runtime.ollama.baseURL)
        let starting = Task { await runtime.lifecycle.ensureRunning() }
        defer { starting.cancel() }
        try #require(await Patience.until { !server.started.isEmpty }, "the app starts the server")
        let process = try #require(server.started.first)
        #expect(StandInServer.runs(process), "which runs")

        // Quit while the archive is read, held as macOS holds a folder behind its prompt for access: the stop cannot end.
        let (reading, read) = (Signal(), OneShot<Void>())
        let opening = Task { try await runtime.openAndStart { reading.fire(); await read.wait() } }
        try #require(await Patience.until { reading.fired }, "the app opens the archive")
        #expect(await !runtime.stopBeforeQuitting(), "the stop outlasts ingest.quitTimeout, and the app quits without waiting longer")
        #expect(await Patience.until { kill(process, 0) != 0 }, "and the server the app started ends all the same, not left running after it")
        read.fire(())
        _ = await opening.result
        await runtime.stop()
    }

    /// An `ingest.quitTimeout` that a stop held by the test outlasts, in seconds.
    static let shortQuit = 0.2
}
