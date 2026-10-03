@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The generation lane (`AsyncSemaphore` in `InferenceGate`): one model call at a time, in the order they were asked
/// for. A worker that waits for the lane stops when it is told to, without waiting for whoever holds it, and gives its
/// place to the next.
@Suite struct AsyncSemaphoreTests {
    @Test func aWaitForAPermitAnotherHoldsEndsWhenItsTaskIsCancelledAndItsPlaceGoesToTheNext() async throws {
        let lane = AsyncSemaphore(permits: 1)
        try await lane.acquire()
        let (first, second) = (Ending(), Ending())
        let firstWaits = Task<Void, any Error> {
            do { try await lane.acquire() } catch {
                await first.end()
                throw error
            }
        }
        try #require(await Patience.until { lane.waiting == 1 })
        let secondWaits = Task {
            try await lane.acquire()
            await second.end()
        }
        try #require(await Patience.until { lane.waiting == 2 })

        firstWaits.cancel()
        try #require(await Patience.until { await first.ended == [true] },
                     "a waiter whose task is cancelled stops waiting at once, with no permit, though the permit is still held")
        #expect(lane.waiting == 1, "and leaves the queue")
        lane.release()
        try #require(await Patience.until { await second.ended == [false] }, "the permit goes to the next in line")
        try await secondWaits.value
        await #expect(throws: CancellationError.self, "the waiter that left says it was stopped") { try await firstWaits.value }

        lane.release()
        try await lane.acquire()
        #expect(lane.waiting == 0, "the permit given back is free again, not kept for the waiter that left")
    }

    @Test func aTaskCancelledBeforeItAsksTakesNoPermit() async throws {
        let lane = AsyncSemaphore(permits: 1)
        let asks = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await lane.acquire()
        }
        await #expect(throws: CancellationError.self, "a stopped worker asks for no model call") { try await asks.value }
        let next = Ending()
        let nextAsks = Task {
            try await lane.acquire()
            await next.end()
        }
        #expect(await Patience.until { await next.ended == [false] }, "and the permit is still free for the next")
        nextAsks.cancel()
    }

    @Test func aFileWaitingForTheGenerationLaneStopsAtOnceWhileAnotherQueueHoldsIt() async throws {
        // A model that takes every request for an answer and gives none until the request is cancelled, as one that
        // thinks for minutes.
        let held = MockOllama { _ in "" }
        await held.hold()
        let gate = InferenceGate(api: held, retryDelays: [], time: TestTime(.blocks))
        let ask = OllamaChatRequest.sample(think: nil)
        let reading = Signal()
        let h = try await Harness.make(analyzer: StubAnalyzer(during: { _ in
            reading.fire()
            _ = try await gate.chat(ask)
        }))
        defer { h.env.cleanup() }
        // The search task queue reads a request, holding the lane for as long as the model thinks.
        let holding = Signal()
        let (queue, tasks) = h.searchTasks(StubInterpreter(plans: [:]) { _ in
            holding.fire()
            _ = try await gate.chat(ask)
        })
        _ = try await tasks.create(prompt: Self.request)
        await queue.start()
        try #require(await Patience.until { holding.fired }, "the search task queue reads the request")
        await h.coordinator.enqueue(try h.env.drop(Self.file, text: Self.text))
        await h.coordinator.start()
        try #require(await Patience.until { reading.fired }, "the ingest worker reads the file, which waits for the lane")

        let stopped = Ending()
        let stopping = Task {
            await h.coordinator.stop()
            await stopped.end()
        }
        #expect(await Patience.until { await stopped.ended.count == 1 },
                "the ingest worker stops at once, though the request it waits behind is still being read")
        let job = try #require(try await h.jobs().first)
        #expect(job.state == .analysing && job.attempt == 0 && job.lastError == nil,
                "and its file waits at the stage it was stopped in, no attempt spent and no error: being stopped is no failure")
        await queue.stop()
        await stopping.value
    }

    static let request = "electricity invoices"
    static let file = "bill.txt"
    static let text = "EDP electricity, July"
}
