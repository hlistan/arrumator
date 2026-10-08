import ArrumatorCore
import Foundation

/// The Ollama server the runtime reads with: which one, and starting it as the settings say.
extension ArrumatorRuntime {
    /// Points the app at the Ollama server at `address` — this Mac or a machine on the local network — from now on,
    /// and remembers it, recorded in History once. An address elsewhere is refused and nothing changes: a `.local` name
    /// too, when it stands for an address beyond the local network now (`OllamaEndpoint.resolved(_:by:within:)`). Whether the
    /// server answers is the caller's to check (`startOllama()`).
    public func useOllama(at address: String) async throws {
        let url = try OllamaEndpoint.validated(address)
        _ = try await OllamaEndpoint.resolved(url, by: resolver, within: config.ollama.timeouts.resolve)
        try ollama.connect(to: url)
        _ = try await settingsActions.change(summary: "Ollama at \(url.absoluteString)") { $0.ollamaURL = url.absoluteString }
        await configureOllama()
        Log.info(.ollama, "Using Ollama", ["url": url.absoluteString])
    }

    /// Checks the Ollama server, and starts it as the settings in force say, applied first: the runtime applies changes only
    /// once its work runs (`begin`), and onboarding asks before, with a Management chosen on that step. A task of the
    /// runtime's, so a stop ends it before it stops the server, and none begins once a stop has (`BackgroundTasks`).
    /// What it found is published (`lifecycle.askings()`).
    public func startOllama() async {
        await tasks.joining("ollama-asked") { [self] in
            await configureOllama()
            await lifecycle.ask()
        }?.value
    }

    /// Has the lifecycle start the server in use, or never start it, as the settings in force say, read and applied in one
    /// step, so settings read earlier never land after those read later (`apply`, `startOllama`, `useOllama`).
    func configureOllama() async {
        do {
            try await ollamaConfiguring.withPermit { [self] in
                let current = await settings.current
                await lifecycle.configure(management: Self.management(for: current, at: ollama.baseURL), binaryOverride: current.ollamaBinaryPath, address: ollama.baseURL)
            }
        } catch {
            // Stopped while it waited its turn: what is in force is applied at the next start.
        }
    }

    /// A server on another machine is the user's to run: the app starts and stops only one on this Mac.
    public static func management(for settings: AppSettings, at url: URL) -> OllamaManagement {
        OllamaEndpoint.isThisMac(url) ? settings.ollamaManagement : .external
    }
}
