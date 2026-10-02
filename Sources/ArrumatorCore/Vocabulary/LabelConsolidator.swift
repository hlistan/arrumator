import Foundation

/// Keeps the archive's labels one vocabulary. Every label the model gives a document goes through the user's rules
/// first: a label the user merged is written as the user wants it, one the user does not want is dropped. Then a label
/// of a kind the configuration keeps consistent becomes the label the archive already uses when the two are written
/// alike enough (`KindVocabularyConfig.mergeSimilarity`, 1 for written the same way), unless the user kept them apart.
/// Labels that are alike, but not enough to be merged without asking, are offered to the user instead
/// (`suggestions()`). The user's own labels, tags, follow the user's rules alone (`ruled`): nothing merges them unasked.
public struct LabelConsolidator: Sendable {
    public let config: LabelVocabularyConfig
    public let rules: [LabelRule]
    /// The labels in use, by kind, the most used first.
    public let vocabulary: [LabelKind: [LabelUsage]]

    public init(config: LabelVocabularyConfig, rules: [LabelRule], vocabulary: [LabelKind: [LabelUsage]]) {
        self.config = config
        self.rules = rules
        self.vocabulary = vocabulary
    }

    public func consolidate(_ labels: [DocumentLabel]) -> LabelConsolidation {
        var changes: [LabelChange] = []
        var kept: [DocumentLabel] = []
        for label in labels {
            let (ruled, applied) = resolve(label)
            guard var current = ruled else {
                changes.append(LabelChange(from: label, to: nil, reason: .rule(id: applied.last ?? 0)))
                continue
            }
            if current != label, let rule = applied.last { changes.append(LabelChange(from: label, to: current, reason: .rule(id: rule))) }
            if applied.isEmpty, let (known, similarity) = alike(current) {
                current = known
                changes.append(LabelChange(from: label, to: current, reason: .alike(similarity: similarity)))
            }
            kept.append(current)
        }
        return LabelConsolidation(labels: kept.distinct(), changes: changes)
    }

    /// The user's own labels, tags, as the user's rules write them, each once: merged or dropped as a rule says, and
    /// never made another label because one in use is written alike, as the model's are. They are the user's words.
    public func ruled(_ tags: [DocumentLabel]) -> LabelConsolidation {
        var changes: [LabelChange] = []
        let kept = tags.compactMap { tag -> DocumentLabel? in
            let (ruled, applied) = resolve(tag)
            if ruled != tag, let rule = applied.last { changes.append(LabelChange(from: tag, to: ruled, reason: .rule(id: rule))) }
            return ruled
        }
        return LabelConsolidation(labels: kept.distinct(), changes: changes)
    }

    /// The label as the user's rules have it, following one merge into the next, and the rules applied; nil when a rule
    /// drops it.
    func resolve(_ label: DocumentLabel) -> (DocumentLabel?, [Int64]) {
        var current = label
        var applied: [Int64] = []
        while let rule = rules.first(where: { $0.action != .keepApart && $0.concerns(current) && !applied.contains($0.id ?? 0) }) {
            applied.append(rule.id ?? 0)
            switch rule.action {
            case .ignore: return (nil, applied)
            case .merge: current.value = rule.target ?? current.value
            case .keepApart: break
            }
        }
        return (current, applied)
    }

    /// The label in use most like `label` and alike enough to be it, the most used of equals. A label the archive already
    /// uses stays itself, unless more documents have it written another way.
    private func alike(_ label: DocumentLabel) -> (DocumentLabel, Double)? {
        guard let policy = config.kinds[label.kind] else { return nil }
        let usages = vocabulary[label.kind] ?? []
        let own = usages.first { $0.label.value == label.value }?.documents
        let threshold = own == nil ? policy.mergeSimilarity : 1
        let key = LabelSimilarity.Key(label.value)
        var best: (label: DocumentLabel, similarity: Double)?
        for usage in usages where usage.label.value != label.value && usage.documents > (own ?? 0) {
            let other = LabelSimilarity.Key(usage.label.value)
            guard key.isSameWriting(as: other) || LabelSimilarity.bound(key, other) >= threshold else { continue }
            let similarity = LabelSimilarity.similarity(key, other)
            guard similarity >= threshold, similarity > (best?.similarity ?? 0),
                  !keptApart(label.value, usage.label.value, kind: label.kind) else { continue }
            best = (usage.label, similarity)
        }
        return best
    }

    private func keptApart(_ a: String, _ b: String, kind: LabelKind) -> Bool {
        rules.contains { $0.keepsApart(a, b, kind: kind) }
    }

    /// Pairs of labels in use that are alike enough to be one (`KindVocabularyConfig.suggestSimilarity`) and that the
    /// user has not kept apart, the most alike first, at most `suggestionLimit`. Each is to be merged into the one more
    /// documents have.
    public func suggestions() -> [LabelSuggestion] {
        var found: [LabelSuggestion] = []
        for kind in LabelKind.allCases {
            guard let policy = config.kinds[kind] else { continue }
            let usages = vocabulary[kind] ?? []
            let keys = usages.map { LabelSimilarity.Key($0.label.value) }
            for i in usages.indices {
                for j in usages.indices where j > i {
                    guard LabelSimilarity.bound(keys[i], keys[j]) >= policy.suggestSimilarity || keys[i].isSameWriting(as: keys[j]) else {
                        continue
                    }
                    let similarity = LabelSimilarity.similarity(keys[i], keys[j])
                    let (into, value) = (usages[i].label.value, usages[j].label.value)
                    guard similarity >= policy.suggestSimilarity, !keptApart(into, value, kind: kind) else { continue }
                    found.append(LabelSuggestion(kind: kind, value: value, into: into, similarity: similarity))
                }
            }
        }
        return Array(found.sorted { $0.similarity > $1.similarity }.prefix(config.suggestionLimit))
    }
}
