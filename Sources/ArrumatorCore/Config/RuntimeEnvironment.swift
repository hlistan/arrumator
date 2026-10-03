import CryptoKit
import Foundation

/// Process-level overrides read from environment variables.
public struct RuntimeEnvironment: Sendable {
    /// Relocates all app state (indexes, settings, logs). Used by tests and smoke runs.
    public var home: String?
    /// Overrides the Ollama endpoint; like the setting, it must pass `OllamaEndpoint.validated` (this Mac or the local network).
    public var ollamaURL: String?
    /// `ARRUMATOR_LOG_LEVEL` as written; `logLevel()` reads it.
    public var logLevelName: String?
    /// Extra pipeline override JSON file merged after the user's `pipeline.json`.
    public var pipelineOverridePath: String?
    /// A folder the app uses as the Trash, as a run in a scratch home must, so a file it has no more use for never
    /// reaches the user's Trash (AGENTS.md §4.3).
    public var trashPath: String?

    public init(home: String?, ollamaURL: String?, logLevelName: String?, pipelineOverridePath: String?, trashPath: String?) {
        self.home = home
        self.ollamaURL = ollamaURL
        self.logLevelName = logLevelName
        self.pipelineOverridePath = pipelineOverridePath
        self.trashPath = trashPath
    }

    /// The variable that names the Ollama server, which Settings names when it is set.
    public static let ollamaURLVariable = "ARRUMATOR_OLLAMA_URL"

    public static var current: RuntimeEnvironment {
        let env = ProcessInfo.processInfo.environment
        return RuntimeEnvironment(
            home: env["ARRUMATOR_HOME"].flatMap { $0.isEmpty ? nil : $0.expandingTilde },
            ollamaURL: env[ollamaURLVariable].flatMap { $0.isEmpty ? nil : $0 },
            logLevelName: env["ARRUMATOR_LOG_LEVEL"].flatMap { $0.isEmpty ? nil : $0 },
            pipelineOverridePath: env["ARRUMATOR_PIPELINE_CONFIG"].flatMap { $0.isEmpty ? nil : $0.expandingTilde },
            trashPath: env["ARRUMATOR_TRASH"].flatMap { $0.isEmpty ? nil : $0.expandingTilde })
    }

    /// Where a file the app has no more use for goes: the folder `ARRUMATOR_TRASH` names, else `userTrash`, which only the
    /// app and `arrumatorcli` give as the user's Trash (trash gate in `scripts/lint.sh`).
    public func trash(orElse userTrash: @autoclosure () -> any Trashing) -> any Trashing {
        trashPath.map { FolderTrash(folder: URL(fileURLWithPath: $0, isDirectory: true)) } ?? userTrash()
    }

    /// The level `ARRUMATOR_LOG_LEVEL` sets, nil when it is not set. A value that is no level stops the app with the
    /// reason, rather than being ignored while the user waits for the detail they asked for.
    public func logLevel() throws -> LogLevel? {
        guard let logLevelName else { return nil }
        guard let level = LogLevel(rawValue: logLevelName) else {
            throw ConfigError.invalid(name: "ARRUMATOR_LOG_LEVEL", underlying: "“\(logLevelName)” is none of "
                                          + LogLevel.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return level
    }
}

extension URL {
    /// The folder's path as the file system knows it: symbolic links resolved, `/private` kept and letters in the case
    /// they have on disk, so two spellings of one folder compare equal. Nil when the folder does not exist. The
    /// canonical path alone keeps a link in the last component, so links are resolved first.
    public var canonicalFolderPath: String? {
        try? resolvingSymlinksInPath().resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
    }

    /// `canonicalFolderPath` of the folder, or, when it is not there, of where it would be: the canonical path of the
    /// nearest folder above it that is there, with the rest as given. The same as the folder's own once it is made.
    public var canonicalPlacePath: String {
        let (base, rest) = canonicalPlaceParts
        return rest.reduce(URL(fileURLWithPath: base, isDirectory: true)) { $0.appendingPathComponent($1, isDirectory: true) }.path
    }

    /// The folder spelled as the file system spells it, as `canonicalPlacePath` finds it, and standardized as every path
    /// the app keeps is (`/var` for `/private/var`), whether it is there yet or not.
    public var canonicalPlace: URL {
        let (base, rest) = canonicalPlaceParts
        return rest.reduce(URL(fileURLWithPath: base, isDirectory: true).standardizedFileURL) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// The canonical path of the nearest folder of this URL, or above it, that is there, and the names below it.
    private var canonicalPlaceParts: (base: String, rest: [String]) {
        var place = standardizedFileURL
        var rest: [String] = []
        while place.canonicalFolderPath == nil, place.path != "/" {
            rest.insert(place.lastPathComponent, at: 0)
            place = place.deletingLastPathComponent()
        }
        return (place.canonicalFolderPath ?? place.path, rest)
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

    public static func resolve(_ env: RuntimeEnvironment) -> AppPaths {
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

    /// Every archive has an index of its own, so switching archives never mixes the documents, labels or history of one
    /// with another (docs/storage.md). It is named after the canonical path of the archive's folder, or of where it
    /// would be when it is not there (`canonicalPlacePath`): two spellings of one folder, such as `/tmp` and
    /// `/private/tmp` or another case, name one index, and an archive whose folder is away, as on a disk not connected,
    /// still names its own.
    public func indexURL(for archive: URL) -> URL {
        let digest = SHA256.hash(data: Data(archive.canonicalPlacePath.utf8)).prefix(Self.indexNameBytes)
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
    /// that archive has an index already. Returns whether it moved. Its write-ahead log is written into it first: the
    /// files are moved one at a time, and a stop between two would otherwise leave its last changes behind.
    @discardableResult
    public func moveSingleIndex(to index: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: singleIndexURL.path), !fm.fileExists(atPath: index.path) else { return false }
        try fm.createDirectory(at: indexesDirectory, withIntermediateDirectories: true)
        try AppDatabase.checkpoint(singleIndexURL)
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
