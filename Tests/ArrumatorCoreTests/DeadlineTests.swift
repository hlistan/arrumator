import ArrumatorCore
import Foundation
import Testing

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
            try await Deadline.run(180, expired: { OllamaError.timeout("api/chat") }, sleep: { _ in }) {
                do {
                    try await Self.waitForever()
                    return 0
                } catch {
                    await cancelled.raise()
                    throw error
                }
            }
        }
        #expect(await cancelled.raised, "the exchange is cancelled, not left running behind the error")
    }

    @Test func anExchangeWithinItsDeadlineReturnsItsAnswer() async throws {
        let answer = try await Deadline.run(180, expired: { OllamaError.timeout("api/chat") }, sleep: { _ in try await Self.waitForever() }) {
            42
        }
        #expect(answer == 42)
    }

    @Test func noDeadlineLeavesTheExchangeUnbounded() async throws {
        let waited = Flag()
        let answer = try await Deadline.run(0, expired: { OllamaError.timeout("api/pull") }, sleep: { _ in await waited.raise() }) { 7 }
        let slept = await waited.raised
        #expect(answer == 7 && !slept, "a timeout of 0 means none, as the configuration says")
    }
}
