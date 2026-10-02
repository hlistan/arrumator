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
    /// What stands in for the Trash, so nothing a test does reaches the user's.
    var trash: FolderTrash { FolderTrash(folder: folder("Trash")) }

    /// An address on this Mac where no Ollama answers: port 9 is the discard service, which nothing serves here.
    static let nowhere = "http://127.0.0.1:9"

    static func make() async throws -> RuntimeHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-runtime-\(UUID().uuidString)",
                                                                               isDirectory: true)
        // Nothing of the process's own environment: the test runs the same however it was started.
        let environment = RuntimeEnvironment(home: root.appendingPathComponent("support").path, ollamaURL: nil,
                                             logLevelName: LogLevel.error.rawValue, pipelineOverridePath: nil, trashPath: nil)
        let home = RuntimeHome(root: root, environment: environment)
        try home.paths.ensureDirectories()
        try await SettingsStore(paths: home.paths).update {
            $0.archivePath = home.folder("First").path
            $0.incomingPath = home.folder("Incoming").path
        }
        return home
    }

    /// Settings under which a started runtime finds no Ollama and starts none: what a test that runs the app's
    /// background machinery (`ArrumatorRuntime.start()`) needs, as no model may be reached from `swift test`.
    func withoutOllama() async throws {
        try await SettingsStore(paths: paths).update {
            $0.ollamaURL = Self.nowhere
            $0.ollamaManagement = .external
        }
    }

    /// What the app and every command do first.
    func open() async throws -> ArrumatorRuntime {
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: environment, echoLogsToStderr: false, trash: trash)
        try await runtime.openArchive()
        return runtime
    }
}
