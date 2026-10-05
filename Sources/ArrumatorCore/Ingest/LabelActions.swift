import Foundation
import GRDB

public enum LabelError: Error, LocalizedError, Equatable {
    case notALabel(LabelKind, String)
    case sameLabel(LabelKind, String)
    case ruleNotFound(Int64)

    public var errorDescription: String? {
        switch self {
        case let .notALabel(kind, value): "“\(value)” is no label of its kind: \(Self.form(of: kind))"
        case let .sameLabel(_, value): "“\(value)” is the same label either way"
        case let .ruleNotFound(id): "There is no rule \(id) about labels"
        }
    }

    /// Why `label` is no label of its kind, as `DocumentLabel.normalized` keeps one, or nil when it is one: what the app
    /// says as a label is typed, and what a correction of a document's labels and a decision about labels refuse.
    public static func refusal(of label: DocumentLabel) -> LabelError? {
        DocumentLabel.normalized(label.value, kind: label.kind) == nil ? .notALabel(label.kind, DocumentLabel.oneLine(label.value)) : nil
    }

    /// What a label of `kind` is, as `DocumentLabel.normalized` takes one, in words that name no kind: the app and the
    /// command line call kinds by names of their own ("About" on a card is `party=` on a command), and a refusal is
    /// shown beside where the kind was chosen.
    private static func form(of kind: LabelKind) -> String {
        let separator = kind.isUsersOwn ? "" : ", and no \(DocumentLabel.entrySeparator)"
        return switch kind {
        case .type: "it is one of " + DocumentType.allCases.filter { $0 != .other }.map(\.rawValue).joined(separator: ", ")
        case .date, .deadline: "it is a day of the calendar, as YYYY-MM-DD or DD.MM.YYYY"
        case .period: "it is a year, a month or a day, as YYYY, YYYY-MM or YYYY-MM-DD, or two of them as start/end"
        case .language: "it is an ISO 639 code or its English name, such as pt or Portuguese"
        case .amount: "it is a number and its currency, such as 54.21 EUR or 12,50 €, never a percentage"
        case .reference: "it has a number in it" + separator
        case .sender, .party, .topic, .object, .jurisdiction: "it has a letter in it" + separator
        case .tag: "it is not blank"
        }
    }
}

/// What a decision about a label did: the rule it made or forgot, and the documents whose labels it changed.
public struct LabelActionOutcome: Sendable, Codable, Hashable {
    public var rule: LabelRule
    public var documents: [Int64]
}

/// What the user decides about a label for the whole archive: merge it into another, stop wanting it, keep two alike
/// ones apart, or forget such a decision. Each becomes a rule every reading from then on follows (`LabelConsolidator`,
/// `LabelGuidance`) and changes every document it concerns now, in one transaction with its History event.
public struct LabelActions: Sendable {
    public let database: AppDatabase
    public let time: any TimeSource

    public init(database: AppDatabase, time: any TimeSource) {
        self.database = database
        self.time = time
    }

    /// Writes `label` as `value` on every document that has it, written however, and in every reading from now on.
    @discardableResult
    public func merge(_ label: DocumentLabel, into value: String) async throws -> LabelActionOutcome {
        let into = try Self.normalized(DocumentLabel(kind: label.kind, value: value))
        let now = time.now()
        return try await database.writer.write { db in
            let from = try Self.named(db, label)
            guard from.value != into.value else { throw LabelError.sameLabel(from.kind, from.value) }
            let rules = try LabelRule.fetchAll(db)
            let over = rules.filter { rule in
                // The new merge is the label's rule now.
                (rule.action != .keepApart && rule.concerns(from))
                    // The user wants `into` now: a rule dropping it, or merging it back into what is merged into it, is over.
                    || (rule.concerns(into) && (rule.action == .ignore || rule.target.map { LabelSimilarity.sameWriting($0, from.value) } == true))
                    || rule.keepsApart(from.value, into.value, kind: from.kind)
            }
            for rule in over { _ = try rule.delete(db) }
            // Labels merged into this one follow it to its new writing; a rule that is over follows nothing.
            let gone = Set(over)
            for var rule in rules where !gone.contains(rule) && rule.action == .merge && rule.kind == from.kind
                && rule.target.map({ LabelSimilarity.sameWriting($0, from.value) }) == true && !rule.concerns(into) {
                rule.target = into.value
                try rule.update(db)
            }
            var rule = LabelRule(kind: from.kind, value: from.value, action: .merge, target: into.value, createdAt: now)
            try rule.insert(db)
            let documents = try Self.relabel(db, from, to: into.value, at: now)
            try HistoryStore.insert(db, .labelsMerged, at: now, actor: .user,
                                    summary: "Merged \(from.kind.rawValue) “\(from.value)” into “\(into.value)”"
                                        + Self.onDocuments(documents),
                                    payload: LabelActionOutcome(rule: rule, documents: documents))
            return LabelActionOutcome(rule: rule, documents: documents)
        }
    }

    /// Takes `label`, written however, off every document, and out of every reading from now on.
    @discardableResult
    public func ignore(_ label: DocumentLabel) async throws -> LabelActionOutcome {
        let now = time.now()
        return try await database.writer.write { db in
            let unwanted = try Self.named(db, label)
            for rule in try LabelRule.fetchAll(db) where rule.action != .keepApart && rule.concerns(unwanted) {
                _ = try rule.delete(db)
            }
            var rule = LabelRule(kind: unwanted.kind, value: unwanted.value, action: .ignore, target: nil, createdAt: now)
            try rule.insert(db)
            let documents = try Self.relabel(db, unwanted, to: nil, at: now)
            try HistoryStore.insert(db, .labelIgnored, at: now, actor: .user,
                                    summary: "Ignored \(unwanted.kind.rawValue) “\(unwanted.value)”" + Self.onDocuments(documents, taken: true),
                                    payload: LabelActionOutcome(rule: rule, documents: documents))
            return LabelActionOutcome(rule: rule, documents: documents)
        }
    }

    /// Keeps `label` and `other` apart: they mean different things, however alike they are written.
    @discardableResult
    public func keepApart(_ label: DocumentLabel, from other: String) async throws -> LabelActionOutcome {
        let now = time.now()
        return try await database.writer.write { db in
            let (a, b) = (try Self.named(db, label), try Self.named(db, DocumentLabel(kind: label.kind, value: other)))
            guard !LabelSimilarity.sameWriting(a.value, b.value) else { throw LabelError.sameLabel(a.kind, a.value) }
            for rule in try LabelRule.fetchAll(db) where rule.action == .merge
                && ((rule.concerns(a) && rule.target.map { LabelSimilarity.sameWriting($0, b.value) } == true)
                    || (rule.concerns(b) && rule.target.map { LabelSimilarity.sameWriting($0, a.value) } == true)) {
                _ = try rule.delete(db)
            }
            var rule = try LabelRule.fetchAll(db).first { $0.keepsApart(a.value, b.value, kind: a.kind) }
                ?? LabelRule(kind: a.kind, value: a.value, action: .keepApart, target: b.value, createdAt: now)
            if rule.id == nil { try rule.insert(db) }
            try HistoryStore.insert(db, .labelsKeptApart, at: now, actor: .user,
                                    summary: "Kept \(a.kind.rawValue) “\(a.value)” and “\(b.value)” apart",
                                    payload: LabelActionOutcome(rule: rule, documents: []))
            return LabelActionOutcome(rule: rule, documents: [])
        }
    }

    /// Forgets a rule: readings from now on no longer follow it. Documents it already changed keep their labels.
    @discardableResult
    public func forget(rule id: Int64) async throws -> LabelActionOutcome {
        let now = time.now()
        return try await database.writer.write { db in
            guard let rule = try LabelRule.fetchOne(db, key: id) else { throw LabelError.ruleNotFound(id) }
            _ = try rule.delete(db)
            try HistoryStore.insert(db, .labelRuleForgotten, at: now, actor: .user, summary: "Forgot: \(rule.summary)",
                                    payload: LabelActionOutcome(rule: rule, documents: []))
            return LabelActionOutcome(rule: rule, documents: [])
        }
    }

    /// The label as a label of its kind keeps it (`DocumentLabel.normalized`): what a label is merged into.
    static func normalized(_ label: DocumentLabel) throws -> DocumentLabel {
        guard let normalized = DocumentLabel.normalized(label.value, kind: label.kind) else {
            throw LabelError.notALabel(label.kind, DocumentLabel.oneLine(label.value))
        }
        return normalized
    }

    /// The label a decision is about: as a label of its kind keeps it, or else as documents have it, written so: one an
    /// earlier reading gave in a form its kind no longer keeps can still be merged away, removed everywhere or kept
    /// apart. Read in the transaction the decision is made in.
    private static func named(_ db: Database, _ label: DocumentLabel) throws -> DocumentLabel {
        if let normalized = DocumentLabel.normalized(label.value, kind: label.kind) { return normalized }
        let written = DocumentLabel.oneLine(label.value)
        let given = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM documents d, json_each(d.labels_json) l
            WHERE d.labels_json IS NOT NULL AND json_extract(l.value, '$.kind') = ? AND json_extract(l.value, '$.value') = ?)
            """, arguments: [label.kind.rawValue, written]) ?? false
        guard given else { throw LabelError.notALabel(label.kind, written) }
        return DocumentLabel(kind: label.kind, value: written)
    }

    /// Writes `label`, written however, as `value` on every document that has it, or takes it off when `value` is nil.
    /// A document not labelled yet stays so. Returns the documents changed, in order.
    private static func relabel(_ db: Database, _ label: DocumentLabel, to value: String?, at now: Date) throws -> [Int64] {
        var changed: [Int64] = []
        let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT d.id AS id, d.labels_json AS labels, d.tags_only AS tags_only FROM documents d, json_each(d.labels_json) l
            WHERE d.labels_json IS NOT NULL AND json_extract(l.value, '$.kind') = ? ORDER BY d.id
            """, arguments: [label.kind.rawValue])
        for row in rows {
            guard let id: Int64 = row["id"], let labels = JSON.decode([DocumentLabel].self, from: row["labels"]) else { continue }
            let updated = labels.compactMap { existing -> DocumentLabel? in
                guard existing.kind == label.kind, LabelSimilarity.sameWriting(existing.value, label.value) else { return existing }
                return value.map { DocumentLabel(kind: existing.kind, value: $0) }
            }.distinct()
            guard updated != labels else { continue }
            try IndexStore.saveLabels(db, updated, docID: id, labelled: !(row["tags_only"] as Bool? ?? false), at: now)
            changed.append(id)
        }
        return changed
    }

    private static func onDocuments(_ documents: [Int64], taken: Bool = false) -> String {
        documents.isEmpty ? "" : (taken ? " and took it off " : " on ") + Format.count(documents.count, "document")
    }
}
