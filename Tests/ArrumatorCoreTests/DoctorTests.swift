import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// `arrumatorcli doctor` and the app's startup check: what they say about an index and a model server.
@Suite struct DoctorTests {
    /// The profile the bundled settings read with.
    private func profile() throws -> ModelProfile { try AppSettings.bundledDefaults().modelProfile() }

    /// The report on an environment whose Ollama double has `installed`, under its settings as `change` leaves them.
    private func report(installed: [String], remoteHosts: [String: String] = [:],
                        settings change: (inout AppSettings) -> Void = { _ in }) async throws -> DoctorReport {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        var settings = await env.settings.current
        change(&settings)
        let mock = MockOllama(installed: installed, remoteHosts: remoteHosts) { _ in "{}" }
        let address = try OllamaEndpoint.validated(settings.ollamaURL)
        let lifecycle = OllamaLifecycle(api: mock, config: env.config.ollama, management: .external, binaryOverride: nil,
                                        address: address, time: env.time)
        return await Doctor(database: env.database, paths: env.paths, appVersion: "test", time: env.time)
            .run(settings: settings, config: env.config, lifecycle: lifecycle, models: ModelManager(api: mock, config: env.config.ollama),
                 ollamaURL: address)
    }

    @Test func aHealthyIndexAndTheProfilesModelsAreReportedHealthy() async throws {
        let profile = try profile()
        let report = try await report(installed: [profile.chatModel, profile.visionModel, profile.embedModel])
        let database = try #require(report.checks.first { $0.name == "Database" })
        #expect(database.status == .ok, "the index of a current schema is healthy, not an error: \(database.detail)")
        #expect(report.checks.first { $0.name == "Ollama running" }?.status == .ok, "the mock server answers")
        #expect(report.models.map(\.role) == [.chat, .vision, .embedding]
                    && report.models.map(\.name) == [profile.chatModel, profile.visionModel, profile.embedModel],
                "the three models of the profile in use are checked, each in its role")
        #expect(report.checks.filter { $0.name.hasPrefix("Model ") }.map(\.status) == [.ok, .ok, .ok], "and each is installed")
    }

    @Test func aModelOfTheProfileThatIsNotInstalledIsAnError() async throws {
        let profile = try profile()
        let report = try await report(installed: [profile.chatModel])
        let embedding = try #require(report.checks.first { $0.name == "Model embedding" })
        #expect(embedding.status == .error && embedding.detail == "\(profile.embedModel) is not installed",
                "without its embedding model nothing is found by meaning, so the check fails and names the model to download")
        #expect(report.hasErrors, "and doctor exits saying a check failed")
    }

    @Test func aModelOfTheProfileThatOllamaRunsElsewhereIsAnErrorSayingWhere() async throws {
        let profile = try profile()
        let host = "https://ollama.com:443"
        let report = try await report(installed: [profile.chatModel, profile.visionModel, profile.embedModel],
                                      remoteHosts: [profile.chatModel: host])
        let chat = try #require(report.checks.first { $0.name == "Model chat" })
        #expect(chat.status == .error && chat.detail.contains(host) && chat.detail.contains(profile.chatModel),
                "a model the server sends elsewhere reads nothing, so the check fails saying where it runs: \(chat.detail)")
        #expect(report.models.first?.remoteHost == host && report.hasErrors, "and the report says so")
    }

    @Test func settingsThatUseNoProfileTheyListAreAnErrorNamingIt() async throws {
        let report = try await report(installed: []) { $0.profile = "lowMemory" }
        let check = try #require(report.checks.first { $0.name == "Model profile" }, "the models it cannot check are reported, not skipped in silence")
        #expect(check.status == .error && check.detail == ModelProfileError.unknown("lowMemory").localizedDescription,
                "the check says which profile is missing: \(check.detail)")
        #expect(report.models.isEmpty, "and no model is reported in its place")
    }
}
