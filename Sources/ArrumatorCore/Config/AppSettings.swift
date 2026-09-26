import Foundation

public enum OllamaManagement: String, Sendable, Codable, CaseIterable {
    case launchApp, spawnServe, external
}

public enum LowConfidenceAction: String, Sendable, Codable, CaseIterable {
    case holdForReview, fileAndFlag
}

public enum DuplicateAction: String, Sendable, Codable, CaseIterable {
    case moveToDuplicates, leaveInIncoming
}

public enum InducedRulePolicy: String, Sendable, Codable, CaseIterable {
    case autoEnableAndNotify, proposeOnly
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
    /// Give filed documents the name the model chose, following the logic; otherwise they keep their own.
    public var renameFiles: Bool
    public var transliterate: Bool
    public var lowConfidenceAction: LowConfidenceAction
    public var duplicateAction: DuplicateAction
    /// Create folders the model proposes when its decision is confident; otherwise hold them for review.
    public var autoCreateFolders: Bool
    /// Language of folder names and descriptions the model writes.
    public var folderNamingLanguage: String
    public var inducedRulePolicy: InducedRulePolicy
    public var thresholds: Thresholds
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

    /// Re-reads the file (e.g. after the CLI changed it).
    @discardableResult
    public func reload() throws -> AppSettings {
        let fresh = try Self.read(url: url)
        if fresh != cached {
            cached = fresh
            for c in continuations.values { c.yield(fresh) }
        }
        return cached
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
