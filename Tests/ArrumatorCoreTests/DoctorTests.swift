@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// `arrumatorcli doctor` and the app's startup check: what they say about an index and a model server.
@Suite struct DoctorTests {
    /// The profile the bundled settings read with.
    private func profile() throws -> ModelProfile { try AppSettings.bundledDefaults().modelProfile() }

    /// The report on an environment whose Ollama double has `installed` (with where it runs each model of `remoteHosts`),
    /// under its settings as `change` leaves them, with the archive's record files that cannot be read.
    /// `listing`, when given, is how the server fails to list its models; `resolver` says what a `.local` name stands for.
    private func report(installed: [String], remoteHosts: [String: String] = [:], unreadable: [UnreadableRecordFile] = [],
                        listing: OllamaError? = nil, resolver: StubResolver = StubResolver(),
                        settings change: (inout AppSettings) -> Void = { _ in },
                        index: (AppDatabase) async throws -> Void = { _ in }) async throws -> DoctorReport {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        try await index(env.database)
        var settings = await env.settings.current
        change(&settings)
        let mock = MockOllama(installed: installed, remoteHosts: remoteHosts) { _ in "{}" }
        if let listing { await mock.failListing(with: listing) }
        let address = try OllamaEndpoint.validated(settings.ollamaURL)
        let lifecycle = OllamaLifecycle(api: mock, config: env.config.ollama, management: .external, binaryOverride: nil,
                                        address: address, time: env.time)
        return await Doctor(database: env.database, archive: env.archive, paths: env.paths, appVersion: "test", time: env.time,
                            resolver: resolver)
            .run(settings: settings, config: env.config, lifecycle: lifecycle, models: ModelManager(api: mock, config: env.config.ollama),
                 ollamaURL: address, unreadableRecords: unreadable)
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
        #expect(report.checks.first { $0.name == "Record files" }?.status == .ok, "and every record file of the archive can be read")
    }

    @Test func eachRecordFileThatCannotBeReadIsAnErrorNamingItAndWhy() async throws {
        let profile = try profile()
        let files = [UnreadableRecordFile(path: "/Archive/System/_labels.md", reason: "not valid YAML at line 4, column 9"),
                     UnreadableRecordFile(path: "/Archive/Kept/_documents.md", reason: "it is not UTF-8 text")]
        let report = try await report(installed: [profile.chatModel, profile.visionModel, profile.embedModel], unreadable: files)
        let checks = report.checks.filter { $0.name == "Record file" }
        #expect(checks.map(\.status) == [.error, .error] && checks.map(\.detail) == files.map { "\($0.path): \($0.reason)" },
                "the user is told which files the app neither reads nor writes, and why, to correct them: \(checks)")
        #expect(report.hasErrors && !report.checks.contains { $0.name == "Record files" }, "and the doctor fails until they read again")
    }

    @Test func anArchiveFolderOtherThanTheOneTheIndexWasKeptForIsAWarning() async throws {
        let profile = try profile()
        let installed = [profile.chatModel, profile.visionModel, profile.embedModel]
        let replaced = try await report(installed: installed, index: { database in
            try await database.setMeta(ArchiveWatcher.folderKey, FolderIdentity(volume: "another volume", place: "inode 1").stored)
        })
        let check = try #require(replaced.checks.first { $0.name == "Archive folder replaced" })
        #expect(check.status == .warning, "the folder at the archive's path is not the one the index was kept for, which the user is told")
        let kept = try await report(installed: installed)
        #expect(!kept.checks.contains { $0.name == "Archive folder replaced" }, "and nothing is said of the folder the index was kept for")
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

    @Test func aServerThatCannotListItsModelsIsAnErrorNotAPass() async throws {
        let failure = OllamaError.http(status: 500, body: "listing failed")
        let report = try await report(installed: [], listing: failure)
        let check = try #require(report.checks.first { $0.name == "Models" }, "the listing that failed is reported, not passed over")
        #expect(check.status == .error && check.detail.contains(failure.localizedDescription),
                "it says what the server answered: \(check.detail)")
        #expect(report.hasErrors, "and doctor exits saying a check failed, as no model of the profile is known to be there")
    }

    /// A server on the local network, by the address the settings save.
    private static let onTheNetwork = "http://ollama-box.local:11434"
    private static let onTheNetworkHost = "ollama-box.local"

    @Test func plainHTTPToAnotherMachineIsAWarning() async throws {
        let report = try await report(installed: [], resolver: StubResolver([Self.onTheNetworkHost: ["192.168.1.20"]])) {
            $0.ollamaURL = Self.onTheNetwork
        }
        let connection = try #require(report.checks.first { $0.name == "Ollama connection" })
        #expect(connection.status == .warning && connection.detail == OllamaEndpoint.Caution.unencrypted(host: Self.onTheNetworkHost).summary,
                "documents cross the network unencrypted, which the user is told, and the server is still used: \(connection.detail)")
        let address = try #require(report.checks.first { $0.name == "Ollama address" })
        #expect(address.status == .ok && address.detail.contains("192.168.1.20"), "the name stands for an address on the local network")
        let onThisMac = try await self.report(installed: [])
        #expect(!onThisMac.checks.contains { $0.name == "Ollama connection" || $0.name == "Ollama address" },
                "a server on this Mac sends nothing across the network")
    }

    @Test func aLocalNameThatStandsForAnAddressBeyondTheLocalNetworkIsAnError() async throws {
        let beyond = try await report(installed: [], resolver: StubResolver([Self.onTheNetworkHost: ["192.168.1.20", "203.0.113.7"]])) {
            $0.ollamaURL = Self.onTheNetwork
        }
        let address = try #require(beyond.checks.first { $0.name == "Ollama address" })
        #expect(address.status == .error && address.detail.contains("203.0.113.7"),
                "a .local name is not trusted by its name when it stands for an address beyond: \(address.detail)")
        let unresolved = try await report(installed: []) { $0.ollamaURL = Self.onTheNetwork }
        let byName = try #require(unresolved.checks.first { $0.name == "Ollama address" })
        #expect(byName.status == .warning && byName.detail.contains("does not resolve"),
                "one that does not resolve now is trusted by its name alone, which the user is told: \(byName.detail)")
    }
}
