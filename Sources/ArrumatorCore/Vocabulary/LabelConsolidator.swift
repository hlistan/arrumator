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

    /// The label in use most like `label` and alike enough to be it, the most used of equals: never one 0 alike, as labels
    /// whose numbers differ are, the same digits grouped otherwise among them, whatever the threshold. A label the archive
    /// already uses stays itself, unless more documents have it written another way.
    private func alike(_ label: DocumentLabel) -> (DocumentLabel, Double)? {
        guard let policy = config.kinds[label.kind] else { return nil }
        let usages = vocabulary[label.kind] ?? []
        let own = usages.first { $0.label.value == label.value }?.documents
        let threshold = own == nil ? policy.mergeSimilarity : 1
        let key = LabelSimilarity.Key(label.value)
        var best: (label: DocumentLabel, similarity: Double)?
        for usage in usages where usage.label.value != label.value && usage.documents > (own ?? 0) {
            guard let similarity = LabelSimilarity.similarity(key, LabelSimilarity.Key(usage.label.value), atLeast: threshold),
                  similarity > (best?.similarity ?? 0), !keptApart(label.value, usage.label.value, kind: label.kind) else { continue }
            best = (usage.label, similarity)
        }
        return best
    }

    private func keptApart(_ a: String, _ b: String, kind: LabelKind) -> Bool {
        rules.contains { $0.keepsApart(a, b, kind: kind) }
    }

    /// Pairs of labels in use that the user has not kept apart and that are alike enough to be one
    /// (`KindVocabularyConfig.suggestSimilarity`), or that hold the same digits grouped otherwise, which every kind offers
    /// whatever its thresholds, each saying why (`LabelSuggestion.Reason`). The most alike come first, at most
    /// `suggestionLimit`; of pairs as alike, those written alike, then those of the kind listed first, then of the labels
    /// more documents have. Each is to be merged into the one more documents have.
    public func suggestions() -> [LabelSuggestion] {
        suggestions(alike: Dictionary(uniqueKeysWithValues: config.kinds.map { kind, policy in
            (kind, AlikeLabels(threshold: policy.suggestSimilarity).updated(to: labels(of: kind), comparing: LabelSimilarity.lookAlike(_:_:atLeast:)) {
                false
            })
        }))
    }

    /// `suggestions()`, which labels of each kind look alike brought up to date by `memo` from what it last worked out
    /// (`LookAlikeMemo.alike`), comparing labels with `comparing`. Throws `CancellationError` when stopped part way.
    func suggestions(by memo: LookAlikeMemo, comparing: @escaping AlikeLabels.Comparing) async throws -> [LabelSuggestion] {
        var alike: [LabelKind: AlikeLabels] = [:]
        for (kind, policy) in config.kinds {
            alike[kind] = try await memo.alike(kind, labels: labels(of: kind), threshold: policy.suggestSimilarity, comparing: comparing)
        }
        return suggestions(alike: alike)
    }

    /// The labels of `kind` in use.
    private func labels(of kind: LabelKind) -> [String] {
        (vocabulary[kind] ?? []).map(\.label.value)
    }

    /// `suggestions()`, with which labels of each kind look alike given by `alike`, a kind it does not name offering none.
    private func suggestions(alike: [LabelKind: AlikeLabels]) -> [LabelSuggestion] {
        var found: [(order: (reason: Int, kind: Int, first: Int, second: Int), suggestion: LabelSuggestion)] = []
        for (place, kind) in LabelKind.allCases.enumerated() {
            guard let pairs = alike[kind]?.pairs else { continue }
            let usages = vocabulary[kind] ?? []
            let rank = Dictionary(usages.enumerated().map { ($1.label.value, $0) }, uniquingKeysWith: min)
            for (pair, look) in pairs {
                guard let a = rank[pair.first], let b = rank[pair.second], !keptApart(pair.first, pair.second, kind: kind) else { continue }
                let (first, second) = (min(a, b), max(a, b))
                found.append(((look.reason == .writtenAlike ? 0 : 1, place, first, second),
                              LabelSuggestion(kind: kind, value: usages[second].label.value, into: usages[first].label.value,
                                              similarity: look.similarity, reason: look.reason)))
            }
        }
        let ordered = found.sorted { a, b in
            guard a.suggestion.similarity == b.suggestion.similarity else { return a.suggestion.similarity > b.suggestion.similarity }
            return (a.order.reason, a.order.kind, a.order.first, a.order.second) < (b.order.reason, b.order.kind, b.order.first, b.order.second)
        }
        return Array(ordered.prefix(config.suggestionLimit).map(\.suggestion))
    }
}
