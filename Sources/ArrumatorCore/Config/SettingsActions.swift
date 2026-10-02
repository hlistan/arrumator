import Foundation

/// The one writer of the user's changes to the settings: each change is saved through the store and recorded once in
/// History as `.settingsChanged`, in the words its caller gives and with the settings it changed, from the app and the
/// command line alike (AGENTS.md §4.4). A change that changes nothing is neither saved nor recorded. Pausing
/// (`.paused`, `.resumed`) and switching archives record events of their own.
public struct SettingsActions: Sendable {
    public let store: SettingsStore
    public let history: HistoryStore

    public init(store: SettingsStore, history: HistoryStore) {
        self.store = store
        self.history = history
    }

    /// Applies `mutate` to the settings in force, saves them and records the change in History as `summary`, a sentence
    /// a person reads there, with the top-level settings that changed and their new values as its payload. Settings the
    /// next launch would refuse are refused, and so is a change `mutate` refuses by throwing: nothing is saved or
    /// recorded. Returns the settings in force.
    @discardableResult
    public func change(summary: String, _ mutate: @Sendable (inout AppSettings) throws -> Void) async throws -> AppSettings {
        try await save(mutate) { _, _ in summary }.settings
    }

    /// Applies `mutate` as `change(summary:_:)` does, recorded in History in words made of what changed
    /// (`summary(_:)`): how Settings in the app and `arrumatorcli settings` change any setting without an action of its own.
    @discardableResult
    public func change(_ mutate: @Sendable (inout AppSettings) throws -> Void) async throws -> AppSettings {
        try await save(mutate) { _, changed in Self.summary(changed) }.settings
    }

    /// Applies a change that depends on the settings in force as one step, as `change(summary:_:)` does: `mutate` checks
    /// the settings it is given, refuses the change by throwing, or changes them and says what History records of it,
    /// `summary`, and what its caller is given back, `outcome`, so no other change comes between what it checked and
    /// what it wrote. Returns the settings in force and that outcome.
    @discardableResult
    public func change<Outcome: Sendable>(checking mutate: @Sendable (inout AppSettings) throws -> (summary: String, outcome: Outcome))
        async throws -> (settings: AppSettings, outcome: Outcome) {
        let saved = try await save(mutate) { described, _ in described.summary }
        return (saved.settings, saved.outcome.outcome)
    }

    /// What a change did, as History says it: “Changed logLevel to debug, renameFiles to false”, each setting by its
    /// name in `settings.json`, in the order of their names, with what it became.
    static func summary(_ changed: [String: JSONValue]) -> String {
        "Changed " + changed.sorted { $0.key < $1.key }.map { "\($0.key) to \($0.value.stringValue ?? $0.value.serialized())" }
            .joined(separator: ", ")
    }

    /// Saves the change and records it, in the words `summary` gives for what `mutate` gave back and the settings that
    /// changed.
    private func save<Outcome: Sendable>(_ mutate: @Sendable (inout AppSettings) throws -> Outcome,
                                         summarized summary: (Outcome, [String: JSONValue]) -> String) async throws
        -> (settings: AppSettings, outcome: Outcome) {
        let (before, after, outcome) = try await store.change(mutate)
        let changed = try Self.changes(from: before, to: after)
        guard !changed.isEmpty else { return (after, outcome) }
        try await history.record(.settingsChanged, actor: .user, summary: summary(outcome, changed), payload: changed)
        return (after, outcome)
    }

    /// The top-level settings that differ between `before` and `after`, with their values in `after`: null for one taken
    /// away, such as a path no longer set.
    private static func changes(from before: AppSettings, to after: AppSettings) throws -> [String: JSONValue] {
        guard case let .object(old) = try value(before), case let .object(new) = try value(after) else { return [:] }
        var changed: [String: JSONValue] = [:]
        for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
            changed[key] = new[key] ?? .null
        }
        return changed
    }

    /// The settings as `settings.json` holds them.
    private static func value(_ settings: AppSettings) throws -> JSONValue {
        try JSON.decoder.decode(JSONValue.self, from: JSON.encoder.encode(settings))
    }
}
