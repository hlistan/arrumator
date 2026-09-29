import Foundation

/// The kinds of signal the local model picks out of every document and the app keeps as its labels. A document is
/// labelled by what it is about, not by where it is filed, so it can be found however the archive is arranged.
public enum LabelKind: String, Sendable, Codable, CaseIterable {
    /// A person or organisation the document concerns: whom it is addressed to, whose it is, or whom it is about.
    case subject
    /// A specific thing the document concerns: a property, vehicle, account, policy, contract, device or the like.
    case object
    /// A country, region or other jurisdiction whose law, authority or administration the document falls under.
    case jurisdiction
    /// A language the document is written in, as an ISO 639-1 code.
    case language
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

extension DocumentLabel {
    /// ISO 639-1 codes are two letters.
    public static let languageCodeLength = 2

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
