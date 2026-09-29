import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

public struct PredicateEvaluation: Sendable, Codable, Hashable {
    public var predicate: String
    public var matched: Bool
}

public struct RuleEvaluation: Sendable, Codable, Hashable {
    public var ruleID: Int64
    public var name: String
    public var matched: Bool
    public var predicates: [PredicateEvaluation]
}

public struct RuleHit: Sendable, Codable, Hashable {
    public var rule: FilingRule
    public var evaluations: [RuleEvaluation]
}

/// Deterministic, user-editable filing rules evaluated before the model (and, for document-type rules, after it).
public struct RuleEngine: Sendable {
    public let rules: [FilingRule]
    /// Senders' names by id, so the trace says which sender a condition is about.
    public let senderNames: [Int64: String]
    public let ruleMinimumStrength: Double
    public let textScanChars: Int

    public init(rules: [FilingRule], senders: [Correspondent], config: ClassificationConfig) {
        self.rules = rules.filter(\.enabled).sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) }
        senderNames = Correspondent.names(senders)
        ruleMinimumStrength = config.correspondentStrength.ruleMinimum
        textScanChars = config.ruleTextScanChars
    }

    /// All rules, with document-type conditions checked against the deterministic guess (nil = unknown, never matches).
    public func evaluateBeforeModel(_ content: ExtractedContent, matches: [CorrespondentMatch],
                                    detectedType: DocumentType?) -> (RuleHit?, [RuleEvaluation]) {
        evaluate(rules, content: content, matches: matches, documentType: detectedType)
    }

    /// Rules with document-type conditions, re-checked with the model's document type.
    public func evaluateAfterModel(_ content: ExtractedContent, matches: [CorrespondentMatch],
                                   documentType: DocumentType) -> (RuleHit?, [RuleEvaluation]) {
        evaluate(rules.filter(\.isPostLLM), content: content, matches: matches, documentType: documentType)
    }

    private func evaluate(_ candidates: [FilingRule], content: ExtractedContent, matches: [CorrespondentMatch],
                          documentType: DocumentType?) -> (RuleHit?, [RuleEvaluation]) {
        var evaluations: [RuleEvaluation] = []
        var hit: RuleHit?
        for rule in candidates {
            let preds = rule.predicates.map { p in
                PredicateEvaluation(predicate: p.summary(sender: { senderNames[$0] }), matched: holds(p, content: content, matches: matches, documentType: documentType))
            }
            let matched = !preds.isEmpty && preds.allSatisfy(\.matched)
            evaluations.append(RuleEvaluation(ruleID: rule.id, name: rule.name, matched: matched, predicates: preds))
            if matched && hit == nil { hit = RuleHit(rule: rule, evaluations: []) }
        }
        if var h = hit { h.evaluations = evaluations; hit = h }
        return (hit, evaluations)
    }

    private func holds(_ p: RulePredicate, content: ExtractedContent, matches: [CorrespondentMatch], documentType: DocumentType?) -> Bool {
        switch p {
        case let .correspondent(id):
            return matches.contains { $0.correspondent.id == id && $0.strength >= ruleMinimumStrength }
        case let .stableKey(token):
            return content.entities.stableKeys.contains { $0.token == token }
        case let .textRegex(pattern):
            let text = content.source.originalFilename + "\n" + String(content.text.prefix(textScanChars))
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        case let .filenameGlob(glob):
            return fnmatch(glob, content.source.originalFilename, FNM_CASEFOLD) == 0
        case let .utType(identifier):
            guard let a = UTType(content.source.utType), let b = UTType(identifier) else { return false }
            return a.conforms(to: b)
        case let .emailSenderDomain(domain):
            guard let from = content.metadata["email:from"], let d = CorrespondentResolver.domain(ofEmail: from) else { return false }
            return d == domain.lowercased() || d.hasSuffix("." + domain.lowercased())
        case let .whereFromDomain(domain):
            return content.source.whereFroms.contains { url in
                guard let host = URL(string: url)?.host()?.lowercased() else { return false }
                return host == domain.lowercased() || host.hasSuffix("." + domain.lowercased())
            }
        case let .language(lang):
            return content.language.primary == lang
        case let .documentType(type):
            return documentType == type
        }
    }
}
