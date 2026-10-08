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
    /// The `ollama` program the app starts (`spawnServe`), when it is not where Ollama installs it
    /// (`ollama.binarySearchPaths`); nil looks for it there.
    public var ollamaBinaryPath: String?
    /// Describe images with the vision model of the profile in use, so a picture with little text is read by what it
    /// shows; otherwise an image is read by its text alone.
    public var enableVLM: Bool
    public var notifyOnFiled: Bool
    public var notifyOnReview: Bool
    public var pauseOnBattery: Bool
    public var logLevel: LogLevel
    /// Days the prompts and raw answers of a reading are kept in its trace (`traceRawRetentionDaysRange`).
    public var traceRawRetentionDays: Int
    public var onboardingCompleted: Bool
    /// List the sidebar's labels under their kinds; otherwise in one list, the most used first.
    public var groupLabelsByKind: Bool
    /// How much the model thinks before it answers a new search task's request, unless it is asked with another effort.
    public var taskEffort: TaskEffort

    /// Its keys in `settings.json`, which the checks of the settings and History name.
    enum CodingKeys: String, CodingKey {
        case incomingPath, archivePath, paused, showInDock, renameFiles, transliterate, profile, modelProfiles, ollamaURL,
             ollamaManagement, ollamaBinaryPath, enableVLM, notifyOnFiled, notifyOnReview, pauseOnBattery, logLevel,
             traceRawRetentionDays, onboardingCompleted, groupLabelsByKind, taskEffort
    }

    public var incomingURL: URL { URL(fileURLWithPath: incomingPath.expandingTilde, isDirectory: true).standardizedFileURL }
    public var archiveURL: URL { URL(fileURLWithPath: archivePath.expandingTilde, isDirectory: true).standardizedFileURL }

    /// The days a reading's prompts and raw answers may be kept, which Settings in the app offers: at least a day, as
    /// fewer would clear them from a reading still being looked at, and at most ten years.
    public static let traceRawRetentionDaysRange = 1...3_650

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

    /// Reads with the profile `id` names from now on, as the user wrote it, on one line; the profile. One the settings do
    /// not list is refused.
    @discardableResult
    public mutating func use(profile id: String) throws -> ModelProfile {
        let id = DocumentLabel.oneLine(id)
        let chosen = try modelProfile(id)
        profile = id
        return chosen
    }

    /// The same settings, with the profile in use reading documents and requests, and describing images, with `model`, as
    /// each profile the app comes with reads and describes with one model: how `replay --model` and `eval --model` read
    /// with another model and leave everything else as it is, the embedding model among it. A blank model is refused.
    public func reading(withModel model: String) throws -> AppSettings {
        var settings = self
        var inUse = try modelProfile()
        inUse.chatModel = model
        inUse.visionModel = model
        settings.modelProfiles[profile] = inUse
        try ConfigLoader.refuse(settings.problems, name: Self.configurationName)
        return settings
    }
}

extension AppSettings: ValidatedConfiguration {
    /// Incoming and the archive are two folders, neither inside the other (`folderProblems`). The profile in use is one
    /// the settings list, and each profile has a name no other has, whatever its case, and its three models; nothing in
    /// them may be left blank. Prompts are kept for days `traceRawRetentionDaysRange` allows, and Ollama's program, when
    /// given, is named by a full path.
    public var problems: [String] {
        var problems = folderProblems
        if !Self.traceRawRetentionDaysRange.contains(traceRawRetentionDays) {
            problems.append("\(CodingKeys.traceRawRetentionDays.stringValue) must be from \(Self.traceRawRetentionDaysRange.lowerBound) "
                + "to \(Self.traceRawRetentionDaysRange.upperBound) days")
        }
        if let ollamaBinaryPath, !Self.isFullPath(ollamaBinaryPath) {
            problems.append("\(CodingKeys.ollamaBinaryPath.stringValue) “\(ollamaBinaryPath)” is not a full path, from / or ~; "
                + "leave it out to look for Ollama where it is installed")
        }
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

    /// Incoming and the archive, each named by a full path, are two folders, neither inside the other: an archive inside
    /// Incoming, or Incoming itself, would have every document filed taken in and filed again, and Incoming inside the
    /// archive would have what waits there taken for the archive's documents. They are compared as the file system spells
    /// them as far as they exist (`URL.canonicalPlacePath`), so a link or another case of a folder is that folder,
    /// and whatever the case of their letters: a Mac's volumes tell no case apart unless formatted to, and a folder not
    /// made yet has no case on disk to go by. Every way the folders are set (Settings, `arrumatorcli settings` and
    /// `archive switch`, `settings.json` written by hand) meets this one rule, as `SettingsStore` refuses to load or save
    /// settings that break it.
    private var folderProblems: [String] {
        let partial = Self.partialPaths([(CodingKeys.incomingPath, incomingPath), (CodingKeys.archivePath, archivePath)])
        guard partial.isEmpty else { return partial }
        let incoming = incomingURL.canonicalPlacePath, archive = archiveURL.canonicalPlacePath
        let apart = "choose two folders, neither inside the other"
        let (incomingNamed, archiveNamed) = (Self.named(.incomingPath, incomingPath, spelled: incoming),
                                             Self.named(.archivePath, archivePath, spelled: archive))
        if Self.folder(incoming, isInside: archive) && Self.folder(archive, isInside: incoming) {
            return ["\(incomingNamed) and \(archiveNamed) are one folder, so what is filed would be taken in again; \(apart)"]
        }
        if Self.folder(archive, isInside: incoming) {
            return ["\(archiveNamed) is inside \(incomingNamed), so everything filed would be taken in again; \(apart)"]
        }
        if Self.folder(incoming, isInside: archive) {
            return ["\(incomingNamed) is inside \(archiveNamed), so what waits there would be taken for documents of the archive; \(apart)"]
        }
        return []
    }

    /// Why the archive's folder, named by a partial path, cannot be used: what is checked before anything uses it.
    var archivePathProblems: [String] { Self.partialPaths([(CodingKeys.archivePath, archivePath)]) }

    /// Why each of `written`, by its key, is not a full path to a folder.
    private static func partialPaths(_ written: [(CodingKeys, String)]) -> [String] {
        written.filter { !isFullPath($0.1) }.map { "\($0.0.stringValue) “\($0.1)” is not a full path to a folder, from / or ~" }
    }

    /// Whether `path`, after `~`, starts at the top of the disk, so it names one place whatever folder a process runs in.
    private static func isFullPath(_ path: String) -> Bool { path.expandingTilde.hasPrefix("/") }

    /// Whether the folder at `inner` is the folder at `outer` or inside it, comparing their parts whatever their case.
    private static func folder(_ inner: String, isInside outer: String) -> Bool {
        let (innerParts, outerParts) = (URL(fileURLWithPath: inner).pathComponents, URL(fileURLWithPath: outer).pathComponents)
        return innerParts.count >= outerParts.count
            && zip(innerParts, outerParts).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    /// A folder setting as a refusal names it: its key and its value as written, and the folder the file system takes it
    /// for when that is spelled otherwise, as through a link.
    private static func named(_ key: CodingKeys, _ written: String, spelled: String) -> String {
        let named = "\(key.stringValue) “\(written)”"
        // Both in one form: standardized, which takes `/private` off a temporary folder's canonical path, as it is written.
        let same = URL(fileURLWithPath: spelled).standardizedFileURL.path == URL(fileURLWithPath: written.expandingTilde).standardizedFileURL.path
        return same ? named : named + " (“\(spelled)”)"
    }
}

/// A change of the settings: those in force before and after it, and what the change gave back.
public struct SettingsChange<Outcome: Sendable>: Sendable {
    public let before: AppSettings
    public let after: AppSettings
    public let outcome: Outcome
}

/// Loads and saves `AppSettings` (only the diff against bundled defaults is written), broadcasting changes. Each change
/// is made in one turn of its own, which no other change of any store, in this process or another, such as
/// `arrumatorcli` while the app runs, comes into (`flock(2)` on a file beside the settings): the file is read again,
/// the change is checked, recorded by whoever records it, and saved. Settings the next launch would refuse
/// (`AppSettings.problems`), and a file that cannot be read, are refused before anything is written, naming the file and
/// how to mend it. Every change saved is told to every store of the same file, in any process (`ChangeSignal`), which
/// reads the file again and publishes what changed (`changes()`), so the app goes on at once with a profile or a pause
/// `arrumatorcli` saved.
///
/// What the change and its record leave after a crash: the file is renamed into place before the transaction that holds
/// the record commits, so a process that ends between the two leaves the change saved without its record. Nothing else
/// leaves one apart from the other (`change(_:recording:)`).
public actor SettingsStore {
    public let url: URL
    /// What tells every store of this file, in any process, that a change was saved.
    private let signal: ChangeSignal
    private let defaultsValue: JSONValue
    private var cached: AppSettings
    private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]
    /// One change at a time, from reading the file to saving it, however long recording it takes: a change that came
    /// between would be saved over by the one it came into.
    private let turn = AsyncSemaphore(permits: 1)

    /// How a change waits for one another process is making, and the clock it waits on.
    private let lockConfig: SettingsLockConfig
    private let time: any TimeSource

    /// - Parameter mending: whether settings the app could not run with are taken all the same, as `arrumatorcli settings`
    ///   takes them to mend them: every change then refuses settings that still cannot be used (`refuseUnusable()`).
    ///   Otherwise they are refused, naming the file and how to mend it. An archive the settings name by a partial path
    ///   is refused either way, as nothing may use a place that depends on the folder a process runs in, and no option
    ///   of `settings` mends it.
    public init(paths: AppPaths, config: SettingsLockConfig, time: any TimeSource, mending: Bool = false) throws {
        url = paths.settingsURL
        signal = ChangeSignal(settings: paths.settingsURL)
        lockConfig = config
        self.time = time
        defaultsValue = try ConfigLoader.bundledValue(AppSettings.configurationName)
        cached = try Self.read(Self.contents(of: paths.settingsURL), at: paths.settingsURL, validating: !mending)
        if mending {
            try ConfigLoader.refuse(cached.archivePathProblems, name: AppSettings.configurationName, file: url, mend: Self.mendArchive)
        }
    }

    /// How an archive named by a partial path is mended, as its refusal says.
    public static let mendArchive = "Correct archivePath in that file: give the archive's folder from / or ~"

    /// How settings the app cannot run with are mended, as their refusal says.
    public static let mend = "Give other values with `arrumatorcli settings`, such as `--incoming <folder>` or "
        + "`--trace-retention-days <days>`, which mends them, or correct them in that file"

    /// The settings `file` at `url` holds over the bundled defaults; the defaults when there is no file. One that is not
    /// JSON, has a key the app does not know or, when `validating`, settings it cannot run with, is refused naming `url`.
    private static func read(_ file: Data?, at url: URL, validating: Bool) throws -> AppSettings {
        do {
            let overrides = try file.map { [try JSON.decoder.decode(JSONValue.self, from: $0)] } ?? []
            return try ConfigLoader.load(AppSettings.self, defaults: AppSettings.configurationName, overrides: overrides,
                                         validating: validating)
        } catch let refused as ConfigError {
            throw refused.naming([url], mend: mend)
        } catch {
            throw ConfigError.invalidFile(name: AppSettings.configurationName, paths: [url.path], underlying: error.localizedDescription,
                                          mend: mend)
        }
    }

    /// Refuses the settings in force when the app could not run with them, naming the file and what is left to mend: what
    /// a store that took them to be mended (`init(paths:mending:)`) says once it has been given what it was given.
    public func refuseUnusable() throws {
        try ConfigLoader.refuse(cached.problems, name: AppSettings.configurationName, file: url)
    }

    /// What the file at `url` holds; nil when there is none.
    private static func contents(of url: URL) throws -> Data? {
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    /// The settings in force: those last read from the file or saved to it.
    public var current: AppSettings { cached }

    /// Applies `mutate` to the settings in force and saves them, as `change(_:)` does; the settings in force after it. A
    /// change the user makes goes through `SettingsActions`, which records it in History.
    @discardableResult
    public func update(_ mutate: @Sendable (inout AppSettings) throws -> Void) async throws -> AppSettings {
        try await change(mutate).after
    }

    /// Applies `mutate` to the settings in force and saves them when they differ, recording nothing, as
    /// `change(_:recording:)` does.
    public func change<Outcome: Sendable>(_ mutate: @Sendable (inout AppSettings) throws -> Outcome) async throws
        -> SettingsChange<Outcome> {
        try await change(mutate) { _, save in try save() }
    }

    /// Applies `mutate` to the settings in force and, when they differ, records and saves them, in a turn no other change
    /// of this store comes into: the settings before and after, and what `mutate` gave back. The settings in force are
    /// read again from the file first, and a change found there is published as one made here is, so a change another
    /// process made is kept rather than saved over. `mutate` checks the settings it is given, so what it checks is what
    /// it changes; when it throws, or makes settings the next launch would refuse, nothing is recorded or saved.
    ///
    /// `record` records the change and saves it, calling `save` as the last step of what it records, so that the record
    /// is kept only once the settings are saved (`SettingsActions`, which records in the transaction that saves). When it
    /// throws after `save` wrote the file, as when that transaction cannot be committed, the file is put back as it was,
    /// so a change is never in force without its record.
    public func change<Outcome: Sendable>(_ mutate: @Sendable (inout AppSettings) throws -> Outcome,
                                          recording record: @Sendable (SettingsChange<Outcome>, _ save: @escaping @Sendable () throws -> Void)
                                              async throws -> Void) async throws -> SettingsChange<Outcome> {
        try await turn.acquire()
        defer { turn.release() }
        let lock = try await lockAcrossProcesses()
        defer { lock.release() }
        let (before, file) = try reread()
        var after = before
        let outcome = try mutate(&after)
        let change = SettingsChange(before: before, after: after, outcome: outcome)
        guard after != before else { return change }
        try refuse(after, changing: before)
        let saved = try encoded(after)
        let url = url
        do {
            try await record(change) { try Self.write(saved, to: url) }
        } catch {
            do { try putBack(file, over: saved) } catch let failure {
                Log.error(.app, "A settings change was saved and could neither be recorded nor put back",
                          ["error": failure.localizedDescription])
            }
            throw error
        }
        publish(after)
        signal.post()
        return change
    }

    /// Refuses, as `change` would, the settings `mutate` makes of those in force, and writes the file again as it is:
    /// what saves them later, once it can no longer be undone, as a switch of archives once the app has stopped, finds
    /// out first that it could not. Nothing changes.
    public func checkSaving(_ mutate: @Sendable (inout AppSettings) throws -> Void) async throws {
        try await turn.acquire()
        defer { turn.release() }
        let lock = try await lockAcrossProcesses()
        defer { lock.release() }
        let (before, file) = try reread()
        var after = before
        try mutate(&after)
        try refuse(after, changing: before)
        try Self.write(file ?? encoded(before), to: url)
    }

    /// Refuses `after` when the app could not run with it: naming the file and what is left to mend when the file already
    /// held settings it could not (`before`), as one an earlier version saved; otherwise as the change that is refused.
    private func refuse(_ after: AppSettings, changing before: AppSettings) throws {
        if before.problems.isEmpty {
            try ConfigLoader.refuse(after.problems, name: AppSettings.configurationName)
        } else {
            try ConfigLoader.refuse(after.problems, name: AppSettings.configurationName, file: url)
        }
    }

    /// The settings in force read again from the file, and the file as read. A change found there is published, when the
    /// app can run with it; one it cannot is only the start of a change, which must leave settings it can.
    private func reread() throws -> (settings: AppSettings, file: Data?) {
        let file = try Self.contents(of: url)
        let settings = try Self.read(file, at: url, validating: false)
        if settings.problems.isEmpty { publish(settings) }
        return (settings, file)
    }

    /// Makes `settings` the settings in force, and tells every subscriber when they changed.
    private func publish(_ settings: AppSettings) {
        guard settings != cached else { return }
        cached = settings
        for c in continuations.values { c.yield(settings) }
    }

    /// Puts the file back as it was, `file`, or as none, over the change `saved` wrote, when it is still there: its
    /// record failed, so it was not made.
    private func putBack(_ file: Data?, over saved: Data) throws {
        guard try Self.contents(of: url) == saved else { return }
        if let file {
            try Self.write(file, to: url)
        } else {
            // The app's own file, made by this change a moment ago: nothing of the user's.
            try FileManager.default.removeItem(at: url)
        }
    }

    /// What the file holds of `settings`: what differs from the bundled defaults.
    private func encoded(_ settings: AppSettings) throws -> Data {
        let value = try JSON.decoder.decode(JSONValue.self, from: JSON.encoder.encode(settings))
        return try JSON.prettyEncoder.encode(ConfigLoader.diff(value, from: defaultsValue) ?? .object([:]))
    }

    private static func write(_ file: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(to: url, options: .atomic)
    }

    /// How many changes wait for their turn: what a test watches for before it lets the one in its turn go on.
    var changesWaiting: Int { turn.waiting }

    /// Whether a change of this store waits for one another store, as in another process, is making: what a test watches
    /// for before it lets that one go on.
    private(set) var waitsForAnotherChange = false

    private func lockAcrossProcesses() async throws -> SettingsLock {
        waitsForAnotherChange = true
        defer { waitsForAnotherChange = false }
        return try await SettingsLock.take(beside: url, config: lockConfig, time: time)
    }

    /// The settings each time they change, for as long as the stream is read: changed through this store, or saved by
    /// another store of the file, as `arrumatorcli` does while the app runs, told by its `ChangeSignal`.
    public func changes() -> AsyncStream<AppSettings> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AppSettings>.makeStream()
        continuations[id] = continuation
        let posts = signal.posts()
        let listening = Task { [weak self] in
            for await _ in posts { await self?.readOthersChange() }
        }
        continuation.onTermination = { [weak self] _ in
            listening.cancel()
            Task { await self?.remove(id) }
        }
        return stream
    }

    /// Reads the file again when a store of it said a change was saved, and publishes what it holds when the app can run
    /// with it (`reread`): what this store saved itself is no change. One it cannot read now is left to the next change,
    /// which refuses it, naming the file. It is read under the lock across processes a change is made under, this
    /// store's own included: a change saved and not recorded yet, which may yet be put back, is read once it is over,
    /// never in between.
    func readOthersChange() async {
        do {
            waitsToReadAnotherChange = true
            defer { waitsToReadAnotherChange = false }
            let lock = try await SettingsLock.take(beside: url, config: lockConfig, time: time)
            defer { lock.release() }
            _ = try reread()
        } catch {
            Log.warning(.app, "Could not read the settings another process saved", ["error": error.localizedDescription])
        }
    }

    /// Whether this store waits for a change another store is making to end, before it reads what was saved: what a test
    /// watches for before it lets that one go on.
    private(set) var waitsToReadAnotherChange = false

    private func remove(_ id: UUID) { continuations[id] = nil }
}
