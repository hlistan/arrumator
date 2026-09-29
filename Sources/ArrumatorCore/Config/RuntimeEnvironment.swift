import CryptoKit
import Foundation

/// Process-level overrides read from environment variables.
public struct RuntimeEnvironment: Sendable {
    /// Relocates all app state (indexes, settings, logs). Used by tests and smoke runs.
    public var home: String?
    /// Overrides the Ollama endpoint; like the setting, it must pass `OllamaEndpoint.validated` (this Mac or the local network).
    public var ollamaURL: String?
    public var logLevel: LogLevel?
    /// Extra pipeline override JSON file merged after the user's `pipeline.json`.
    public var pipelineOverridePath: String?
    /// Enables tests and evals that talk to a live Ollama.
    public var live: Bool

    public static var current: RuntimeEnvironment {
        let env = ProcessInfo.processInfo.environment
        return RuntimeEnvironment(
            home: env["ARRUMATOR_HOME"].flatMap { $0.isEmpty ? nil : $0.expandingTilde },
            ollamaURL: env["ARRUMATOR_OLLAMA_URL"].flatMap { $0.isEmpty ? nil : $0 },
            logLevel: env["ARRUMATOR_LOG_LEVEL"].flatMap(LogLevel.init(rawValue:)),
            pipelineOverridePath: env["ARRUMATOR_PIPELINE_CONFIG"].flatMap { $0.isEmpty ? nil : $0.expandingTilde },
            live: env["ARRUMATOR_LIVE"] == "1")
    }
}

extension URL {
    /// The folder's path as the file system knows it: symbolic links resolved, `/private` kept and letters in the case
    /// they have on disk, so two spellings of one folder compare equal. Nil when the folder does not exist. The
    /// canonical path alone keeps a link in the last component, so links are resolved first.
    public var canonicalFolderPath: String? {
        try? resolvingSymlinksInPath().resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
    }
}

/// Filesystem locations of app state.
public struct AppPaths: Sendable {
    public let supportDirectory: URL
    public let logsDirectory: URL

    public init(supportDirectory: URL, logsDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.logsDirectory = logsDirectory
    }

    public static func resolve(_ env: RuntimeEnvironment = .current) -> AppPaths {
        if let home = env.home {
            let base = URL(fileURLWithPath: home, isDirectory: true)
            return AppPaths(supportDirectory: base, logsDirectory: base.appendingPathComponent("Logs", isDirectory: true))
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arrumator", isDirectory: true)
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Arrumator", isDirectory: true)
        return AppPaths(supportDirectory: support, logsDirectory: logs)
    }

    /// Every archive has an index of its own, so switching archives never mixes the folders, logic or learned state of
    /// one with another (docs/storage.md). It is named after the canonical path of the archive's folder, which must
    /// exist: two spellings of one folder, such as `/tmp` and `/private/tmp` or another case, name one index.
    public func indexURL(for archive: URL) throws -> URL {
        guard let path = archive.canonicalFolderPath else { throw ConfigError.archiveFolderMissing(archive.path) }
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(Self.indexNameBytes)
        return indexesDirectory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + "." + Self.indexExtension)
    }

    public var indexesDirectory: URL { supportDirectory.appendingPathComponent("Indexes", isDirectory: true) }

    /// Bytes of the path's SHA-256 that name an index: collisions are out of reach, and the name stays short.
    static let indexNameBytes = 8
    static let indexExtension = "sqlite"

    /// Before each archive had an index, this one database indexed whichever archive the settings named. It becomes
    /// that archive's index, once, so nothing it held is lost; afterwards it no longer exists.
    var singleIndexURL: URL { supportDirectory.appendingPathComponent("arrumator.sqlite") }

    /// Moves the one database of earlier versions into place as the index of the archive the settings name, unless
    /// that archive has an index already. Returns whether it moved.
    @discardableResult
    public func moveSingleIndex(to index: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: singleIndexURL.path), !fm.fileExists(atPath: index.path) else { return false }
        try fm.createDirectory(at: indexesDirectory, withIntermediateDirectories: true)
        for suffix in [""] + AppDatabase.companionSuffixes where fm.fileExists(atPath: singleIndexURL.path + suffix) {
            try fm.moveItem(atPath: singleIndexURL.path + suffix, toPath: index.path + suffix)
        }
        Log.info(.db, "The index became the archive's own", ["index": index.path])
        return true
    }

    public var settingsURL: URL { supportDirectory.appendingPathComponent("settings.json") }
    public var pipelineOverrideURL: URL { supportDirectory.appendingPathComponent("pipeline.json") }
    public var diagnosticsDirectory: URL { supportDirectory.appendingPathComponent("Diagnostics", isDirectory: true) }

    public func ensureDirectories() throws {
        for dir in [supportDirectory, logsDirectory, diagnosticsDirectory] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
