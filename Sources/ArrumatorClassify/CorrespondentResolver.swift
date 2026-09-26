import ArrumatorCore
import Foundation

public enum CorrespondentMatchKind: String, Sendable, Codable, Hashable {
    case stableKey, emailDomain, webDomain, name
}

public struct CorrespondentMatch: Sendable, Codable, Hashable {
    public var correspondent: Correspondent
    public var matchedBy: CorrespondentMatchKind
    public var evidence: String
    public var strength: Double
}

/// Recognises correspondents the app has learned from earlier documents: identifiers first (IBAN, NIF, ИНН…
/// promoted after repeated filings), then e-mail/web domains, then names seen before.
public struct CorrespondentResolver: Sendable {
    public let correspondents: [Correspondent]
    public let strength: ClassificationConfig.CorrespondentStrength
    public let scanChars: Int
    public let companySuffixes: [String]
    /// Identifiers currently seen with more than one correspondent; they identify none of them.
    public let ambiguousKeys: Set<String>

    public init(correspondents: [Correspondent], config: ClassificationConfig, entities: EntityConfig,
                ambiguousKeys: Set<String> = []) {
        self.correspondents = correspondents
        self.ambiguousKeys = ambiguousKeys
        strength = config.correspondentStrength
        scanChars = config.correspondentScanChars
        companySuffixes = entities.companySuffixes
    }

    public func resolve(_ content: ExtractedContent) -> [CorrespondentMatch] {
        let raw = [content.source.stem, content.visual?.organisations.joined(separator: " ") ?? "",
                   content.metadata["email:from"] ?? "", String(content.text.prefix(scanChars))].joined(separator: "\n")
        let padded = TextNormalizer.padded(stripSuffixes(raw))
        let tokens = Set(content.entities.stableKeys.map(\.token)).subtracting(ambiguousKeys)
        let emailDomains = Set((content.entities.emails + [content.metadata["email:from"] ?? ""]).compactMap(Self.domain(ofEmail:)))
        let webHosts = Set((content.source.whereFroms + content.entities.urls).compactMap { URL(string: $0)?.host()?.lowercased() })
        var matches: [CorrespondentMatch] = []
        for c in correspondents {
            if let key = c.stableKeys.first(where: tokens.contains) {
                matches.append(CorrespondentMatch(correspondent: c, matchedBy: .stableKey, evidence: key, strength: strength.stableKey))
            } else if let d = c.emailDomains.first(where: { Self.matches(host: $0, in: emailDomains) }) {
                matches.append(CorrespondentMatch(correspondent: c, matchedBy: .emailDomain, evidence: d, strength: strength.domain))
            } else if let d = c.webDomains.first(where: { Self.matches(host: $0, in: webHosts) }) {
                matches.append(CorrespondentMatch(correspondent: c, matchedBy: .webDomain, evidence: d, strength: strength.domain))
            } else if let name = ([c.canonicalName] + c.aliases).first(where: { nameAppears($0, raw: raw, padded: padded) }) {
                matches.append(CorrespondentMatch(correspondent: c, matchedBy: .name, evidence: name, strength: strength.alias))
            }
        }
        return matches.sorted { ($0.strength, $0.correspondent.filedCount) > ($1.strength, $1.correspondent.filedCount) }
    }

    /// The known correspondent a free-text name (from the model or the user) refers to, if any.
    public func known(_ name: String) -> Correspondent? {
        let n = TextNormalizer.normalize(stripSuffixes(name))
        guard !n.isEmpty else { return nil }
        return correspondents.first { c in ([c.canonicalName] + c.aliases).contains { TextNormalizer.normalize(stripSuffixes($0)) == n } }
    }

    /// Whether `name` is `correspondent` written another way: one of its names begins with the other, legal forms aside
    /// ("EDP Comercial – Comercialização de Energia, S.A." and "EDP Comercial").
    public func resembles(_ name: String, _ correspondent: Correspondent) -> Bool {
        resembles(name, anyOf: [correspondent.canonicalName] + correspondent.aliases)
    }

    /// Whether `name` is one of `names` written another way, legal forms aside: one begins with the other, word for
    /// word. A name's distinctive part comes first, so a name that merely contains another ("Unilabs Portugal" and
    /// "Portugal") is not it.
    public func resembles(_ name: String, anyOf names: [String]) -> Bool {
        let n = TextNormalizer.normalize(stripSuffixes(name))
        guard !n.isEmpty else { return false }
        return names.contains { known in
            let k = TextNormalizer.normalize(stripSuffixes(known))
            return !k.isEmpty && (Self.begins(n, with: k) || Self.begins(k, with: n))
        }
    }

    static func begins(_ text: String, with start: String) -> Bool {
        guard text.hasPrefix(start) else { return false }
        return text.count == start.count || text.dropFirst(start.count).first == " "
    }

    private func nameAppears(_ name: String, raw: String, padded: String) -> Bool {
        let normalized = TextNormalizer.normalize(stripSuffixes(name))
        // Very short names are only trusted as exact, case-sensitive words.
        if normalized.count <= Self.shortNameLength { return TextNormalizer.containsExactWord(raw, name) }
        return padded.contains(" " + normalized + " ")
    }

    /// Names this short are matched case-sensitively to avoid hits on ordinary words.
    static let shortNameLength = 4

    private func stripSuffixes(_ s: String) -> String {
        var out = s
        for suffix in companySuffixes {
            out = out.replacingOccurrences(of: "(?<![\\p{L}])\(NSRegularExpression.escapedPattern(for: suffix))(?![\\p{L}])",
                                           with: " ", options: .regularExpression)
        }
        return out
    }

    static func matches(host: String, in hosts: Set<String>) -> Bool {
        hosts.contains { $0 == host || $0.hasSuffix("." + host) }
    }

    static func domain(ofEmail s: String) -> String? {
        guard let at = s.lastIndex(of: "@") else { return nil }
        let d = s[s.index(after: at)...].trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'")).lowercased()
        return d.isEmpty ? nil : d
    }
}
