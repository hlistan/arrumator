import Foundation
import GRDB

public enum LabelError: Error, LocalizedError, Equatable {
    case notALabel(LabelKind, String)
    case sameLabel(LabelKind, String)
    case ruleNotFound(Int64)
    /// Only a tag, the user's own, is added without a document: the model gives every other kind.
    case notAddable(LabelKind)
    /// The tag to add is one the archive already has, on a document or added before.
    case alreadyThere(LabelKind, String)

    public var errorDescription: String? {
        switch self {
        case let .notALabel(kind, value): "“\(value)” is no label of its kind: \(Self.form(of: kind))"
        case let .sameLabel(_, value): "“\(value)” is the same label either way"
        case let .ruleNotFound(id): "There is no rule \(id) about labels"
        case .notAddable: "Only a tag of your own is added so: the model gives every other kind of label as it reads"
        case let .alreadyThere(_, value): "“\(value)” is a tag already"
        }
    }

    /// Why `label` is no label of its kind, as `DocumentLabel.normalized` keeps one, or nil when it is one: what the app
    /// says as a label is typed, and what a correction of a document's labels and a decision about labels refuse.
    public static func refusal(of label: DocumentLabel) -> LabelError? {
        DocumentLabel.normalized(label.value, kind: label.kind) == nil ? .notALabel(label.kind, DocumentLabel.oneLine(label.value)) : nil
    }

    /// Why `label` cannot be merged into, or renamed, `value`, or nil when it can: what the app says as the new writing is
    /// typed, by the rule `LabelActions.merge` and `rename` apply. `value` is a label of the kind (`refusal(of:)`), and
    /// written otherwise than `label` as a label of its kind keeps it, case aside: a new case is a new writing.
    public static func refusal(ofMerging label: DocumentLabel, into value: String) -> LabelError? {
        let target = DocumentLabel(kind: label.kind, value: value)
        if let refused = refusal(of: target) { return refused }
        let from = DocumentLabel.normalized(label.value, kind: label.kind) ?? DocumentLabel(kind: label.kind, value: DocumentLabel.oneLine(label.value))
        return DocumentLabel.normalized(value, kind: label.kind)?.value == from.value ? .sameLabel(label.kind, from.value) : nil
    }

    /// Why `label` cannot be added as a tag among `inUse`, the archive's tags (`LabelStore.listing()`), or nil when it
    /// can: what the app says as it is typed, by the rule `LabelActions.add` applies.
    public static func refusal(ofAdding label: DocumentLabel, among inUse: [String]) -> LabelError? {
        guard label.kind.isUsersOwn else { return .notAddable(label.kind) }
        if let refused = refusal(of: label) { return refused }
        guard let tag = DocumentLabel.normalized(label.value, kind: label.kind),
              !inUse.contains(where: { LabelSimilarity.sameWriting($0, tag.value) }) else {
            return .alreadyThere(label.kind, DocumentLabel.oneLine(label.value))
        }
        return nil
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

/// What a decision about a label did: the rule it made or forgot, if any (a tag added is forgotten when it is removed),
/// and the documents whose labels it changed.
public struct LabelActionOutcome: Sendable, Codable, Hashable {
    public var rule: LabelRule?
    public var documents: [Int64]
}

/// What the user, or the model for labels that look alike, decides about a label for the whole archive: merge it into
/// another or rename it, stop wanting it, take it off every document, keep two alike ones apart, add a tag of the
/// user's own, or forget such a decision. Each but taking a label off becomes a rule every reading from then on follows
/// (`LabelConsolidator`, `LabelGuidance`), and each changes every document it concerns now, in one transaction with its
/// History event.
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
            try Self.merge(db, try Self.named(db, label), into: into, at: now, said: .merged, actor: .user)
        }
    }

    /// Writes `label` as `value` from now on: a merge into a writing of the user's choosing, which History says is a
    /// rename. Into a label in use, it is that label's documents' too, as a merge is.
    @discardableResult
    public func rename(_ label: DocumentLabel, to value: String) async throws -> LabelActionOutcome {
        let into = try Self.normalized(DocumentLabel(kind: label.kind, value: value))
        let now = time.now()
        return try await database.writer.write { db in
            try Self.merge(db, try Self.named(db, label), into: into, at: now, said: .renamed, actor: .user)
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

    /// Takes `label`, written however, off every document, as a correction of each: no rule is made, so a reading may
    /// give it again, which `ignore` stops. A tag the user added goes with it, its rule the one the outcome gives. Taking off a label no document has, and
    /// that was not added, changes nothing and records nothing.
    @discardableResult
    public func remove(_ label: DocumentLabel) async throws -> LabelActionOutcome {
        let now = time.now()
        return try await database.writer.write { db in
            let removed = try Self.named(db, label)
            let added = try LabelRule.fetchAll(db).filter { $0.action == .add && $0.concerns(removed) }
            for rule in added { _ = try rule.delete(db) }
            let documents = try Self.relabel(db, removed, to: nil, at: now)
            let outcome = LabelActionOutcome(rule: added.first, documents: documents)
            guard !documents.isEmpty || !added.isEmpty else { return outcome }
            try HistoryStore.insert(db, .labelRemoved, at: now, actor: .user,
                                    summary: "Removed \(removed.kind.rawValue) “\(removed.value)”"
                                        + (documents.isEmpty ? "" : " from " + Format.count(documents.count, "document")),
                                    payload: outcome)
            return outcome
        }
    }

    /// Adds `label`, a tag of the user's own, to the archive's labels, whether or not a document has it, so a card offers
    /// it (`LabelStore.listing()`). Refused for any other kind, which the model gives (`LabelError.notAddable`), and for
    /// a tag the archive has (`LabelError.alreadyThere`), decided in the transaction that adds it. A tag the user did not
    /// want is wanted again.
    @discardableResult
    public func add(_ label: DocumentLabel) async throws -> LabelActionOutcome {
        guard label.kind.isUsersOwn else { throw LabelError.notAddable(label.kind) }
        let tag = try Self.normalized(label)
        let now = time.now()
        return try await database.writer.write { db in
            let rules = try LabelRule.fetchAll(db)
            let inUse = try String.fetchAll(db, sql: "SELECT DISTINCT value FROM document_labels WHERE kind = ?", arguments: [tag.kind.rawValue])
                + rules.filter { $0.action == .add && $0.kind == tag.kind }.map(\.value)
            if let refused = LabelError.refusal(ofAdding: tag, among: inUse) { throw refused }
            for rule in rules where rule.action == .ignore && rule.concerns(tag) { _ = try rule.delete(db) }
            var rule = LabelRule(kind: tag.kind, value: tag.value, action: .add, target: nil, createdAt: now)
            try rule.insert(db)
            let outcome = LabelActionOutcome(rule: rule, documents: [])
            try HistoryStore.insert(db, .labelAdded, at: now, actor: .user, summary: "Added \(tag.kind.rawValue) “\(tag.value)”", payload: outcome)
            return outcome
        }
    }

    /// Keeps `label` and `other` apart: they mean different things, however alike they are written.
    @discardableResult
    public func keepApart(_ label: DocumentLabel, from other: String) async throws -> LabelActionOutcome {
        let now = time.now()
        return try await database.writer.write { db in
            let (a, b) = (try Self.named(db, label), try Self.named(db, DocumentLabel(kind: label.kind, value: other)))
            return try Self.keepApart(db, a, b, at: now, actor: .user, because: nil)
        }
    }

    /// Acts on what the model judged of two labels that look alike, as `suggestion` found them: the same, they are merged
    /// into the one more documents have, the suggestion's `into` when as many have each; different, they are kept apart.
    /// Either is recorded as the system's, with the trace of the judgement, and is a rule the user can forget. Decided in
    /// the transaction that acts: nothing is done, and nil returned, when either label is no longer on any document, or a
    /// rule of the user's already decides either label, as the user merged, removed for good or kept apart one meanwhile.
    @discardableResult
    public func decide(_ suggestion: LabelSuggestion, _ judgement: LabelJudgement, trace: Int64?) async throws -> LabelActionOutcome? {
        let now = time.now()
        return try await database.writer.write { db in
            let (a, b) = (DocumentLabel(kind: suggestion.kind, value: suggestion.value), DocumentLabel(kind: suggestion.kind, value: suggestion.into))
            guard let (forA, forB) = try Self.undecided(db, suggestion) else { return nil }
            switch judgement {
            case .same:
                let (from, into) = forA > forB ? (b, a) : (a, b)
                return try Self.merge(db, from, into: into, at: now, said: .judgedSame, actor: .system, trace: trace)
            case .different:
                return try Self.keepApart(db, a, b, at: now, actor: .system, because: Self.judgedDifferent, trace: trace)
            }
        }
    }

    /// Whether `suggestion` is still to be judged, as `decide` would act on it: both labels on documents, and no rule
    /// deciding either.
    public func isUndecided(_ suggestion: LabelSuggestion) async throws -> Bool {
        try await database.reader.read { db in try Self.undecided(db, suggestion) != nil }
    }

    /// How many documents have each label of `suggestion`, in the transaction of `db`, while it is still to be judged; nil
    /// when either is on no document, or a rule already decides either (`decide`).
    static func undecided(_ db: Database, _ suggestion: LabelSuggestion) throws -> (Int, Int)? {
        let (a, b) = (DocumentLabel(kind: suggestion.kind, value: suggestion.value), DocumentLabel(kind: suggestion.kind, value: suggestion.into))
        let count = { (label: DocumentLabel) in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_labels WHERE kind = ? AND value = ?",
                             arguments: [label.kind.rawValue, label.value]) ?? 0
        }
        let (forA, forB) = (try count(a), try count(b))
        guard forA > 0, forB > 0, try !LabelRule.fetchAll(db).contains(where: { $0.decides(a, b) }) else { return nil }
        return (forA, forB)
    }

    /// Forgets a rule: readings from now on no longer follow it. Documents it already changed keep their labels. A tag the
    /// user added, forgotten, is no longer listed once no document has it.
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

    /// How History says a merge was made.
    private enum Said {
        case merged, renamed, judgedSame
    }

    /// Why the model's judgement of two labels that look alike was acted on, as History says it.
    private static let judgedSame = ", which the model judged the same"
    private static let judgedDifferent = ", which the model judged different"

    /// Merges `from` into `into` in the transaction of `db`: the rules it ends go, labels merged into `from` follow it,
    /// and a tag the user added of it is added of `into`, so it stays listed; then every document is relabelled, and the
    /// merge recorded in History. A merge made already, which changes no rule and no document, is undone and recorded
    /// nowhere: the rule there is the outcome's.
    private static func merge(_ db: Database, _ from: DocumentLabel, into: DocumentLabel, at now: Date, said: Said, actor: EventActor,
                              trace: Int64? = nil) throws -> LabelActionOutcome {
        if let refused = LabelError.refusal(ofMerging: from, into: into.value) { throw refused }
        var outcome: LabelActionOutcome?
        try db.inSavepoint {
            let before = try LabelRule.fetchAll(db)
            let made = try merging(db, from, into: into, at: now, rules: before)
            if made.documents.isEmpty, let there = before.first(where: { $0.isMerge(of: from, into: into) }),
               try decided(LabelRule.fetchAll(db)) == decided(before) {
                outcome = LabelActionOutcome(rule: there, documents: [])
                return .rollback
            }
            let what = "\(from.kind.rawValue) “\(from.value)”"
            let summary = switch said {
            case .merged: "Merged \(what) into “\(into.value)”" + onDocuments(made.documents)
            case .renamed: "Renamed \(what) to “\(into.value)”" + onDocuments(made.documents)
            case .judgedSame: "Merged \(what) into “\(into.value)”" + onDocuments(made.documents) + judgedSame
            }
            try HistoryStore.insert(db, .labelsMerged, at: now, actor: actor, trace: trace, summary: summary, payload: made)
            outcome = made
            return .commit
        }
        return outcome ?? LabelActionOutcome(rule: nil, documents: [])
    }

    /// What `rules` decide, whenever each was made: each one's kind, label, action and target, in order.
    private static func decided(_ rules: [LabelRule]) -> [[String]] {
        rules.map { [$0.kind.rawValue, $0.value, $0.action.rawValue, $0.target ?? ""] }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// The rules and documents of a merge of `from` into `into`, made in the transaction of `db`, whose rules were
    /// `rules`; what History is to say aside.
    private static func merging(_ db: Database, _ from: DocumentLabel, into: DocumentLabel, at now: Date, rules: [LabelRule]) throws
        -> LabelActionOutcome {
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
        if over.contains(where: { $0.action == .add }), !rules.contains(where: { $0.action == .add && $0.concerns(into) }) {
            var added = LabelRule(kind: into.kind, value: into.value, action: .add, target: nil, createdAt: now)
            try added.insert(db)
        }
        var rule = LabelRule(kind: from.kind, value: from.value, action: .merge, target: into.value, createdAt: now)
        try rule.insert(db)
        return LabelActionOutcome(rule: rule, documents: try relabel(db, from, to: into.value, at: now))
    }

    /// Keeps `a` and `b` apart in the transaction of `db`: a merge between them is over, and the rule is made once. Kept
    /// apart already, with no merge between them to end, nothing changes and nothing is recorded.
    private static func keepApart(_ db: Database, _ a: DocumentLabel, _ b: DocumentLabel, at now: Date, actor: EventActor, because: String?,
                                  trace: Int64? = nil) throws -> LabelActionOutcome {
        guard !LabelSimilarity.sameWriting(a.value, b.value) else { throw LabelError.sameLabel(a.kind, a.value) }
        var ended = false
        for rule in try LabelRule.fetchAll(db) where rule.action == .merge
            && ((rule.concerns(a) && rule.target.map { LabelSimilarity.sameWriting($0, b.value) } == true)
                || (rule.concerns(b) && rule.target.map { LabelSimilarity.sameWriting($0, a.value) } == true)) {
            _ = try rule.delete(db)
            ended = true
        }
        let there = try LabelRule.fetchAll(db).first { $0.keepsApart(a.value, b.value, kind: a.kind) }
        if let there, !ended { return LabelActionOutcome(rule: there, documents: []) }
        var rule = there ?? LabelRule(kind: a.kind, value: a.value, action: .keepApart, target: b.value, createdAt: now)
        if rule.id == nil { try rule.insert(db) }
        let outcome = LabelActionOutcome(rule: rule, documents: [])
        try HistoryStore.insert(db, .labelsKeptApart, at: now, actor: actor, trace: trace,
                                summary: "Kept \(a.kind.rawValue) “\(a.value)” and “\(b.value)” apart" + (because ?? ""), payload: outcome)
        return outcome
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
