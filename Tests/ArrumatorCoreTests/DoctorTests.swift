import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// `arrumatorcli doctor` and the app's startup check: what they say about an index and a model server.
@Suite struct DoctorTests {
    @Test func aHealthyIndexIsReportedHealthy() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        let settings = await env.settings.current
        let models = try env.config.models(for: settings.models)
        let mock = MockOllama(installed: [models.chat, models.embed]) { _ in "{}" }
        let address = try OllamaEndpoint.validated(settings.ollamaURL)
        let lifecycle = OllamaLifecycle(api: mock, config: env.config.ollama, management: .external, binaryOverride: nil,
                                        address: address, time: env.time)
        let report = await Doctor(database: env.database, paths: env.paths, appVersion: "test", time: env.time)
            .run(settings: settings, config: env.config, lifecycle: lifecycle, models: ModelManager(api: mock, config: env.config.ollama),
                 ollamaURL: address)
        let database = try #require(report.checks.first { $0.name == "Database" })
        #expect(database.status == .ok, "the index of a current schema is healthy, not an error: \(database.detail)")
        #expect(report.checks.first { $0.name == "Ollama running" }?.status == .ok, "the mock server answers")
    }
}
