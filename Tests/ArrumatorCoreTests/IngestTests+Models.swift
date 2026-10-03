import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// A file whose model is not installed waits for it.
extension IngestTests {
    @Test func aFileWhoseModelIsMissingWaitsForItAtItsStageAndIsFiledOnceItIsInstalled() async throws {
        let model = "ministral-3:14b"
        let server = MockOllama { _ in "" }
        let installed = Signal()
        let analyzer = StubAnalyzer(during: { _ in if !installed.fired { throw OllamaError.modelNotFound(model) } })
        let env = try await TestEnvironment.make()
        let h = Harness(env: env, services: Harness.services(env, analyzer: analyzer, ollama: server, config: env.config))
        defer { h.env.cleanup() }
        let id = try #require(await h.coordinator.enqueue(try h.env.drop("bill.txt", text: Self.bill)))
        await h.coordinator.drain()
        let recheck = h.env.config.ingest.modelRecheckSeconds
        let waiting = try #require(try await h.services.jobs.job(id: id))
        #expect(waiting.state == .analysing && waiting.state.isActive && waiting.attempt == 0,
                "the job waits in the queue at the stage that needs the model, spending no attempt: \(waiting.state)")
        #expect(waiting.lastError == "\(model) is not installed in Ollama: download it in Settings › Models, or with arrumatorcli models pull \(model)"
                    && waiting.nextRunAt == h.env.time.now().addingTimeInterval(recheck),
                "the queue says what to do, naming the model, and it looks again after ingest.modelRecheckSeconds: \(waiting.lastError ?? "")")

        let traces = { try await h.env.database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM traces") } }
        let tracedBefore = try await traces()
        h.env.time.advance(by: recheck)
        await h.coordinator.drain()
        let said = try await h.services.history.events(limit: 10, kinds: [.error]).count
        #expect(said == 1, "still missing, History has said so once")
        let read = await analyzer.calls.files.count
        #expect(try await traces() == tracedBefore && read == 1,
                "and looking again whether it is installed reads nothing and leaves no trace")
        let still = try #require(try await h.services.jobs.job(id: id))
        #expect(still.nextRunAt == h.env.time.now().addingTimeInterval(recheck), "it looks again after another while")

        installed.fire()
        await server.install(model)
        h.env.time.advance(by: recheck)
        await h.coordinator.drain()
        let filed = try #require(try await h.services.jobs.job(id: id))
        #expect(filed.state == .done, "once the model is installed, the file is read and filed, with no new job for it")
        #expect(try await h.jobs().count == 1, "the one job the file had")
    }
}
