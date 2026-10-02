@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What the search task queue says it is doing (`SearchTaskQueue.statusUpdates()`), which the app shows while a request
/// waits or is read. Taking a task from the queue records nothing in History, which keeps what a reading concluded, so
/// without this status the app would show a task as waiting until its reading ended: minutes later, with a model that
/// thinks.
@Suite struct SearchTaskQueueStatusTests {
    private let suite = SearchTaskTests()

    static let phones = "phone bills"
    static let phonePlan = SearchPlan(title: "Phone bills", labels: [SearchTaskTests.label(.topic, "telecommunications")], words: [],
                                      grouping: [])
    static let plans = [SearchTaskTests.prompt: SearchTaskTests.invoices2025, phones: phonePlan]

    @Test func whileARequestIsReadTheStatusNamesItsTaskAndModelAndCountsTheTasksWaitingBehindIt() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let witness = QueueWitness()
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: Self.plans) { await witness.look(reading: $0) })
        await witness.watch(queue, tasks)
        let first = try await tasks.create(prompt: SearchTaskTests.prompt).id
        let second = try await tasks.create(prompt: Self.phones).id
        let model = try await w.h.env.settings.current.modelProfile().chatModel
        let now = w.h.env.time.now()
        await queue.drain()
        let sights = await witness.sights
        #expect(sights.map(\.status) == [
            SearchTaskQueueStatus(reading: .init(task: first, model: model, since: now), queued: 1, waitingForOllama: false),
            SearchTaskQueueStatus(reading: .init(task: second, model: model, since: now), queued: 0, waitingForOllama: false),
        ], "while a request is read the status names its task, the model reading it and since when, and counts the task waiting behind it")
        #expect(sights.map(\.state) == [.interpreting, .interpreting], "as the task's stored state says it is being read")
        #expect(await queue.status == .idle, "once nothing is left to read, the queue says it is idle")
    }

    @Test func aSubscriberIsSentTheReadingAsItHappensAndOneJoiningLateGetsTheCurrentStatusFirst() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let witness = QueueWitness()
        let follower = StatusFollower()
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: Self.plans) { await witness.look(reading: $0) })
        let updates = await queue.statusUpdates()
        let following = Task { for await status in updates { await follower.add(status) } }
        defer { following.cancel() }
        #expect(await Patience.until { await follower.received == [.idle] }, "a subscriber is sent first the status there is when it subscribes")
        await witness.watch(queue, tasks, follower: follower)
        let id = try await tasks.create(prompt: SearchTaskTests.prompt).id
        let model = try await w.h.env.settings.current.modelProfile().chatModel
        let reading = SearchTaskQueueStatus(reading: .init(task: id, model: model, since: w.h.env.time.now()), queued: 0, waitingForOllama: false)
        await queue.drain()
        let sight = try #require(await witness.sights.first, "the request was read")
        #expect(sight.status == reading && sight.followed == true,
                "a subscriber, as the app is one, is sent that the request is being read while it is, not once it ends")
        #expect(sight.joinedLate == reading, "and one that subscribes while it is read is sent the reading first, not waiting for a change")
        #expect(await Patience.until { await follower.received.last == .idle }, "when the reading ends the subscriber is sent that the queue is idle")
    }

    @Test func whileOllamaCannotBeReachedTheStatusSaysTheQueueWaitsForItUntilAReadingReachesItOrNothingIsLeft() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let ollama = Reachability()
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: Self.plans) { _ in
            if await !ollama.up { throw OllamaError.unreachable("connection refused") }
        })
        let removed = try await tasks.create(prompt: Self.phones).id
        await queue.drain()
        #expect(await queue.status == SearchTaskQueueStatus(reading: nil, queued: 1, waitingForOllama: true),
                "a server that is down is said to be waited for, with the task waiting for it, and nothing is being read")
        #expect(try await suite.task(tasks, removed).state == .queued, "the task waits in the queue")
        try await tasks.delete(removed)
        #expect(await queue.status == .idle, "with nothing left to read the queue waits for nothing, Ollama included")

        let id = try await tasks.create(prompt: SearchTaskTests.prompt).id
        await queue.drain()
        #expect(await queue.status.waitingForOllama, "a task asked while Ollama is away waits for it too")
        await ollama.set(up: true)
        w.h.env.time.advance(by: w.h.env.config.ingest.retryDelays.last)
        await queue.drain()
        #expect(try await suite.task(tasks, id).state == .ready, "once Ollama is back the task is read when it is tried again")
        #expect(await queue.status == .idle, "and the queue no longer says it waits for Ollama")
    }

    @Test func theStatusIsRightAfterTheQueueStopsWhileARequestIsReadAndStartsAgain() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let witness = QueueWitness()
        let held = TestTime(.blocks)
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: Self.plans) { prompt in
            await witness.look(reading: prompt)
            // The first reading goes on until the queue stops, as a model that thinks for minutes may.
            if await witness.sights.count == 1 { try await held.sleep(seconds: 1) }
        })
        await witness.watch(queue, tasks)
        let id = try await tasks.create(prompt: SearchTaskTests.prompt).id
        await queue.start()
        #expect(await Patience.until { await witness.sights.count == 1 }, "the running queue takes the task, and the model reads it")
        #expect(await queue.status.reading?.task == id, "the queue says which task it reads")
        await queue.stop()
        #expect(await queue.status == .idle, "a stopped queue reads nothing and waits for nothing")
        #expect(try await suite.task(tasks, id).state == .interpreting, "the task it was reading is taken up at the next start")
        await queue.start()
        #expect(try await Patience.until {
            let ready = try await tasks.store.task(id: id)?.state == .ready
            let idle = await queue.status == .idle
            return ready && idle
        }, "started again, it reads the task, and is idle once it has")
        await queue.stop()
        #expect(await witness.sights.map(\.status.reading?.task) == [id, id], "while the task is read again the status names it again")
    }

    @Test func whereATaskIsInTheQueueIsWhatTheStatusSaysOfIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let (_, tasks) = h.searchTasks(StubInterpreter(plans: Self.plans))
        let (first, second) = (try await tasks.create(prompt: SearchTaskTests.prompt), try await tasks.create(prompt: Self.phones))
        let reading = SearchTaskQueueStatus.Reading(task: first.id, model: "qwen3.5:9b", since: TestTime.start)
        let readingFirst = SearchTaskQueueStatus(reading: reading, queued: 1, waitingForOllama: false)
        #expect(SearchTaskQueueStatus.idle.progress(of: second) == .waiting, "a task the queue is not busy with waits to be read")
        #expect(readingFirst.progress(of: first) == .reading(reading), "the task the status names is being read, by its model, since then")
        #expect(readingFirst.progress(of: second) == .waitingForTurn, "and another waits while it is read first")
        let ollamaAway = SearchTaskQueueStatus(reading: nil, queued: 2, waitingForOllama: true)
        #expect(ollamaAway.progress(of: second) == .waitingForOllama, "while Ollama cannot be reached a waiting task waits for it")
        let retrying = SearchTaskQueueStatus(reading: reading, queued: 1, waitingForOllama: true)
        #expect(retrying.progress(of: first) == .reading(reading) && retrying.progress(of: second) == .waitingForOllama,
                "trying a task again reads it, and the others still wait for Ollama")
        var elsewhere = second
        elsewhere.state = .interpreting
        #expect(readingFirst.progress(of: elsewhere) == .reading(nil),
                "a task stored as being read that this queue does not name is read elsewhere, as by the command line, by a model it does not know")
        #expect([SearchTaskProgress.reading(reading), .reading(nil)].allSatisfy(\.isReading)
                    && ![SearchTaskProgress.waitingForOllama, .waitingForTurn, .waiting].contains(where: \.isReading),
                "only a request being read, here or elsewhere, is said to be read")
        var done = first
        done.state = .ready
        #expect(readingFirst.progress(of: done) == nil, "a task that is ready is no longer in the queue, whatever a status not yet updated says")
        done.state = .failed
        #expect(readingFirst.progress(of: done) == nil, "nor one that failed")
    }

    @Test func startingTheQueueAgainWhileItReadsARequestLeavesThatRequestBeingRead() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let reading = Signal()
        let (queue, tasks) = h.searchTasks(StubInterpreter(plans: Self.plans) { _ in
            reading.fire()
            try await TestTime(.blocks).sleep(seconds: 1)
        })
        let id = try await tasks.create(prompt: SearchTaskTests.prompt).id
        await queue.start()
        try #require(await Patience.until { reading.fired }, "the queue reads the request")
        await queue.start()
        #expect(try await tasks.store.task(id: id)?.state == .interpreting,
                "a second start does not put back in the queue the request being read, as if it had been stopped")
        #expect(await queue.status.reading?.task == id, "which the queue goes on reading")
        await queue.stop()
    }
}

/// What a test sees of the queue while the interpreter double reads a request (its `during` hook), as the queue exists
/// only once the double does.
actor QueueWitness {
    struct Sight: Sendable {
        var status: SearchTaskQueueStatus
        /// The stored state of the task being read.
        var state: SearchTaskState?
        /// The first status sent to a subscriber that joins while the request is read.
        var joinedLate: SearchTaskQueueStatus?
        /// Whether the follower, when there is one, was sent the status while the request was read.
        var followed: Bool?
    }

    private var queue: SearchTaskQueue?
    private var tasks: SearchTaskActions?
    private var follower: StatusFollower?
    private(set) var sights: [Sight] = []

    func watch(_ queue: SearchTaskQueue, _ tasks: SearchTaskActions, follower: StatusFollower? = nil) {
        self.queue = queue
        self.tasks = tasks
        self.follower = follower
    }

    func look(reading prompt: String) async {
        guard let queue, let tasks else { return }
        let status = await queue.status
        let state = try? await tasks.store.tasks().first { $0.prompt == prompt }?.state
        let joinedLate = await queue.statusUpdates().first { _ in true }
        var followed: Bool?
        if let follower { followed = await Patience.until { await follower.received.last == status } }
        sights.append(Sight(status: status, state: state, joinedLate: joinedLate, followed: followed))
    }
}

/// A subscriber to the queue's status, as the app is one: everything it was sent, in order.
actor StatusFollower {
    private(set) var received: [SearchTaskQueueStatus] = []
    func add(_ status: SearchTaskQueueStatus) { received.append(status) }
}

/// Whether the Ollama the interpreter double stands for can be reached.
actor Reachability {
    private(set) var up = false
    func set(up: Bool) { self.up = up }
}
