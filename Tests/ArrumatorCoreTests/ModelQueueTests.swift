@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// What the queues of search tasks and of questions share (`ModelQueue`): an item in hand is the process's that took
/// it, so one a process that ended left behind is taken up and one another process works on is left to it, and what the
/// work keeps depends on still holding it; the user changing, removing or stopping an item stops the work on it at once;
/// Ollama away makes an item wait, spending nothing, under one trace however often it is tried, and a server that
/// answers with a failure fails it.
@Suite struct ModelQueueTests {
    private let tasksSuite = SearchTaskTests()
    private let talkSuite = ConversationTests()

    /// Waits until the work it runs in is cancelled, as a reading or an answer that takes long; whether it was.
    static func untilStopped() async -> Bool { await Patience.until { Task.isCancelled } }

    private func traces(_ h: Harness, _ source: TraceSource) async throws -> [TraceRecord] {
        try await h.env.database.reader.read { db in
            try TraceRecord.filter(Column("source") == source.rawValue).order(Column("id")).fetchAll(db)
        }
    }

    // MARK: Left in hand

    @Test func aProcessIsKnownByItsIdAndWhenItStarted() throws {
        let processes = try SystemProcesses()
        #expect(processes.isRunning(processes.current), "this process runs")
        let reused = ProcessTag(pid: processes.current.pid, started: processes.current.started + 1)
        #expect(!processes.isRunning(reused), "a process given the same id later is another, so one that ended is never taken for it")
        #expect(ProcessTag(processes.current.description) == processes.current && ProcessTag("12") == nil && ProcessTag("a:1") == nil,
                "a tag reads back as the index keeps it, and text that is none is no tag")
        let launchd = ProcessTag(pid: 1, started: try #require(SystemProcesses.started(1), "launchd runs")).description
        #expect(processes.hasLeft(nil) && processes.hasLeft("none") && processes.hasLeft(processes.current.description)
                    && !processes.hasLeft(launchd),
                "an item no running process holds is left, as is this process's own between items; one launchd holds is not")
    }

    @Test func aTaskACommandWasReadingWhenItWasKilledIsReadByTheNextCommandAndByTheRunningApp() async throws {
        let w = try await tasksSuite.world()
        defer { w.h.env.cleanup() }
        let interpreter = StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025])
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let asked = try await tasks.create(prompt: SearchTaskTests.prompt)
        let command = w.h.processes.start(pid: TestProcesses.otherPID)
        _ = try await tasks.store.begin(asked.id, by: command.description)
        await queue.drain()
        #expect(try await tasksSuite.task(tasks, asked.id).state == .interpreting, "a task a running command reads is left to it")
        w.h.processes.end(command)
        await queue.drain()
        #expect(try await tasksSuite.task(tasks, asked.id).state == .ready, "once the command was killed, the next one reads it")

        // The app runs; a command it does not hear of takes the task to read again, and is killed.
        await queue.start()
        let killed = w.h.processes.start(pid: TestProcesses.otherPID)
        try await w.h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE search_tasks SET state = ?, worker = ? WHERE id = ?",
                           arguments: [SearchTaskState.interpreting.rawValue, killed.description, asked.id])
        }
        w.h.processes.end(killed)
        await queue.wake()
        let read = await Patience.until {
            let readings = await interpreter.calls.prompts.count
            return readings == 2 ? (try? await tasksSuite.task(tasks, asked.id).state) == .ready : false
        }
        await queue.stop()
        #expect(read,
                "a running app reads one a command left once it is told to look, as its maintenance tells it")
    }

    @Test func aQuestionACommandWasAnsweringWhenItWasKilledIsAnsweredByTheNextOne() async throws {
        let w = try await talkSuite.world()
        defer { w.h.env.cleanup() }
        let (queue, talk) = w.h.conversations(StubAnswerer(fallback: ConversationTests.reply), interpreter: StubInterpreter(plans: [:]))
        let asked = try await talk.ask(w.task.id, question: ConversationTests.question)
        let command = w.h.processes.start(pid: TestProcesses.otherPID)
        _ = try await talk.store.begin(asked.id, by: command.description)
        await queue.drain()
        #expect(try await talk.store.turn(id: asked.id)?.state == .answering, "a question a running command answers is left to it")
        w.h.processes.end(command)
        await queue.drain()
        #expect(try await talk.store.turn(id: asked.id)?.answer == ConversationTests.reply.text, "once it was killed, the next one answers it")
    }

    @Test func anItemInHandWhenTheQueueStopsGoesBackIntoTheQueueAtOnce() async throws {
        let w = try await tasksSuite.world()
        defer { w.h.env.cleanup() }
        let reading = Signal()
        let interpreter = StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025]) { _ in
            reading.fire()
            _ = await Self.untilStopped()
            try Task.checkCancellation()
        }
        let (queue, tasks) = w.h.searchTasks(interpreter)
        await queue.start()
        let asked = try await tasks.create(prompt: SearchTaskTests.prompt)
        try #require(await Patience.until { reading.fired }, "the queue reads the task")
        await queue.stop()
        let row = try await w.h.env.database.reader.read { db in try SearchTaskRecord.fetchOne(db, key: asked.id) }
        #expect(row?.state == .queued && row?.worker == nil,
                "the task is back in the queue once the queue has stopped, so the next runtime on the index takes it up, as after an archive switch")
    }

    // MARK: What the work keeps

    @Test func aReadingKeepsNothingOnceAnotherProcessTookTheTaskAfterTheUserChangedIt() async throws {
        let w = try await tasksSuite.world()
        defer { w.h.env.cleanup() }
        let holder = TaskHolder()
        let other = w.h.processes.start(pid: TestProcesses.otherPID).description
        // The app reads the task at low effort; meanwhile a command changes its effort and begins reading it itself.
        let app = StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025]) { _ in
            guard let tasks = await holder.tasks, let id = await holder.id else { return }
            try await Task {
                _ = try await tasks.update(id, SearchTaskChange(effort: .high))
                _ = try await tasks.store.begin(id, by: other)
            }.value
        }
        let (queue, _) = w.h.searchTasks(app)
        let (_, command) = w.h.searchTasks(StubInterpreter(plans: [:]))
        let asked = try await command.create(prompt: SearchTaskTests.prompt, effort: .low)
        await holder.set(command, asked.id)
        await queue.drain()
        let after = try await tasksSuite.task(command, asked.id)
        #expect(after.state == .interpreting && after.plan == nil,
                "the reading at the old effort is not kept, though the prompt is the same: the command reads it now")
        #expect(try await tasksSuite.events(w.h, [.taskPrepared]).isEmpty, "and History says nothing was found")
    }

    // MARK: The user ends the work

    @Test func changingATaskStopsItsReadingAtOnce() async throws {
        let w = try await tasksSuite.world()
        defer { w.h.env.cleanup() }
        let holder = TaskHolder()
        let stopped = Signal()
        let change = ConversationTests.Later<Task<SearchTask, any Error>>()
        let interpreter = StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025]) { prompt in
            guard prompt == SearchTaskTests.prompt, let tasks = await holder.tasks, let id = await holder.id,
                  try await tasks.store.task(id: id)?.effort == .low else { return }
            // The user gives it another effort from the app, in a task of its own, while the model reads.
            let changing = Task { try await tasks.update(id, SearchTaskChange(effort: .high)) }
            change.set(changing)
            if await Self.untilStopped() { stopped.fire() }
        }
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let asked = try await tasks.create(prompt: SearchTaskTests.prompt, effort: .low)
        await holder.set(tasks, asked.id)
        await queue.drain()
        _ = try await change.get().value
        #expect(stopped.fired, "the reading at the old effort is stopped, rather than holding the model until it ends")
        let readings = await interpreter.calls.readings.map(\.effort)
        let state = try await tasksSuite.task(tasks, asked.id).state
        #expect(readings == [.low, .high] && state == .ready,
                "and the task is read again at the new one")
        let first = try #require(try await traces(w.h, .task).first)
        #expect(first.outcome == SearchTaskQueue.superseded, "the trace of the reading stopped says why it ended")
    }

    @Test func removingATaskStopsAnswerToItsQuestion() async throws {
        let w = try await talkSuite.world()
        defer { w.h.env.cleanup() }
        let stopped = Signal()
        let tasks = ConversationTests.Later<SearchTaskActions>()
        let removal = ConversationTests.Later<Task<Void, any Error>>()
        let task = w.task.id
        let answerer = StubAnswerer(fallback: ConversationTests.reply) { _ in
            let removing = Task { try await tasks.get().delete(task) }
            removal.set(removing)
            if await Self.untilStopped() { stopped.fire() }
        }
        let (queue, talk) = w.h.conversations(answerer, interpreter: StubInterpreter(plans: [:]))
        tasks.set(w.h.searchTasks(StubInterpreter(plans: [:]), conversations: queue).actions)
        _ = try await talk.ask(task, question: ConversationTests.question)
        await queue.drain()
        try await removal.get().value
        #expect(stopped.fired, "the answer about a task removed is stopped, rather than holding the model for nothing")
    }

    @Test func aQuestionBeingAnsweredIsStoppedEvenWhenItIsNoLongerInTheIndex() async throws {
        let w = try await talkSuite.world()
        defer { w.h.env.cleanup() }
        let stopped = Signal()
        let asked = ConversationTests.Later<Int64>()
        let actions = ConversationTests.Later<TaskConversationActions>()
        let database = w.h.env.database
        let answerer = StubAnswerer(fallback: ConversationTests.reply) { _ in
            // Another process removed the question, and the user stops it in the app.
            let id = try asked.get()
            try await Task {
                _ = try await database.writer.write { db in try TaskTurnRecord.deleteOne(db, key: id) }
                try await actions.get().stop(id)
            }.value
            if await Self.untilStopped() { stopped.fire() }
        }
        let (queue, talk) = w.h.conversations(answerer, interpreter: StubInterpreter(plans: [:]))
        actions.set(talk)
        asked.set(try await talk.ask(w.task.id, question: ConversationTests.question).id)
        await queue.drain()
        #expect(stopped.fired, "stopping reaches the answer before anything that could fail is asked")
    }

    @Test func aQuestionStoppedWhileItIsTakenFromTheQueueIsStoppedNotAnswered() async throws {
        let w = try await talkSuite.world()
        defer { w.h.env.cleanup() }
        // An index on disk, which another connection can hold, as another process writing to it does.
        let config = w.h.env.config
        let url = w.h.env.root.appendingPathComponent("Indexes/held.sqlite")
        let (database, _) = try AppDatabase.open(at: url, config: config.database, setAsideSuffix: config.records.setAsideSuffix,
                                                 time: TestTime(.advances)) { true }
        try await database.writer.write { db in try AppDatabase.setPendingRebuild(db, nil) }
        var services = w.h.services
        services.database = database
        let answerer = StubAnswerer(fallback: ConversationTests.reply)
        let queue = TaskConversationQueue(services: services, answerer: answerer, interpreter: StubInterpreter(plans: [:]), search: w.h.search,
                                          processes: w.h.processes)
        let tasks = SearchTaskActions(services: services, queue: SearchTaskQueue(services: services, interpreter: StubInterpreter(plans: [:]),
                                                                                 processes: w.h.processes), conversations: queue)
        let talk = TaskConversationActions(services: services, queue: queue)
        let asked = try await talk.ask(try await tasks.create(prompt: SearchTaskTests.prompt).id, question: ConversationTests.question)

        // Another connection holds the index for writing, so taking the question from the queue waits for it.
        let holding = Signal()
        let release = DispatchSemaphore(value: 0)
        let blocker = try DatabaseQueue(path: url.path)
        let held = Thread {
            try? blocker.writeWithoutTransaction { db in
                try db.execute(sql: "BEGIN IMMEDIATE")
                holding.fire()
                release.wait()
                try db.execute(sql: "COMMIT")
            }
        }
        held.start()
        try #require(await Patience.until { holding.fired }, "the other connection holds the index")
        let draining = Task { await queue.drain() }
        // The user stops the question while the queue waits to take it.
        let stopped = await Patience.until { await queue.stop(asked.id) }
        release.signal()
        await draining.value
        #expect(stopped, "the question is in hand from before it is taken, so stopping it then reaches it")
        let after = try #require(try await talk.store.turn(id: asked.id))
        let answered = await answerer.calls.questions
        #expect(after.state == .failed && after.problem == TaskConversationQueue.stoppedProblem && answered.isEmpty,
                "it is stopped, not answered once the index is free")
    }

    @Test func aStoppedAnswerIsTracedAsFarAsItCame() async throws {
        let w = try await talkSuite.world()
        defer { w.h.env.cleanup() }
        let actions = ConversationTests.Later<TaskConversationActions>()
        let stopping = ConversationTests.Later<Int64>()
        let answerer = StubAnswerer(fallback: ConversationTests.reply) { _ in
            try await Task { try await actions.get().stop(try stopping.get()) }.value
        }
        let (queue, talk) = w.h.conversations(answerer, interpreter: StubInterpreter(plans: [:]))
        actions.set(talk)
        let asked = try await talk.ask(w.task.id, question: ConversationTests.question)
        stopping.set(asked.id)
        await queue.drain()
        let id = try #require(try await talk.store.turn(id: asked.id)?.lastTrace, "the stopped answer is traced")
        let (trace, steps) = try #require(try await w.h.services.traces.trace(id: id))
        #expect(trace.outcome == TaskConversationQueue.stopped && steps.map(\.stage) == ["context", "answer"],
                "with the step that says how far the answer came when it was stopped, and how it ended")
    }

    // MARK: Ollama away, and a server that fails

    @Test func anItemThatWaitsForOllamaKeepsOneTraceHoweverOftenItIsTried() async throws {
        let w = try await tasksSuite.world()
        defer { w.h.env.cleanup() }
        let (away, tasks) = w.h.searchTasks(StubInterpreter(plans: [:], error: OllamaError.unreachable("down")))
        let asked = try await tasks.create(prompt: SearchTaskTests.prompt)
        for _ in 0..<3 {
            await away.drain()
            w.h.env.time.advance(by: w.h.env.config.ingest.retryDelays.last)
        }
        var traced = try await traces(w.h, .task)
        #expect(traced.count == 1 && traced.first?.attempt == 2 && traced.first?.outcome == TraceRecorder.waitingOutcome,
                "one trace, taken up by each attempt, which it counts, rather than one more for every 30 s Ollama is away")
        let (back, _) = w.h.searchTasks(StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025]))
        await back.drain()
        traced = try await traces(w.h, .task)
        let kept = try await tasksSuite.task(tasks, asked.id).lastTrace
        #expect(traced.count == 1 && traced.first?.outcome == SearchTaskState.ready.rawValue && kept == traced.first?.id,
                "and the attempt that reads it ends it")
    }

    @Test func aServerThatDoesNotAnswerInTimeIsAwayOnlyWhenItAnswersNoProbeEither() async throws {
        let w = try await tasksSuite.world()
        defer { w.h.env.cleanup() }
        let hung = OllamaError.timeout("chat")
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [:], error: hung))
        let answering = try await tasks.create(prompt: SearchTaskTests.prompt)
        await queue.drain()
        let failed = try await tasksSuite.task(tasks, answering.id)
        #expect(failed.state == .failed && failed.problem == hung.localizedDescription,
                "a server that answers a probe but not the request fails the task, as ingest spends an attempt on it")
        let server = try #require(w.h.services.ollama as? MockOllama)
        await server.failVersion(with: .timeout("version"))
        let hanging = try await tasks.create(prompt: "phone bills")
        await queue.drain()
        let waiting = try await tasksSuite.task(tasks, hanging.id)
        let waitsForOllama = await queue.status.waitingForOllama
        #expect(waiting.state == .queued && waiting.problem == nil && waitsForOllama,
                "one that answers no probe either is away, and the task waits for it, as a document does")
    }

    @Test func aServerThatAnswersWithAFailureFailsTheItemRatherThanKeepingItWaiting() async throws {
        let w = try await tasksSuite.world()
        defer { w.h.env.cleanup() }
        let failing = OllamaError.http(status: 500, body: "runner crashed")
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [:], error: failing))
        let asked = try await tasks.create(prompt: SearchTaskTests.prompt)
        await queue.drain()
        let failed = try await tasksSuite.task(tasks, asked.id)
        #expect(failed.state == .failed && failed.problem == failing.localizedDescription,
                "a server that answers, but with a failure the gate already asked again about, fails the task with the reason")
        #expect(await !queue.status.waitingForOllama, "and nothing waits for Ollama, which answered")

        let w2 = try await talkSuite.world()
        defer { w2.h.env.cleanup() }
        let (answering, talk) = w2.h.conversations(StubAnswerer(error: OllamaError.emptyResponse), interpreter: StubInterpreter(plans: [:]))
        let question = try await talk.ask(w2.task.id, question: ConversationTests.question)
        await answering.drain()
        #expect(try await talk.store.turn(id: question.id)?.state == .failed, "so does a question answered with nothing, every time")
    }
}
