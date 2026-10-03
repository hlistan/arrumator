import Foundation

/// The one writer of the user's changes to the settings: each change is recorded once in History as `.settingsChanged`,
/// in the words its caller gives and with the settings it changed, and saved, from the app and the command line alike
/// (AGENTS.md §4.4). The record and the save are one: the event is written in the transaction that saves the settings,
/// which saves them as its last step, so a save that fails records nothing, a record that fails saves nothing, and a
/// change is never in force without its record (`SettingsStore.change(_:recording:)`), but for a crash between the file
/// being saved and the transaction being committed, which leaves the change without its record. A change that changes nothing is
/// neither saved nor recorded. Pausing is recorded as `.paused` or `.resumed` (`setPaused(_:)`); switching archives
/// records an event of its own.
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
        try await save(mutate) { _, _, _ in summary }.settings
    }

    /// Applies `mutate` as `change(summary:_:)` does, recorded in History in words made of what changed
    /// (`summary(_:in:)`): how Settings in the app and `arrumatorcli settings` change any setting without an action of
    /// its own, several at once as one change.
    @discardableResult
    public func change(_ mutate: @Sendable (inout AppSettings) throws -> Void) async throws -> AppSettings {
        try await save(mutate) { _, changed, settings in try Self.summary(changed, in: settings) }.settings
    }

    /// Applies a change that depends on the settings in force as one step, as `change(summary:_:)` does: `mutate` checks
    /// the settings it is given, refuses the change by throwing, or changes them and says what History records of it,
    /// `summary`, and what its caller is given back, `outcome`, so no other change comes between what it checked and
    /// what it wrote. Returns the settings in force and that outcome.
    @discardableResult
    public func change<Outcome: Sendable>(checking mutate: @Sendable (inout AppSettings) throws -> (summary: String, outcome: Outcome))
        async throws -> (settings: AppSettings, outcome: Outcome) {
        let saved = try await save(mutate) { described, _, _ in described.summary }
        return (saved.settings, saved.outcome.outcome)
    }

    /// Pauses or resumes filing, saved and recorded as `.paused` or `.resumed` as one change, as `change(summary:_:)` is:
    /// from the app and the command line alike (`ArrumatorRuntime.setPaused`). When filing already is as asked, nothing
    /// is saved or recorded. Returns the settings in force.
    @discardableResult
    public func setPaused(_ paused: Bool) async throws -> AppSettings {
        try await save({ $0.paused = paused }, as: paused ? .paused : .resumed) { _, _, _ in
            paused ? Self.pausedSummary : Self.resumedSummary
        }.settings
    }

    /// How History says filing was paused, and resumed.
    static let pausedSummary = "Processing paused"
    static let resumedSummary = "Processing resumed"

    /// What a change did, as History says it: the profile chosen, in the words choosing it has (`reading(with:)`), then
    /// every other setting by its name in `settings.json`, in the order of their names, with what it became, as in
    /// “Changed logLevel to debug, renameFiles to false” or “Reading with the profile “Smart”; changed renameFiles to
    /// false”. `settings` are the settings after the change.
    static func summary(_ changed: [String: JSONValue], in settings: AppSettings) throws -> String {
        let profile = AppSettings.CodingKeys.profile.stringValue
        let chosen = try changed[profile].map { _ in reading(with: try settings.modelProfile()) }
        let others = changed.filter { $0.key != profile }.sorted { $0.key < $1.key }
            .map { "\($0.key) to \($0.value.stringValue ?? $0.value.serialized())" }.joined(separator: ", ")
        guard !others.isEmpty else { return chosen ?? "" }
        return chosen.map { "\($0); changed \(others)" } ?? "Changed \(others)"
    }

    /// How History says the settings read with `profile` from now on.
    static func reading(with profile: ModelProfile) -> String { "Reading with the profile “\(profile.name)”" }

    /// Records the change, in the words `summary` gives for what `mutate` gave back, the settings that changed and the
    /// settings after it, and saves it, in one transaction.
    private func save<Outcome: Sendable>(_ mutate: @Sendable (inout AppSettings) throws -> Outcome, as kind: EventKind = .settingsChanged,
                                         summarized summary: @escaping @Sendable (Outcome, [String: JSONValue], AppSettings) throws -> String)
        async throws -> (settings: AppSettings, outcome: Outcome) {
        let change = try await store.change(mutate) { [history] change, save in
            let changed = try Self.changes(from: change.before, to: change.after)
            try await history.record(kind, actor: .user, summary: try summary(change.outcome, changed, change.after),
                                     payload: changed, alongside: save)
        }
        return (change.after, change.outcome)
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
