import Foundation
import NaturalLanguage

/// What the user decided about a label, for every document and for every one the model reads from then on.
public enum LabelRuleAction: String, Sendable, Codable, CaseIterable {
    /// The label is written as its target instead: two labels that mean the same became one.
    case merge
    /// The label is not wanted: it was taken off every document, and the model's answers lose it.
    case ignore
    /// The label and its target mean different things, however alike they are written: never merged, never suggested.
    case keepApart
    /// A tag the user added: listed among the archive's labels and offered on a card, whether or not a document has it.
    /// Only a tag, the user's own, is added so; the model gives every other kind.
    case add

    /// Whether the rule decides how a reading writes its label: merged into another, or dropped.
    public var rewrites: Bool { self == .merge || self == .ignore }
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

    /// The words of `text` in their order, each folded as `searchKey` folds it, as NaturalLanguage tells them apart in
    /// every script: those written without spaces between words (Chinese, Japanese, Thai) too, in which a split at
    /// spaces would find a whole sentence one word (AGENTS.md §4.5). A word that holds punctuation ("1.4.2025",
    /// "e-mail") is split at it, as `searchKey` splits it, so a word of a text is a word of its key.
    public static func searchWords(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).flatMap { searchKey(String(text[$0])).split(separator: " ").map(String.init) }
    }
}

/// Two labels of one kind that look alike enough to be one, waiting for the model to judge them one, and merge them, or
/// two, and keep them apart (`LabelJudge`). `into` is the one more documents have, which a merge keeps.
public struct LabelSuggestion: Sendable, Codable, Hashable, Identifiable {
    /// Why two labels look alike, and are judged.
    public enum Reason: String, Sendable, Codable, Hashable {
        /// They are written alike enough (`KindVocabularyConfig.suggestSimilarity`).
        case writtenAlike
        /// They hold the same digits in the same order, which punctuation groups otherwise
        /// (`LabelSimilarity.Key.isRegrouping(of:)`): perhaps one number written two ways, which only reading them can tell,
        /// so they are judged whatever the kind's thresholds, and never merged as written alike.
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
    /// The pair whichever way it is written: which label is `value` follows which more documents have, and so may turn as
    /// documents are filed.
    public var pairID: String { "\(kind.rawValue):" + [value, into].sorted().joined(separator: "\u{1F}") }

    public init(kind: LabelKind, value: String, into: String, similarity: Double, reason: Reason) {
        self.kind = kind
        self.value = value
        self.into = into
        self.similarity = similarity
        self.reason = reason
    }
}

/// What the model judged of two labels that look alike (`LabelPairJudging`): one label written two ways, or two.
public enum LabelJudgement: String, Sendable, Codable, Hashable, CaseIterable {
    case same, different
}

/// What each of two labels that look alike is used for: how many documents have it, and the names of the newest of them
/// (`labels.vocabulary.judgeDocuments` of each), as the model is shown them when it judges the pair.
public struct LabelPairUse: Sendable, Codable, Hashable {
    /// How many documents have the suggestion's `value`, and the names of the newest.
    public var valueDocuments: Int
    public var valueNames: [String]
    /// How many documents have the suggestion's `into`, and the names of the newest.
    public var intoDocuments: Int
    public var intoNames: [String]

    public init(valueDocuments: Int, valueNames: [String], intoDocuments: Int, intoNames: [String]) {
        self.valueDocuments = valueDocuments
        self.valueNames = valueNames
        self.intoDocuments = intoDocuments
        self.intoNames = intoNames
    }
}

/// What the model judged of two labels that look alike, why in its own words, and which model judged; without a valid
/// answer, no judgement, and why there is none.
public struct LabelVerdict: Sendable, Codable, Hashable {
    public var judgement: LabelJudgement?
    public var reason: String?
    public var model: String?
    public var problem: String?

    public init(judgement: LabelJudgement?, reason: String?, model: String?, problem: String?) {
        self.judgement = judgement
        self.reason = reason
        self.model = model
        self.problem = problem
    }
}

/// Judges whether two labels of one kind that look alike (`LabelSuggestion`) are one label written two ways or two, so
/// the archive's labels are kept one vocabulary without asking the user (`LabelJudge`). Implemented by
/// `ArrumatorClassify.LabelPairJudge`.
public protocol LabelPairJudging: Sendable {
    /// The chat model of `profile` judges `pair`, shown what each label is used for (`use`). Without a valid answer the
    /// verdict has no judgement and says why; a model that cannot be reached or is missing throws, so the pair waits.
    func judge(_ pair: LabelSuggestion, use: LabelPairUse, profile: ModelProfile, config: PipelineConfig,
               trace: TraceContext) async throws -> LabelVerdict
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
    /// Every label the user merged into another, newest first: a name the document writes may be written as any of them
    /// (`ReadingGrounds`), and the prompt shows the newest `labels.vocabulary.promptPreferred`.
    public var preferred: [LabelPreference]
    /// Every label the user does not want, newest first, of which the prompt shows the newest
    /// `labels.vocabulary.promptUnwanted`.
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
