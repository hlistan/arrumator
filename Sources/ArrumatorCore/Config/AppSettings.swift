import Foundation

public enum OllamaManagement: String, Sendable, Codable, CaseIterable {
    case launchApp, spawnServe, external
}

/// What happens to an exact copy of a document already in the archive.
public enum DuplicateAction: String, Sendable, Codable, CaseIterable {
    /// Filed into the archive beside the original, marked as its copy.
    case fileInArchive
    case leaveInIncoming
}

public enum LogLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case error, warning, info, debug, trace
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// User's model choice: a named profile from `pipeline.json` plus optional per-role overrides.
public struct ModelSelection: Sendable, Codable, Hashable {
    public var profile: String
    public var chatModel: String?
    public var visionModel: String?
    public var embedModel: String?
    public var fastModel: String?
}

/// User preferences. Defaults come from the bundled `Defaults/settings.json`; the user's file stores only changes.
public struct AppSettings: Sendable, Codable, Hashable {
    public var incomingPath: String
    public var archivePath: String
    public var paused: Bool
    /// Show a Dock icon as well as the menu-bar icon. A full menu bar can hide status items, so this is on by default.
    public var showInDock: Bool
    /// Give filed documents the name the model chose; otherwise they keep their own.
    public var renameFiles: Bool
    public var transliterate: Bool
    public var duplicateAction: DuplicateAction
    public var models: ModelSelection
    /// Where Ollama answers: this Mac or a machine on the local network (`OllamaEndpoint`). `ARRUMATOR_OLLAMA_URL`
    /// takes its place while set.
    public var ollamaURL: String
    /// How the app starts Ollama on this Mac; a server on another machine is never started or stopped by the app.
    public var ollamaManagement: OllamaManagement
    public var ollamaBinaryPath: String?
    public var enableVLM: Bool
    public var notifyOnFiled: Bool
    public var notifyOnReview: Bool
    public var pauseOnBattery: Bool
    public var logLevel: LogLevel
    public var traceRawRetentionDays: Int
    public var onboardingCompleted: Bool
    /// List the sidebar's labels under their kinds; otherwise in one list, the most used first.
    public var groupLabelsByKind: Bool
    /// How much computing a new search task's request is read with, unless it is asked with another.
    public var taskEffort: TaskEffort

    public var incomingURL: URL { URL(fileURLWithPath: incomingPath.expandingTilde, isDirectory: true).standardizedFileURL }
    public var archiveURL: URL { URL(fileURLWithPath: archivePath.expandingTilde, isDirectory: true).standardizedFileURL }

    public static func bundledDefaults() throws -> AppSettings {
        try ConfigLoader.load(AppSettings.self, defaults: "settings")
    }
}

/// Loads and saves `AppSettings` (only the diff against bundled defaults is written), broadcasting changes.
public actor SettingsStore {
    public let url: URL
    private let defaultsValue: JSONValue
    private var cached: AppSettings
    private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]

    public init(paths: AppPaths) throws {
        url = paths.settingsURL
        defaultsValue = try ConfigLoader.bundledValue("settings")
        cached = try Self.read(url: paths.settingsURL)
    }

    private static func read(url: URL) throws -> AppSettings {
        let overrides = try ConfigLoader.overrideValue(at: url).map { [$0] } ?? []
        return try ConfigLoader.load(AppSettings.self, defaults: "settings", overrides: overrides)
    }

    public var current: AppSettings { cached }

    @discardableResult
    public func update(_ mutate: @Sendable (inout AppSettings) -> Void) throws -> AppSettings {
        var copy = cached
        mutate(&copy)
        try save(copy)
        return copy
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let value = try JSON.decoder.decode(JSONValue.self, from: JSON.encoder.encode(settings))
        let diff = ConfigLoader.diff(value, from: defaultsValue) ?? .object([:])
        try JSON.prettyEncoder.encode(diff).write(to: url, options: .atomic)
        let changed = settings != cached
        cached = settings
        if changed { for c in continuations.values { c.yield(settings) } }
    }

    public func changes() -> AsyncStream<AppSettings> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AppSettings>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    private func remove(_ id: UUID) { continuations[id] = nil }
}
