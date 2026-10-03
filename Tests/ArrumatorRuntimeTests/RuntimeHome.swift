import ArrumatorCore
import ArrumatorRuntime
import Foundation

/// A subscriber to whether a runtime's work runs (`ArrumatorRuntime.workUpdates()`), as the app is one: everything it was
/// sent, in order.
actor WorkFollower {
    private(set) var received: [RuntimeWork] = []
    func add(_ work: RuntimeWork) { received.append(work) }
}

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
        // The archive the user has, set up as onboarding sets it up: the app never makes its folder at a later launch.
        try FileManager.default.createDirectory(at: home.folder("First"), withIntermediateDirectories: true)
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

    /// Everything the history files of the archive in `folder` hold, one after another; empty while it has none.
    func historyWritten(in folder: URL) throws -> String {
        let config = try PipelineConfig.load(paths: paths, environment: environment)
        let history = ArchiveLayout(root: folder, records: config.records, watcher: config.watcher).history
        // No folder yet is nothing written yet.
        let files = (try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)) ?? []
        return try files.sorted { $0.path < $1.path }.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    /// Writes `text` as the list of documents at the top of the archive in `folder`, which it makes if need be: an
    /// archive with records, as one the app has filed into. The list's URL.
    @discardableResult
    func writeList(_ text: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let list = folder.appendingPathComponent(try PipelineConfig.load(paths: paths, environment: environment).records.documentsFileName)
        try text.write(to: list, atomically: true, encoding: .utf8)
        return list
    }

    /// What the app and every command do first.
    func open() async throws -> ArrumatorRuntime {
        let runtime = try await bootstrap()
        try await runtime.openArchive()
        return runtime
    }

    /// A runtime whose archive is not read yet, as the app has one before the user has set it up
    /// (`ArrumatorRuntime.openAndStart()`).
    func bootstrap() async throws -> ArrumatorRuntime {
        try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: environment, echoLogsToStderr: false, trash: trash)
    }

    /// Sets `values` in the section `section` of the home's `pipeline.json`, over the bundled defaults, as a user may.
    func tune(_ section: String, _ values: [String: JSONValue]) throws {
        let current = try ConfigLoader.overrideValue(at: paths.pipelineOverrideURL) ?? .object([:])
        let tuned = ConfigLoader.deepMerge(current, .object([section: .object(values)]))
        try JSON.prettyEncoder.encode(tuned).write(to: paths.pipelineOverrideURL)
    }

    /// The watcher's timings for a test that waits for a file dropped into Incoming to be queued: what the real ones
    /// take seconds over, in a tenth of one.
    func watchQuickly() throws {
        try tune("watcher", ["fsEventsLatency": .number(Self.quickly), "stabilityPollInterval": .number(Self.quickly)])
    }

    static let quickly = 0.1

    /// A stand-in for `ollama serve`: a script that writes its process number into a file and then waits, as a server
    /// does, until it is stopped. Where the script is, and where it writes its number.
    func standInServer() throws -> (executable: URL, processNumber: URL) {
        let executable = root.appendingPathComponent("serve")
        let processNumber = root.appendingPathComponent("serve.pid")
        try Data("#!/bin/sh\necho $$ > '\(processNumber.path)'\nexec /bin/sleep \(Self.standInLifetime)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: Self.executablePermissions], ofItemAtPath: executable.path)
        return (executable, processNumber)
    }

    /// How long the stand-in server lives if nothing stops it: far longer than any test waits for it.
    static let standInLifetime = 300
    static let executablePermissions = 0o755

    /// Makes `folder` read-only, or writable again: nothing can be saved in it, but in the folders inside it, unless
    /// `withFoldersInIt`, as on a disk that can no longer be written to.
    func setWritable(_ writable: Bool, _ folder: URL, withFoldersInIt: Bool) throws {
        let found = withFoldersInIt ? FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])?.allObjects ?? [] : []
        let folders = [folder] + found.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for each in folders {
            try FileManager.default.setAttributes([.posixPermissions: writable ? Self.writableFolder : Self.readOnlyFolder],
                                                  ofItemAtPath: each.path)
        }
    }

    static let writableFolder = 0o755
    static let readOnlyFolder = 0o555
}
