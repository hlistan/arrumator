import Foundation

/// What the user decided about a label, for every document and for every one the model reads from then on.
public enum LabelRuleAction: String, Sendable, Codable, CaseIterable {
    /// The label is written as its target instead: two labels that mean the same became one.
    case merge
    /// The label is not wanted: it was taken off every document, and the model's answers lose it.
    case ignore
    /// The label and its target mean different things, however alike they are written: never merged, never suggested.
    case keepApart
}

/// A label as the archive uses it: how many documents have it.
public struct LabelUsage: Sendable, Codable, Hashable {
    public var label: DocumentLabel
    public var documents: Int

    public init(label: DocumentLabel, documents: Int) {
        self.label = label
        self.documents = documents
    }
}

/// The labels in use, kind by kind, each kind's most used first, as `LabelStore.usage(within:)` gives them: how the
/// app's sidebar and `arrumatorcli labels browse` list them.
extension [LabelKind: [LabelUsage]] {
    /// The labels whose writing has `text` in it, kinds without one dropped. Case, accents and punctuation do not
    /// matter, and a language is found by its English name too, as search finds it. Blank text keeps every label.
    public func matching(_ text: String) -> Self {
        let wanted = LabelUsage.searchKey(text)
        guard !wanted.isEmpty else { return self }
        return compactMapValues { usage in
            let matched = usage.filter { LabelUsage.searchKey(DocumentLabel.searchText([$0.label], kind: $0.label.kind)).contains(wanted) }
            return matched.isEmpty ? nil : matched
        }
    }

    /// Every label in one list, the most used first. Labels as used keep the order of their kinds, then their own.
    public func ranked() -> [LabelUsage] {
        LabelKind.allCases.flatMap { self[$0] ?? [] }.enumerated()
            .sorted { $0.element.documents != $1.element.documents ? $0.element.documents > $1.element.documents : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Every label, kind by kind when `groupedByKind` (`AppSettings.groupLabelsByKind`), else `ranked()`.
    public func listed(groupedByKind: Bool) -> [LabelUsage] {
        groupedByKind ? LabelKind.allCases.flatMap { self[$0] ?? [] } : ranked()
    }
}

extension LabelUsage {
    /// `text` folded for matching: lowercase, without accents, and with every run of anything but letters and digits one
    /// space, so `tax return` finds `tax-return` and `edp comercial` finds `EDP-Comercial, S.A.`.
    public static func searchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !($0.isLetter || $0.isNumber) }.joined(separator: " ")
    }
}

/// Two labels of one kind that look alike enough to be one, waiting for the user to merge them or keep them apart.
/// `into` is the one more documents have, which a merge keeps.
public struct LabelSuggestion: Sendable, Codable, Hashable, Identifiable {
    /// Why two labels are offered to be merged.
    public enum Reason: String, Sendable, Codable, Hashable {
        /// They are written alike enough (`KindVocabularyConfig.suggestSimilarity`).
        case writtenAlike
        /// They hold the same digits in the same order, which punctuation groups otherwise
        /// (`LabelSimilarity.Key.isRegrouping(of:)`): perhaps one number written two ways, which only the user can tell,
        /// so they are offered whatever the kind's thresholds, and never merged on their own.
        case sameDigitsGroupedOtherwise
    }

    public var kind: LabelKind
    public var value: String
    public var into: String
    /// How alike they are written, from 0 to 1 (`LabelSimilarity`); for the same digits grouped otherwise, how alike
    /// they are written but for where their numbers end.
    public var similarity: Double
    public var reason: Reason

    public var id: String { "\(kind.rawValue):\(value)→\(into)" }

    public init(kind: LabelKind, value: String, into: String, similarity: Double, reason: Reason) {
        self.kind = kind
        self.value = value
        self.into = into
        self.similarity = similarity
        self.reason = reason
    }
}

/// Why a label the model gave was changed before it became the document's.
public enum LabelChangeReason: Sendable, Codable, Hashable {
    /// A rule of the user's, by its number.
    case rule(id: Int64)
    /// The archive already has the label written this way, or so alike (`LabelSimilarity`) that it is the same.
    case alike(similarity: Double)
}

/// One label the model gave that became another, or none.
public struct LabelChange: Sendable, Codable, Hashable {
    public var from: DocumentLabel
    /// Nil when the label was dropped.
    public var to: DocumentLabel?
    public var reason: LabelChangeReason

    public init(from: DocumentLabel, to: DocumentLabel?, reason: LabelChangeReason) {
        self.from = from
        self.to = to
        self.reason = reason
    }
}

/// The labels a reading keeps, and what was changed on the way.
public struct LabelConsolidation: Sendable, Codable, Hashable {
    public var labels: [DocumentLabel]
    public var changes: [LabelChange]

    public init(labels: [DocumentLabel], changes: [LabelChange]) {
        self.labels = labels
        self.changes = changes
    }
}

/// A label the user merged into another: how it was written, and how the user wants it written.
public struct LabelPreference: Sendable, Codable, Hashable {
    public var from: DocumentLabel
    public var to: String

    public init(from: DocumentLabel, to: String) {
        self.from = from
        self.to = to
    }
}

/// What the model is told of the archive when it reads a document: the labels the archive already uses, so it gives
/// the same one for the same thing, how the user corrected labels, and the labels the user does not want. It is how the
/// user's decisions teach the model, in its prompt, without retraining it.
public struct LabelGuidance: Sendable, Codable, Hashable {
    /// The labels in use, by kind, the most used first.
    public var used: [LabelKind: [String]]
    /// Labels the user merged into others, newest first.
    public var preferred: [LabelPreference]
    /// Labels the user does not want, newest first.
    public var unwanted: [DocumentLabel]

    public init(used: [LabelKind: [String]] = [:], preferred: [LabelPreference] = [], unwanted: [DocumentLabel] = []) {
        self.used = used
        self.preferred = preferred
        self.unwanted = unwanted
    }

    /// An archive that uses no label yet and has no rules.
    public static let none = LabelGuidance()

    public var isEmpty: Bool { used.values.allSatisfy(\.isEmpty) && preferred.isEmpty && unwanted.isEmpty }
}

extension LabelKind: CodingKeyRepresentable {}
