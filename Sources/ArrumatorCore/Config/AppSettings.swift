import Foundation

public enum OllamaManagement: String, Sendable, Codable, CaseIterable {
    case launchApp, spawnServe, external
}

public enum LogLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case error, warning, info, debug, trace
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
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
    /// The id of the model profile the app reads with: one of `modelProfiles`.
    public var profile: String
    /// Every model profile by its id: the bundled ones, as the user changed them, and the user's own.
    public var modelProfiles: [String: ModelProfile]
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
    /// How much the model thinks before it answers a new search task's request, unless it is asked with another effort.
    public var taskEffort: TaskEffort

    public var incomingURL: URL { URL(fileURLWithPath: incomingPath.expandingTilde, isDirectory: true).standardizedFileURL }
    public var archiveURL: URL { URL(fileURLWithPath: archivePath.expandingTilde, isDirectory: true).standardizedFileURL }

    /// The name of the bundled defaults, and of the settings in what refuses them.
    static let configurationName = "settings"

    public static func bundledDefaults() throws -> AppSettings {
        try ConfigLoader.load(AppSettings.self, defaults: configurationName)
    }

    /// The profile `id` names, or the one in use when nil.
    public func modelProfile(_ id: String? = nil) throws -> ModelProfile {
        let id = id ?? profile
        guard let found = modelProfiles[id] else { throw ModelProfileError.unknown(id) }
        return found
    }

    /// The same settings, with the profile in use reading documents and requests with `model`: how `replay --model` and
    /// `eval --model` read with another chat model and leave everything else as it is. A blank model is refused.
    public func reading(withChatModel model: String) throws -> AppSettings {
        var settings = self
        var inUse = try modelProfile()
        inUse.chatModel = model
        settings.modelProfiles[profile] = inUse
        try ConfigLoader.refuse(settings.problems, name: Self.configurationName)
        return settings
    }
}

extension AppSettings: ValidatedConfiguration {
    /// The profile in use is one the settings list, and each profile has a name no other has, whatever its case, and its
    /// three models; nothing in them may be left blank.
    public var problems: [String] {
        var problems: [String] = []
        if modelProfiles[profile] == nil {
            problems.append("profile “\(profile)” is none of modelProfiles (\(modelProfiles.keys.sorted().joined(separator: ", ")))")
        }
        var named: [String: String] = [:]
        for (id, listed) in modelProfiles.sorted(by: { $0.key < $1.key }) {
            let key = "modelProfiles.\(id)"
            let fields = [(ModelProfile.CodingKeys.name, listed.name)] + ModelProfile.roles.map { (ModelProfile.field(of: $0).key, listed.model(for: $0)) }
            for (field, value) in fields where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("\(key).\(field.stringValue) is empty")
            }
            let name = listed.nameKey
            guard !name.isEmpty else { continue }
            if let other = named[name] {
                problems.append("\(key).name “\(listed.name)” is the name of modelProfiles.\(other) already")
            } else {
                named[name] = id
            }
        }
        return problems
    }
}

/// Loads and saves `AppSettings` (only the diff against bundled defaults is written), broadcasting changes. Settings
/// the next launch would refuse (`AppSettings.problems`) are refused before anything is written.
public actor SettingsStore {
    public let url: URL
    private let defaultsValue: JSONValue
    private var cached: AppSettings
    private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]

    public init(paths: AppPaths) throws {
        url = paths.settingsURL
        defaultsValue = try ConfigLoader.bundledValue(AppSettings.configurationName)
        cached = try Self.read(url: paths.settingsURL)
    }

    private static func read(url: URL) throws -> AppSettings {
        let overrides = try ConfigLoader.overrideValue(at: url).map { [$0] } ?? []
        return try ConfigLoader.load(AppSettings.self, defaults: AppSettings.configurationName, overrides: overrides)
    }

    public var current: AppSettings { cached }

    /// Applies `mutate` to the settings in force and saves them; the settings in force after it. A change the user makes
    /// goes through `SettingsActions`, which records it in History.
    @discardableResult
    public func update(_ mutate: @Sendable (inout AppSettings) throws -> Void) throws -> AppSettings {
        try change(mutate).after
    }

    /// Applies `mutate` to the settings in force and saves them when they differ: the settings before and after, read and
    /// written at once, so no other change comes between, and what `mutate` gave back. `mutate` checks the settings it
    /// is given, so what it checks is what it changes; when it throws, the change is refused and nothing is saved.
    public func change<Outcome: Sendable>(_ mutate: @Sendable (inout AppSettings) throws -> Outcome) throws
        -> (before: AppSettings, after: AppSettings, outcome: Outcome) {
        let before = cached
        var after = before
        let outcome = try mutate(&after)
        if after != before { try save(after) }
        return (before, after, outcome)
    }

    public func save(_ settings: AppSettings) throws {
        try ConfigLoader.refuse(settings.problems, name: AppSettings.configurationName)
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
