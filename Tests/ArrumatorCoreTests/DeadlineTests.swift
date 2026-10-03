import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// `Deadline` bounds an exchange with Ollama or an extractor by its total time, on time a test controls: a deadline
/// that `advances` expires at once, and one that `blocks` never does.
@Suite struct DeadlineTests {
    /// Waits until cancelled, like a request whose reply never arrives on an open connection.
    private static func waitForever() async throws {
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        defer { continuation.finish() }
        for await _ in stream {}
        throw CancellationError()
    }

    private actor Flag {
        private(set) var raised = false
        func raise() { raised = true }
    }

    @Test func anExchangeThatNeverCompletesEndsAtItsDeadline() async throws {
        let cancelled = Flag()
        await #expect(throws: OllamaError.timeout("api/chat"), "a reply lost on the network must not hold the queue forever") {
            try await Deadline.run(180, time: TestTime(.advances), expired: { OllamaError.timeout("api/chat") }) {
                do {
                    try await Self.waitForever()
                    return 0
                } catch {
                    await cancelled.raise()
                    throw error
                }
            }
        }
        // The abandoned operation is cancelled without being waited for; it notices on its own task.
        #expect(await Patience.until { await cancelled.raised }, "the exchange is cancelled, not left running behind the error")
    }

    @Test func anExchangeWithinItsDeadlineReturnsItsAnswer() async throws {
        let answer = try await Deadline.run(180, time: TestTime(.blocks), expired: { OllamaError.timeout("api/chat") }) { 42 }
        #expect(answer == 42, "an answer that arrives before the deadline is the answer")
    }

    @Test func workThatIgnoresCancellationDoesNotHoldTheCallerPastTheDeadline() async throws {
        let release = OneShot<Void>()
        await #expect(throws: DeadlineExceeded(seconds: 5), "a PDFKit or Vision call that never checks for cancellation is let go") {
            try await Deadline.run(5, time: TestTime(.advances), expired: { DeadlineExceeded(seconds: 5) }) {
                await release.wait()
                return 0
            }
        }
        release.fire(())
    }

    @Test func noDeadlineLeavesTheExchangeUnbounded() async throws {
        let time = TestTime(.advances)
        let answer = try await Deadline.run(0, time: time, expired: { OllamaError.timeout("api/pull") }) { 7 }
        #expect(answer == 7 && time.now() == TestTime.start, "a timeout of 0 means none, as the configuration says: nothing waited")
    }
}
