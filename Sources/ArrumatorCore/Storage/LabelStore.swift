import Foundation
import GRDB

/// One decision of the user's about a label, applied to every document the model reads from then on. Kept in the
/// archive's `System/_labels.md` (docs/storage.md).
public struct LabelRule: ArrumatorRecord, Identifiable, Hashable {
    public static let databaseTableName = "label_rules"
    public var id: Int64?
    public var kind: LabelKind
    /// The label the rule is about.
    public var value: String
    public var action: LabelRuleAction
    /// For a merge, the label written instead; for keeping apart, the other label; nil for ignoring.
    public var target: String?
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public init(id: Int64? = nil, kind: LabelKind, value: String, action: LabelRuleAction, target: String?, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.value = value
        self.action = action
        self.target = target
        self.createdAt = createdAt
    }

    /// Whether the rule is about `label`, written however.
    func concerns(_ label: DocumentLabel) -> Bool {
        kind == label.kind && LabelSimilarity.sameWriting(value, label.value)
    }

    /// Whether the rule keeps `a` and `b` of `kind` apart.
    func keepsApart(_ a: String, _ b: String, kind: LabelKind) -> Bool {
        guard action == .keepApart, self.kind == kind, let target else { return false }
        let (x, y) = (LabelSimilarity.Key(value), LabelSimilarity.Key(target))
        let (p, q) = (LabelSimilarity.Key(a), LabelSimilarity.Key(b))
        return (x.isSameWriting(as: p) && y.isSameWriting(as: q)) || (x.isSameWriting(as: q) && y.isSameWriting(as: p))
    }

    /// The rule as a line: “sender EDP Comercial → EDP”.
    public var summary: String {
        switch action {
        case .merge: "\(kind.rawValue) “\(value)” → “\(target ?? "")”"
        case .ignore: "\(kind.rawValue) “\(value)” ignored"
        case .keepApart: "\(kind.rawValue) “\(value)” and “\(target ?? "")” kept apart"
        }
    }
}

/// The archive's labels as one vocabulary: which are in use and how often, the user's rules about them, and what
/// follows from both for the model (`LabelGuidance`) and for the labels it gives (`LabelConsolidator`).
public struct LabelStore: Sendable {
    public let database: AppDatabase
    public let config: LabelsConfig
    /// Which labels looked alike when `suggestions()` was last asked, for each kind.
    public let lookAlikes: LookAlikeMemo

    public init(database: AppDatabase, config: LabelsConfig, lookAlikes: LookAlikeMemo) {
        self.database = database
        self.config = config
        self.lookAlikes = lookAlikes
    }

    /// Every label in use, by kind, the most used first. With `selection`, only the documents that have every label of
    /// it count, so what is left are the labels to narrow them down further by, the selection's own among them.
    public func usage(within selection: [DocumentLabel] = []) async throws -> [LabelKind: [LabelUsage]] {
        try await database.reader.read { db in try Self.usage(db, within: DocumentFilter(labels: selection)) }
    }

    static func usage(_ db: Database, within scope: DocumentFilter = DocumentFilter()) throws -> [LabelKind: [LabelUsage]] {
        let (conditions, args) = try scope.sql(db)
        let rows = try Row.fetchAll(db, sql: """
            SELECT json_extract(l.value, '$.kind') AS kind, json_extract(l.value, '$.value') AS value, COUNT(DISTINCT d.id) AS documents
            FROM documents d, json_each(d.labels_json) l WHERE d.labels_json IS NOT NULL\(conditions)
            GROUP BY 1, 2 ORDER BY documents DESC, value
            """, arguments: args)
        var usage: [LabelKind: [LabelUsage]] = [:]
        for row in rows {
            guard let kind = LabelKind(rawValue: row["kind"] ?? ""), let value: String = row["value"] else { continue }
            usage[kind, default: []].append(LabelUsage(label: DocumentLabel(kind: kind, value: value), documents: row["documents"]))
        }
        return usage
    }

    /// The user's rules, oldest first.
    public func rules() async throws -> [LabelRule] {
        try await database.reader.read { db in try LabelRule.order(Column("id")).fetchAll(db) }
    }

    /// Applies the rules and the vocabulary to what the model gives a document.
    public func consolidator() async throws -> LabelConsolidator {
        let (rules, usage) = try await database.reader.read { db in (try LabelRule.order(Column("id")).fetchAll(db), try Self.usage(db)) }
        return LabelConsolidator(config: config.vocabulary, rules: rules, vocabulary: usage)
    }

    /// Pairs of labels in use alike enough to be one, which the user has not decided about. Which labels of a kind look
    /// alike is brought up to date from when it was last asked, comparing only the labels added since (`LookAlikeMemo`);
    /// one asking while another works it out waits for it. Stopping is thrown, the work done kept.
    public func suggestions() async throws -> [LabelSuggestion] {
        try await consolidator().suggestions(by: lookAlikes, comparing: LabelSimilarity.lookAlike(_:_:atLeast:))
    }

    /// Works out which labels look alike, as `suggestions()` does, so that the first to ask for them seldom waits: what
    /// the runtime does once the archive is open. Stopping ends it, keeping what it has done; a failure is logged.
    public func workOutLookAlikes() async {
        do { _ = try await suggestions() } catch {
            guard !(error is CancellationError || Task.isCancelled) else { return }
            Log.error(.db, "Could not work out which labels look alike", ["error": error.localizedDescription])
        }
    }

    /// What the model is shown of the archive: the labels it uses most, and the user's merges and unwanted labels, of the
    /// kinds the model gives. It is shown nothing of the user's own tags, which it never gives.
    public func guidance() async throws -> LabelGuidance {
        let (all, usage) = try await database.reader.read { db in (try LabelRule.order(Column("id").desc).fetchAll(db), try Self.usage(db)) }
        let rules = all.filter { !$0.kind.isUsersOwn }
        let vocabulary = config.vocabulary
        var used: [LabelKind: [String]] = [:]
        for (kind, policy) in vocabulary.kinds where policy.promptLimit > 0 && !kind.isUsersOwn {
            let values = (usage[kind] ?? []).prefix(policy.promptLimit).map(\.label.value)
            if !values.isEmpty { used[kind] = values }
        }
        let preferred = rules.filter { $0.action == .merge }.prefix(vocabulary.promptPreferred).compactMap { rule in
            rule.target.map { LabelPreference(from: DocumentLabel(kind: rule.kind, value: rule.value), to: $0) }
        }
        let unwanted = rules.filter { $0.action == .ignore }.prefix(vocabulary.promptUnwanted).map { DocumentLabel(kind: $0.kind, value: $0.value) }
        return LabelGuidance(used: used, preferred: preferred, unwanted: unwanted)
    }
}
