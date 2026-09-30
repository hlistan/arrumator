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
        // Nothing of the process's own environment: the test runs the same however it was started.
        let environment = RuntimeEnvironment(home: root.appendingPathComponent("support").path, ollamaURL: nil,
                                             logLevelName: LogLevel.error.rawValue, pipelineOverridePath: nil)
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
