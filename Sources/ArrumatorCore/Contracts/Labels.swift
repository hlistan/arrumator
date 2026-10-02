import Foundation

/// The kinds of label a document is described by, and all it is described by: the local model picks each out of the
/// document but the last, the user's own `tag`, and the document is found by them, however the archive is arranged. The
/// set follows the metadata archival description keeps for a record (DCMI Metadata Terms, ISO 23081's agents), the facets
/// of faceted classification (Ranganathan's personality, matter, energy, space and time) and the fields document managers
/// and key-information extraction read from personal paperwork; a tag is a label its owner gives, as the tags of a
/// personal collection are; docs/organizing-principles-sources.md#sources-for-labels.
public enum LabelKind: String, Sendable, Codable, CaseIterable {
    /// Who issued or sent the document.
    case sender
    /// Another person or organisation the document concerns: whom it is addressed to, whose it is, whom it is about.
    case party
    /// The form of the document, one of `DocumentType`.
    case type
    /// A subject area it belongs to, in a few lowercase English words: "electricity", "income tax".
    case topic
    /// A specific thing it concerns, with what identifies it: a property, vehicle, account, supply point, policy.
    case object
    /// A number that identifies the document or the case it belongs to: an invoice, contract, case or customer number.
    case reference
    /// When it was issued, `YYYY-MM-DD`.
    case date
    /// The period it covers: `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, or two of them as `start/end`.
    case period
    /// A date by which something must be done, or on which it stops being valid, `YYYY-MM-DD`.
    case deadline
    /// A total it asks for or records, as a number and an ISO 4217 currency: "54.21 EUR".
    case amount
    /// A country, region or other jurisdiction whose law, authority or administration it falls under.
    case jurisdiction
    /// A language it is written in, as an ISO 639-1 code.
    case language
    /// The user's own label, as the user writes it: the name of the folder in Incoming the document was put in
    /// (`IncomingFolders`), or one given by hand. The model is never asked for one and never gives one.
    case tag

    /// A kind a document has at most one label of.
    public var isSingle: Bool { self == .type || self == .date }

    /// Whether labels of the kind are the user's own, never the model's: a tag.
    public var isUsersOwn: Bool { self == .tag }

    /// The kinds the model reads a document and a search request for, in their order: every kind but the user's own.
    public static let modelKinds = allCases.filter { !$0.isUsersOwn }
}

/// One label of a document: a signal of `kind` the model found in it, as `value`.
public struct DocumentLabel: Sendable, Codable, Hashable {
    public var kind: LabelKind
    public var value: String

    public init(kind: LabelKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

extension [DocumentLabel] {
    /// The values of the labels of `kind`, in order.
    public func values(_ kind: LabelKind) -> [String] { filter { $0.kind == kind }.map(\.value) }

    /// Each label once, however its value is cased or accented, and the first of a single-valued kind.
    public func distinct() -> [DocumentLabel] {
        var seen = Set<String>()
        var kinds = Set<LabelKind>()
        return filter { label in
            let key = label.kind.rawValue + ":" + label.value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard seen.insert(key).inserted else { return false }
            return !label.kind.isSingle || kinds.insert(label.kind).inserted
        }
    }
}

extension DocumentLabel {
    /// ISO 639-1 codes are two letters.
    public static let languageCodeLength = 2

    /// A label of `kind` with `value` as a label keeps it, or nil when it is none. Every value is one line. A date or
    /// deadline is ISO 8601 (`YYYY-MM-DD`, from day-first dates too), a period one or two ISO dates of any precision
    /// joined by `/`, a language its ISO 639-1 code, a type one of `DocumentType` other than `other`, an amount and a
    /// reference have a number in them (an amount with its ISO 4217 code before or after it is written `number CODE`),
    /// and a topic is lowercase. A tag is kept as written.
    public static func normalized(_ value: String, kind: LabelKind) -> DocumentLabel? {
        let written = oneLine(value)
        guard !written.isEmpty else { return nil }
        let normalized: String? = switch kind {
        case .language: languageCode(written)
        case .type: DocumentType(rawValue: written.lowercased().replacingOccurrences(of: " ", with: "-"))
            .flatMap { $0 == .other ? nil : $0.rawValue }
        case .date, .deadline: isoDay(written)
        case .period: period(written)
        case .amount: amount(written)
        case .reference: written.contains(where: \.isNumber) ? written : nil
        case .topic: written.lowercased()
        case .sender, .party, .object, .jurisdiction, .tag: written
        }
        return normalized.map { DocumentLabel(kind: kind, value: $0) }
    }

    /// An amount as `number CODE` when it is a number and an ISO 4217 code in either order (`EUR 54.21`, `54.21: EUR`),
    /// as written when it is anything else with a number in it, and nil without one.
    static func amount(_ written: String) -> String? {
        guard written.contains(where: \.isNumber) else { return nil }
        guard let match = written.wholeMatch(of: /([A-Za-z]{3})?[\s:]*(-?[0-9]+(?:\.[0-9]+)?)[\s:]*([A-Za-z]{3})?/),
              (match.output.1 == nil) != (match.output.3 == nil),
              let code = (match.output.1 ?? match.output.3).map({ $0.uppercased() }),
              Locale.Currency.isoCurrencies.contains(where: { $0.identifier == code }) else { return written }
        return "\(match.output.2) \(code)"
    }

    /// At most `limit` characters, cut after the last whole word that fits when there is one.
    public static func shortened(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        // One character more, so a word ending exactly at the limit is seen to be whole.
        let cut = value.prefix(limit + 1)
        guard let space = cut.lastIndex(of: " ") else { return String(value.prefix(limit)) }
        return String(cut[..<space])
    }

    /// Runs of white space, line breaks and control characters become one space.
    public static func oneLine(_ text: String) -> String {
        text.unicodeScalars.split { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
    }

    /// A calendar day as `YYYY-MM-DD`, from ISO or day-first `dd.mm.yyyy` / `dd/mm/yyyy`; nil for anything else.
    public static func isoDay(_ text: String) -> String? {
        if let m = text.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/) { return day(Int(m.1), Int(m.2), Int(m.3)) }
        if let m = text.wholeMatch(of: /(\d{1,2})[.\/-](\d{1,2})[.\/-](\d{4})/) { return day(Int(m.3), Int(m.2), Int(m.1)) }
        return nil
    }

    /// `YYYY`, `YYYY-MM` or a day, or two of them as `start/end`.
    private static func period(_ text: String) -> String? {
        let bounds = text.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(bounds.count) else { return nil }
        let normalized = bounds.compactMap { bound -> String? in
            if bound.wholeMatch(of: /\d{4}/) != nil { return bound }
            if let m = bound.wholeMatch(of: /(\d{4})-(\d{2})/), let month = Int(m.2), (1...12).contains(month) { return bound }
            return isoDay(bound)
        }
        return normalized.count == bounds.count ? normalized.joined(separator: "/") : nil
    }

    private static func day(_ y: Int?, _ m: Int?, _ d: Int?) -> String? {
        guard let y, let m, let d else { return nil }
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        guard c.isValidDate(in: Calendar(identifier: .gregorian)) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// The ISO 639-1 code of a language written as an ISO 639 code ("pt", "POR") or by its English name
    /// ("Portuguese"); nil for anything else. Codes are the ones Foundation knows (`Locale.LanguageCode`).
    public static func languageCode(_ text: String) -> String? {
        let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = Locale.LanguageCode(written.lowercased())
        if code.isISOLanguage, let alpha2 = code.identifier(.alpha2) { return alpha2 }
        return englishLanguageNames[folded(written)]
    }

    /// The English name of an ISO 639-1 code, as Foundation spells it.
    public static func languageName(_ code: String) -> String? {
        english.localizedString(forLanguageCode: code)
    }

    /// What a search matches a document's labels of `kind` by, one label per line. A language is found by its code
    /// and by its English name.
    public static func searchText(_ labels: [DocumentLabel], kind: LabelKind) -> String {
        labels.filter { $0.kind == kind }.map { label in
            guard kind == .language, let name = languageName(label.value) else { return label.value }
            return "\(label.value) \(name)"
        }.joined(separator: "\n")
    }

    private static let english = Locale(identifier: "en")

    private static let englishLanguageNames: [String: String] = Dictionary(
        Locale.LanguageCode.isoLanguageCodes.compactMap { code -> (String, String)? in
            guard code.identifier.count == languageCodeLength, let name = english.localizedString(forLanguageCode: code.identifier) else {
                return nil
            }
            return (folded(name), code.identifier)
        },
        uniquingKeysWith: { first, _ in first })

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
