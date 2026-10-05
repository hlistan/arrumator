import Foundation

/// What the user does with model profiles, from the app and the command line alike: lists them, adds one, changes one,
/// sets a predefined one back to its bundled value, removes one of their own, and chooses the one Settings reads with.
/// A new profile is a copy of another, so no model name is written in code. Each change is saved in `settings.json`,
/// which holds only what differs from the bundled profiles, and recorded once in History, saying what changed
/// (`SettingsActions`). Each is checked against the settings in force and made in the same step
/// (`SettingsActions.change(checking:)`), so changes made at once each hold, and what would leave the settings unusable,
/// or a profile changed after it is gone, is refused before anything is written.
public struct ModelProfileActions: Sendable {
    public let settings: SettingsActions
    /// The profiles the bundled settings list (`AppSettings.bundledDefaults()`), by their ids: predefined, so never
    /// removed, as the bundled settings would bring them back, and reset to these.
    public let bundled: [String: ModelProfile]
    /// The index of the archive that is open, which says how many of its search tasks read with a profile.
    private let database: AppDatabase

    public init(settings: SettingsActions, bundled: [String: ModelProfile], database: AppDatabase) {
        self.settings = settings
        self.bundled = bundled
        self.database = database
    }

    /// The first number a new profile's id takes when another profile has its name's: `mine-2`, then `mine-3`.
    static let firstSuffix = 2

    /// Every profile, by its position, then by its name.
    public func list() async -> [ModelProfileListing] {
        let current = await settings.store.current
        return current.modelProfiles
            .sorted { ($0.value.position, $0.value.nameKey, $0.key) < ($1.value.position, $1.value.nameKey, $1.key) }
            .map { listing($0.key, $0.value, in: current) }
    }

    /// Adds a profile called `name`: a copy of the profile `copying` names, else of the one Settings reads with, with what
    /// `change` gives, after every other profile. Its id is made of its name (`id(for:taken:)`). A name
    /// `refusal(ofNewName:in:)` refuses and a blank model are refused.
    @discardableResult
    public func add(name: String, copying source: String? = nil, change: ModelProfileChange = ModelProfileChange()) async throws
        -> ModelProfileListing {
        let (saved, added) = try await settings.change(checking: { settings in
            var profile = try settings.modelProfile(source.map(DocumentLabel.oneLine))
            profile.name = DocumentLabel.oneLine(name)
            profile = try Self.applying(change, to: profile, named: nil)
            if let refusal = Self.refusal(ofNewName: profile.name, in: settings) { throw refusal }
            let id = try Self.id(for: profile.name, taken: Set(settings.modelProfiles.keys))
            profile.position = (settings.modelProfiles.values.map(\.position).max() ?? 0) + 1
            settings.modelProfiles[id] = profile
            return (summary: "Added the profile “\(profile.name)”, reading with \(profile.chatModel)", outcome: (id: id, profile: profile))
        })
        return listing(added.id, added.profile, in: saved)
    }

    /// Why a new profile cannot be called `name` among the profiles `settings` lists, or nil when it can: a blank name, a
    /// name another profile has, whatever its case, named by that profile's name, and a name with no letter or digit to
    /// make its id of. `add(name:)` refuses what this says, and the app says it as the name is typed.
    public static func refusal(ofNewName name: String, in settings: AppSettings) -> ModelProfileError? {
        let name = DocumentLabel.oneLine(name)
        guard !name.isEmpty else { return .blankName(nil) }
        if let other = holder(of: name, other: nil, in: settings) { return .nameTaken(name: name, by: other) }
        guard idWords(of: name) != nil else { return .nameWithoutLetterOrDigit(name) }
        return nil
    }

    /// The names the predefined profiles come with, in their order: what Arrumator ships, however the user renamed them.
    public var predefinedNames: [String] {
        bundled.values.sorted { ($0.position, $0.nameKey) < ($1.position, $1.nameKey) }.map(\.name)
    }

    /// Changes the profile's name or models, as `change` gives them. An unknown profile, a blank value and a name another
    /// profile has are refused; the values it has already change nothing.
    @discardableResult
    public func update(_ id: String, _ change: ModelProfileChange) async throws -> ModelProfileListing {
        let id = DocumentLabel.oneLine(id)
        let (saved, new) = try await settings.change(checking: { settings in
            let old = try settings.modelProfile(id)
            let new = try Self.applying(change, to: old, named: old.name)
            try Self.refuseTakenName(of: new, id: id, in: settings)
            settings.modelProfiles[id] = new
            return (summary: "The profile “\(old.name)” " + Format.and(Self.differences(from: old, to: new)), outcome: new)
        })
        return listing(id, new, in: saved)
    }

    /// Sets a predefined profile back to the bundled one, so `settings.json` no longer mentions it and a new bundled value
    /// reaches it. A profile of the user's own has nothing to go back to, and is refused.
    @discardableResult
    public func reset(_ id: String) async throws -> ModelProfileListing {
        let id = DocumentLabel.oneLine(id)
        let bundled = bundled[id]
        let (saved, original) = try await settings.change(checking: { settings in
            let old = try settings.modelProfile(id)
            guard let original = bundled else { throw ModelProfileError.notPredefined(old.name) }
            try Self.refuseTakenName(of: original, id: id, in: settings)
            settings.modelProfiles[id] = original
            return (summary: "Reset the profile “\(old.name)”", outcome: original)
        })
        return listing(id, original, in: saved)
    }

    /// Removes a profile of the user's own. What `ModelProfileListing.removalRefusal(searchTasks:)` says of it is refused:
    /// a predefined one, as the bundled settings would bring it back, the one Settings reads with and one search tasks of
    /// the archive that is open read with, which are given another first. Profiles are the user's, tasks each archive's:
    /// a task of another archive whose profile is gone fails saying so until it is given another.
    @discardableResult
    public func remove(_ id: String) async throws -> ModelProfileListing {
        let id = DocumentLabel.oneLine(id)
        // Counted in the index before the settings are changed, as a change of the settings waits on nothing else.
        let tasks = try await searchTasks(readingWith: id)
        let (saved, removed) = try await settings.change(checking: { settings in
            let removed = try settings.modelProfile(id)
            if let refusal = listing(id, removed, in: settings).removalRefusal(searchTasks: tasks) { throw refusal }
            settings.modelProfiles[id] = nil
            return (summary: "Removed the profile “\(removed.name)”", outcome: removed)
        })
        return listing(id, removed, in: saved)
    }

    /// How many search tasks of the archive that is open read with the profile `id` names, rather than with the one
    /// Settings uses; those of another archive are not known while it is closed.
    public func searchTasks(readingWith id: String) async throws -> Int {
        let id = DocumentLabel.oneLine(id)
        return try await database.reader.read { db in try SearchTaskStore.count(db, profile: id) }
    }

    /// Settings reads documents and requests with the profile from now on. An unknown profile is refused.
    @discardableResult
    public func use(_ id: String) async throws -> ModelProfileListing {
        let id = DocumentLabel.oneLine(id)
        let (saved, chosen) = try await settings.change(checking: { settings in
            let chosen = try settings.use(profile: id)
            return (summary: SettingsActions.reading(with: chosen), outcome: chosen)
        })
        return listing(id, chosen, in: saved)
    }

    /// The id a profile called `name` gets: the lowercase letters and digits of its name, its words joined by `-`, with
    /// `-2`, `-3`… after them while another profile has that id. A name with no letter or digit is refused.
    static func id(for name: String, taken: Set<String>) throws -> String {
        guard let base = idWords(of: name) else { throw ModelProfileError.nameWithoutLetterOrDigit(name) }
        var id = base
        var suffix = firstSuffix
        while taken.contains(id) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        return id
    }

    /// The lowercase words of letters and digits of `name`, joined by `-`; nil when it has no letter or digit.
    private static func idWords(of name: String) -> String? {
        let words = name.lowercased().split { !($0.isLetter || $0.isNumber) }
        return words.isEmpty ? nil : words.joined(separator: "-")
    }

    private func listing(_ id: String, _ profile: ModelProfile, in settings: AppSettings) -> ModelProfileListing {
        let original = bundled[id]
        return ModelProfileListing(id: id, profile: profile, predefined: original != nil, changed: original.map { $0 != profile } ?? false,
                                   inUse: id == settings.profile)
    }

    /// `profile` with what `change` gives, each value on one line; a blank one is refused, naming the profile by the name
    /// it had, `named`, nil for a new one.
    private static func applying(_ change: ModelProfileChange, to profile: ModelProfile, named: String?) throws -> ModelProfile {
        var changed = profile
        if let name = change.name.map(DocumentLabel.oneLine) {
            guard !name.isEmpty else { throw ModelProfileError.blankName(named) }
            changed.name = name
        }
        for role in ModelProfile.roles {
            guard let given = change.models[role] else { continue }
            let model = DocumentLabel.oneLine(given)
            guard !model.isEmpty else { throw ModelProfileError.blankModel(profile: changed.name, role: role) }
            changed[keyPath: ModelProfile.field(of: role).path] = model
        }
        return changed
    }

    /// Refuses `profile` when another profile than `id` has its name, whatever its case.
    private static func refuseTakenName(of profile: ModelProfile, id: String?, in settings: AppSettings) throws {
        if let other = holder(of: profile.name, other: id, in: settings) { throw ModelProfileError.nameTaken(name: profile.name, by: other) }
    }

    /// The name of a profile other than `id` that has `name`, whatever its case, or nil when none has.
    private static func holder(of name: String, other id: String?, in settings: AppSettings) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return settings.modelProfiles.filter { $0.key != id && $0.value.nameKey == key }.min { $0.key < $1.key }?.value.name
    }

    /// What differs between two values of a profile, as History says it: “reads with x instead of y”.
    private static func differences(from old: ModelProfile, to new: ModelProfile) -> [String] {
        var said: [String] = []
        if new.name != old.name { said.append("is renamed “\(new.name)”") }
        for role in ModelProfile.roles where new.model(for: role) != old.model(for: role) {
            said.append("\(work(of: role)) \(new.model(for: role)) instead of \(old.model(for: role))")
        }
        return said
    }

    /// What a profile does with the model of `role`, as History says it.
    private static func work(of role: ModelRole) -> String {
        switch role {
        case .chat: "reads with"
        case .vision: "describes images with"
        case .embedding: "finds by meaning with"
        }
    }
}
