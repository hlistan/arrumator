import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// How a queue's worker waits for its queue to change (`Doorbell`): a ring ends a wait, a ring while nobody waits is kept
/// for the next, and a wait ends at its timeout or when its task is cancelled; none of these ends a wait that comes
/// after, which still waits for its ring.
///
/// A wait that must not end by itself runs on an executor the test runs by hand (`StepExecutor`): once the test has run
/// every job it has, the wait has done all it does by itself, so whether it ended then is a fact, not a race, and it
/// ends after the ring or not at all. Its timer is on a clock whose sleeps never end.
@Suite struct DoorbellTests {
    /// Expects a wait begun now, with `timeout` on a clock that never gets there, not to end by itself, and to end once
    /// the bell rings, as a worker with nothing due waits for its queue to change.
    private func expectWaitsForTheRing(_ bell: Doorbell, timeout: Double?, _ comment: Comment,
                                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let steps = StepExecutor()
        let ended = Signal()
        let waiting = Task(executorPreference: steps) {
            await bell.wait(timeout: timeout, time: TestTime(.blocks))
            ended.fire()
        }
        steps.runUntilIdle()
        #expect(!ended.fired, comment, sourceLocation: sourceLocation)
        bell.ring()
        steps.runUntilIdle()
        try #require(ended.fired, "a ring ends it", sourceLocation: sourceLocation)
        await waiting.value
    }

    @Test(arguments: [nil, DoorbellTests.retry])
    func aWaitAfterOneThatTimedOutStillWaitsForTheRing(timeout: Double?) async throws {
        let bell = Doorbell()
        let time = TestTime(.advances)
        // Ollama is away: the worker waits for its time to try again, and nothing rings meanwhile.
        await bell.wait(timeout: Self.retry, time: time)
        #expect(time.now() == TestTime.start.addingTimeInterval(Self.retry), "a wait that nothing rings ends at its timeout")
        try await expectWaitsForTheRing(bell, timeout: timeout,
                                        "the next wait does not end by itself: the worker does not read its queue again and again")
    }

    @Test func aWaitWhoseTaskIsCancelledEndsAndTheNextStillWaitsForTheRing() async throws {
        let bell = Doorbell()
        let steps = StepExecutor()
        let ended = Signal()
        let waiting = Task(executorPreference: steps) {
            await bell.wait(timeout: nil, time: TestTime(.blocks))
            ended.fire()
        }
        steps.runUntilIdle()
        #expect(!ended.fired, "the worker waits")
        waiting.cancel()
        steps.runUntilIdle()
        try #require(ended.fired, "stopping the worker ends its wait")
        await waiting.value
        try await expectWaitsForTheRing(bell, timeout: nil, "and a worker started again waits for its ring as before")
    }

    @Test func aRingWhileNobodyWaitsIsKeptForTheNextWaitAsOne() async throws {
        let bell = Doorbell()
        bell.ring()
        bell.ring()
        let steps = StepExecutor()
        let ended = Signal()
        let waiting = Task(executorPreference: steps) {
            await bell.wait(timeout: nil, time: TestTime(.blocks))
            ended.fire()
        }
        steps.runUntilIdle()
        try #require(ended.fired,
                     "a ring while the worker works ends its next wait at once, so it looks at its queue again and misses nothing")
        await waiting.value
        try await expectWaitsForTheRing(bell, timeout: nil, "and two rings meanwhile are kept as one")
    }

    /// How long a worker waits to try Ollama again, in seconds.
    static let retry = 30.0
}

/// Runs the jobs of the tasks that prefer it (`Task(executorPreference:)`, SE-0417) only when a test calls
/// `runUntilIdle()`, on the test's own thread, child tasks' jobs among them. Once it returns, those tasks have gone as far
/// as they can without something from outside them: what they do by themselves is done.
final class StepExecutor: TaskExecutor {
    private let jobs = Mutex<[UnownedJob]>([])

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        jobs.withLock { $0.append(job) }
    }

    /// Runs every job, those the jobs run enqueue included, until none is left.
    func runUntilIdle() {
        while let job = jobs.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}
