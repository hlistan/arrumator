import ArrumatorCore
import ArrumatorRuntime
import Foundation

/// A scratch app home whose settings name scratch folders, never the user's archive or Incoming.
struct RuntimeHome {
    let root: URL
    let environment: RuntimeEnvironment

    var paths: AppPaths { AppPaths.resolve(environment) }
    func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true).standardizedFileURL }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    static func make() async throws -> RuntimeHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-runtime-\(UUID().uuidString)",
                                                                               isDirectory: true)
        var environment = RuntimeEnvironment.current
        environment.home = root.appendingPathComponent("support").path
        environment.ollamaURL = nil
        environment.pipelineOverridePath = nil
        environment.logLevel = .error
        let home = RuntimeHome(root: root, environment: environment)
        try home.paths.ensureDirectories()
        try await SettingsStore(paths: home.paths).update {
            $0.archivePath = home.folder("First").path
            $0.incomingPath = home.folder("Incoming").path
        }
        return home
    }

    /// What the app and every command do first.
    func open() async throws -> ArrumatorRuntime {
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: environment, echoLogsToStderr: false)
        try await runtime.openArchive()
        return runtime
    }
}
