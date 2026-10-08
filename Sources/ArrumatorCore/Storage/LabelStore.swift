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

    /// Whether the rule already decides labels `a` and `b` of one kind, so the model is not asked about them: it keeps the
    /// two apart, or it rewrites how either is written, merged or dropped, written however (`concerns`). What the user
    /// decided stands; the one check both the pairs judged (`LabelConsolidator`) and acting on a judgement
    /// (`LabelActions.decide`) apply.
    func decides(_ a: DocumentLabel, _ b: DocumentLabel) -> Bool {
        keepsApart(a.value, b.value, kind: a.kind) || (action.rewrites && (concerns(a) || concerns(b)))
    }

    /// Whether the rule merges `from` into `into`, each written so.
    func isMerge(of from: DocumentLabel, into: DocumentLabel) -> Bool {
        action == .merge && kind == from.kind && value == from.value && target == into.value
    }

    /// The rule as a line: “sender EDP Comercial → EDP”.
    public var summary: String {
        switch action {
        case .merge: "\(kind.rawValue) “\(value)” → “\(target ?? "")”"
        case .ignore: "\(kind.rawValue) “\(value)” ignored"
        case .keepApart: "\(kind.rawValue) “\(value)” and “\(target ?? "")” kept apart"
        case .add: "\(kind.rawValue) “\(value)” added"
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

    /// Counted from the index of the labels documents have (`v24_documentLabels`), which answers it by its key, so asking
    /// it for every reading and every change to History reads no document's labels; within a scope, of the documents in
    /// it alone.
    static func usage(_ db: Database, within scope: DocumentFilter = DocumentFilter()) throws -> [LabelKind: [LabelUsage]] {
        let (conditions, args) = try scope.sql(db)
        let labels = conditions.isEmpty ? "document_labels l" : "document_labels l JOIN documents d ON d.id = l.doc_id WHERE 1\(conditions)"
        let rows = try Row.fetchAll(db, sql: """
            SELECT l.kind AS kind, l.value AS value, COUNT(*) AS documents FROM \(labels)
            GROUP BY l.kind, l.value ORDER BY documents DESC, l.value
            """, arguments: args)
        var usage: [LabelKind: [LabelUsage]] = [:]
        for row in rows {
            guard let kind = LabelKind(rawValue: row["kind"] ?? ""), let value: String = row["value"] else { continue }
            usage[kind, default: []].append(LabelUsage(label: DocumentLabel(kind: kind, value: value), documents: row["documents"]))
        }
        return usage
    }

    /// Every label in use, as `usage()` gives them, and after the tags in use each tag the user added that no document has
    /// yet (`LabelActions.add`), the oldest added first: what the Labels page and `arrumatorcli labels list` show, and the
    /// tags a card offers.
    public func listing() async throws -> [LabelKind: [LabelUsage]] {
        try await database.reader.read { db in
            var listing = try Self.usage(db)
            let added = try LabelRule.filter(Column("action") == LabelRuleAction.add.rawValue).order(Column("id")).fetchAll(db)
            for rule in added where !(listing[rule.kind] ?? []).contains(where: { $0.label.value == rule.value }) {
                listing[rule.kind, default: []].append(LabelUsage(label: DocumentLabel(kind: rule.kind, value: rule.value), documents: 0))
            }
            return listing
        }
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

    /// Pairs of labels in use alike enough to be one, which no rule decides yet (`LabelRule.decides`), the most alike
    /// first: what the model judges (`LabelJudge`). Which labels of a kind look alike is brought up to date from when it was last asked, comparing
    /// only the labels added since (`LookAlikeMemo`); one asking while another works it out waits for it. Stopping is
    /// thrown, the work done kept.
    /// Pairs whose `pairID` is in `settingAside` are left out before the list is cut to `labels.vocabulary.suggestionLimit`, so
    /// those the model gave no answer for never hold up the rest.
    public func suggestions(settingAside: Set<String> = []) async throws -> [LabelSuggestion] {
        try await consolidator().suggestions(by: lookAlikes, comparing: LabelSimilarity.lookAlike(_:_:atLeast:), settingAside: settingAside)
    }

    /// What each label of `pair` is used for, as the model is shown it when it judges them (`LabelPairJudging`): how many
    /// documents have each, and the file names of the newest `names` of them, by when they were added.
    public func use(of pair: LabelSuggestion, names: Int) async throws -> LabelPairUse {
        try await database.reader.read { db in
            let of = { (value: String) throws -> (Int, [String]) in
                let arguments: StatementArguments = [pair.kind.rawValue, value]
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_labels WHERE kind = ? AND value = ?", arguments: arguments) ?? 0
                let paths = try String.fetchAll(db, sql: """
                    SELECT d.path FROM document_labels l JOIN documents d ON d.id = l.doc_id WHERE l.kind = ? AND l.value = ?
                    ORDER BY d.added_at DESC, d.id DESC LIMIT ?
                    """, arguments: arguments + [names])
                return (count, paths.map { URL(fileURLWithPath: $0).lastPathComponent })
            }
            let ((valueDocuments, valueNames), (intoDocuments, intoNames)) = (try of(pair.value), try of(pair.into))
            return LabelPairUse(valueDocuments: valueDocuments, valueNames: valueNames, intoDocuments: intoDocuments, intoNames: intoNames)
        }
    }

    /// What the model is told of the archive: the labels it uses most, and every merge and unwanted label of the user's,
    /// of the kinds the model gives, of which its prompt shows the newest (`PromptBuilder.archiveBlock`). It is told
    /// nothing of the user's own tags, which it never gives.
    public func guidance() async throws -> LabelGuidance {
        let (all, usage) = try await database.reader.read { db in (try LabelRule.order(Column("id").desc).fetchAll(db), try Self.usage(db)) }
        let rules = all.filter { !$0.kind.isUsersOwn }
        let vocabulary = config.vocabulary
        var used: [LabelKind: [String]] = [:]
        for (kind, policy) in vocabulary.kinds where policy.promptLimit > 0 && !kind.isUsersOwn {
            let values = (usage[kind] ?? []).prefix(policy.promptLimit).map(\.label.value)
            if !values.isEmpty { used[kind] = values }
        }
        let preferred = rules.filter { $0.action == .merge }.compactMap { rule in
            rule.target.map { LabelPreference(from: DocumentLabel(kind: rule.kind, value: rule.value), to: $0) }
        }
        let unwanted = rules.filter { $0.action == .ignore }.map { DocumentLabel(kind: $0.kind, value: $0.value) }
        return LabelGuidance(used: used, preferred: preferred, unwanted: unwanted)
    }
}
