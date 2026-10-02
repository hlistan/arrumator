import ArrumatorCore
import ArrumatorRuntime
import Foundation
import Testing

/// Ollama may run on this Mac or on a machine of the user's own on the local network, never anywhere beyond it.
@Suite struct OllamaServerTests {
    private static let server = "http://192.168.1.239:11434"

    @Test func theServerCanBeAnotherMachineOnTheLocalNetworkButNothingBeyondIt() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let runtime = try await home.open()
        #expect(runtime.ollama.baseURL.absoluteString == "http://127.0.0.1:11434", "this Mac until told otherwise")
        try await runtime.useOllama(at: Self.server)
        #expect(runtime.ollama.baseURL.absoluteString == Self.server, "the app talks to the server the user chose")
        let saved = await runtime.settings.current.ollamaURL
        #expect(saved == Self.server, "and remembered")
        await #expect(throws: OllamaError.self, "a server beyond the local network is refused") {
            try await runtime.useOllama(at: "http://ollama.example.com:11434")
        }
        let kept = await runtime.settings.current.ollamaURL
        #expect(runtime.ollama.baseURL.absoluteString == Self.server && kept == Self.server, "and changes nothing")
        let history = try await runtime.services.history.events(limit: 10, kinds: [.settingsChanged])
        #expect(history.map(\.summary) == ["Ollama at \(Self.server)"], "the change is in History once, and the refused one not at all")
        await runtime.stop()

        let reopened = try await home.open()
        #expect(reopened.ollama.baseURL.absoluteString == Self.server, "the next start uses it")
        await reopened.stop()
        var environment = home.environment
        environment.ollamaURL = "http://127.0.0.1:12345"
        let overridden = try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: environment, echoLogsToStderr: false,
                                                              trash: home.trash)
        #expect(overridden.ollama.baseURL.absoluteString == "http://127.0.0.1:12345", "ARRUMATOR_OLLAMA_URL takes its place while set")
    }

    @Test func theAppStartsOllamaOnlyOnThisMac() throws {
        var settings = try AppSettings.bundledDefaults()
        settings.ollamaManagement = .launchApp
        let local = try OllamaEndpoint.validated("http://127.0.0.1:11434")
        let remote = try OllamaEndpoint.validated(Self.server)
        #expect(ArrumatorRuntime.management(for: settings, at: local) == .launchApp, "on this Mac, Ollama is started as the user chose")
        #expect(ArrumatorRuntime.management(for: settings, at: remote) == .external,
                "a server on another machine is the user's to start and stop")
    }
}
