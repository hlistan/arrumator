// swiftlint:disable line_length - each identifier pattern is one regex literal, read whole
import Foundation

/// Detection, validation and normalisation of stable identifiers, which the model is shown with the document:
/// IBAN (mod-97), Portuguese NIF (mod-11), Russian ИНН/ОГРН/ОГРНИП (checksums), КПП, БИК, 20-digit Russian
/// accounts, EU VAT numbers, and account/customer and policy/contract numbers after the words
/// `EntityConfig.accountLabels` and `policyLabels` list, a number sign as `EntityConfig.numberSigns` writes it between.
///
/// Identifiers that collide with ordinary numbers (NIF vs. phone numbers, ИНН, account numbers) are only accepted
/// after a label; checksummed identifiers with a distinctive shape (IBAN, compact EU VAT) are accepted anywhere.
/// Pure and deterministic; the regex patterns and checksum algorithms are the definition of each identifier format.
public struct StableKeys: Sendable {
    /// The rules the configuration's words make, compiled once.
    private let labelled: [Rule]

    /// - Parameter labels: the words that label account and policy numbers, and how a number sign is written.
    public init(labels: EntityConfig) {
        labelled = Self.labelledRules(labels)
    }

    /// All stable keys in `text`, in order of first appearance, normalised and deduplicated. A value found both as a
    /// specific kind (e.g. `ruAccount`) and as a generic labelled number keeps only the specific kind.
    public func detect(in text: String) -> [StableKey] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var found: [(location: Int, key: StableKey)] = []
        for rule in Self.rules + labelled {
            for match in rule.regex.matches(in: text, range: range) {
                let groups = (1..<match.numberOfRanges).map { index -> String in
                    let group = match.range(at: index)
                    return group.location == NSNotFound ? "" : ns.substring(with: group)
                }
                for key in rule.keys(groups) {
                    found.append((match.range.location, key))
                }
            }
        }
        found.sort { $0.location < $1.location }
        var seen = Set<StableKey>()
        let ordered = found.map(\.key).filter { seen.insert($0).inserted }
        let specificValues = Set(ordered.filter { !Self.genericKinds.contains($0.kind) }.map(\.value))
        return ordered.filter { !Self.genericKinds.contains($0.kind) || !specificValues.contains($0.value) }
    }

    /// Canonical form: whitespace removed, uppercased, trailing separators trimmed.
    public static func normalize(_ value: String) -> String {
        let compact = value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        return String(String.UnicodeScalarView(compact)).uppercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-/"))
    }

    // MARK: Validation

    /// ISO 13616 IBAN: known country, exact national length, mod-97 remainder 1.
    public static func isValidIBAN(_ value: String) -> Bool {
        let iban = normalize(value)
        let chars = Array(iban)
        guard chars.count >= 5, chars.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        let country = String(chars[0..<2])
        guard let length = ibanLengths[country], chars.count == length,
              chars[2].isNumber, chars[3].isNumber else { return false }
        let rearranged = chars[4...] + chars[0..<4]
        var remainder = 0
        for char in rearranged {
            guard let digit = char.isNumber ? char.wholeNumberValue : base36Value(char) else { return false }
            let digits = digit < 10 ? [digit] : [digit / 10, digit % 10]
            for d in digits { remainder = (remainder * 10 + d) % 97 }
        }
        return remainder == 1
    }

    /// Portuguese NIF/NIPC: 9 digits, a valid leading digit (or two-digit prefix) and the mod-11 check digit.
    public static func isValidPortugueseNIF(_ value: String) -> Bool {
        guard let digits = digitArray(normalize(value)), digits.count == 9 else { return false }
        let first = digits[0]
        let firstTwo = digits[0] * 10 + digits[1]
        guard nifLeadingDigits.contains(first) || nifLeadingPairs.contains(firstTwo) else { return false }
        let sum = (0..<8).reduce(0) { $0 + digits[$1] * (9 - $1) }
        let remainder = sum % 11
        let check = remainder < 2 ? 0 : 11 - remainder
        return check == digits[8]
    }

    /// Russian ИНН: 10 digits (organisation) or 12 digits (individual) with the official weighted checksums.
    public static func isValidRussianINN(_ value: String) -> Bool {
        guard let digits = digitArray(normalize(value)) else { return false }
        func check(_ weights: [Int]) -> Int {
            zip(weights, digits).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10
        }
        switch digits.count {
        case 10:
            return check([2, 4, 10, 3, 5, 9, 4, 6, 8]) == digits[9]
        case 12:
            return check([7, 2, 4, 10, 3, 5, 9, 4, 6, 8]) == digits[10]
                && check([3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8]) == digits[11]
        default:
            return false
        }
    }

    /// Russian ОГРН (13 digits, mod 11) or ОГРНИП (15 digits, mod 13).
    public static func isValidOGRN(_ value: String) -> Bool {
        guard let digits = digitArray(normalize(value)) else { return false }
        let modulus: Int
        switch digits.count {
        case 13: modulus = 11
        case 15: modulus = 13
        default: return false
        }
        let remainder = digits.dropLast().reduce(0) { ($0 * 10 + $1) % modulus }
        return remainder % 10 == digits[digits.count - 1]
    }

    /// Russian КПП: 4 digits (tax office), 2 digits or Latin letters (reason), 3 digits.
    public static func isValidRussianKPP(_ value: String) -> Bool {
        matchesWhole(normalize(value), kppFormat)
    }

    /// Russian БИК: 9 digits starting with the country code `04`.
    public static func isValidRussianBIK(_ value: String) -> Bool {
        matchesWhole(normalize(value), bikFormat)
    }

    /// EU VAT number with its country prefix (`PT999999990`, `DE123456789`, `NL123456789B01`). Portuguese numbers
    /// must also pass the NIF check digit.
    public static func isValidEUVAT(_ value: String) -> Bool {
        let vat = normalize(value)
        guard vat.count > 2 else { return false }
        let country = String(vat.prefix(2))
        let body = String(vat.dropFirst(2))
        guard let format = vatFormats[country], matchesWhole(body, format) else { return false }
        return country == "PT" ? isValidPortugueseNIF(body) : true
    }

    // MARK: Rules

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let keys: @Sendable ([String]) -> [StableKey]
    }

    private static let genericKinds: Set<StableKeyKind> = [.accountNumber, .policyOrContract]

    /// Separator between a label and its value: a number sign as `numberSigns` writes it (`n.º`, `№`, `No.`), if any,
    /// then colons, dots, dashes and white space.
    private static func separator(_ numberSigns: [String]) -> String {
        (LabelPhrases.alternation(numberSigns).map { #"(?:\s*"# + $0 + ")?" } ?? "") + #"[\s:.#-]*"#
    }

    /// Generic labelled identifier: starts alphanumeric, may contain `/ . -` and single spaces between digits.
    private static let labelledValue = #"([A-Z0-9А-ЯЁ](?:[A-Z0-9А-ЯЁ/.-]|(?<=\d) (?=\d)){3,30})"#

    private static let vatCountries = "AT|BE|BG|CY|CZ|DE|DK|EE|EL|ES|FI|FR|HR|HU|IE|IT|LT|LU|LV|MT|NL|PL|PT|RO|SE|SI|SK|XI"

    private static let rules: [Rule] = [
        // IBAN anywhere: country + check digits + BBAN, optionally grouped by spaces; cut to the national length.
        Rule(regex: regex(#"(?<![A-Z0-9])([A-Z]{2}\d{2}(?:[  ]?[A-Z0-9]){10,32})"#, caseInsensitive: false)) { g in
            let compact = normalize(g[0])
            guard let length = ibanLengths[String(compact.prefix(2))], compact.count >= length else { return [] }
            let iban = String(compact.prefix(length))
            return isValidIBAN(iban) ? [StableKey(kind: .iban, value: iban)] : []
        },
        // Russian ИНН/КПП pair: "ИНН/КПП 7707083893/773601001".
        Rule(regex: regex(#"(?<![\p{L}\p{N}])(?:ИНН|INN)\s*/\s*(?:КПП|KPP)[\s:№.-]*(\d{10}|\d{12})\s*/\s*(\d{4}[0-9A-Z]{2}\d{3})(?![\p{L}\p{N}])"#)) { g in
            var keys: [StableKey] = []
            if isValidRussianINN(g[0]) { keys.append(StableKey(kind: .ruINN, value: normalize(g[0]))) }
            if isValidRussianKPP(g[1]) { keys.append(StableKey(kind: .ruKPP, value: normalize(g[1]))) }
            return keys
        },
        Rule(regex: regex(#"(?<![\p{L}\p{N}])(?:ИНН|INN)[\s:№.-]*(\d{12}|\d{10})(?!\d)"#)) { g in
            isValidRussianINN(g[0]) ? [StableKey(kind: .ruINN, value: normalize(g[0]))] : []
        },
        Rule(regex: regex(#"(?<![\p{L}\p{N}])(?:ОГРНИП|ОГРН|OGRNIP|OGRN)[\s:№.-]*(\d{15}|\d{13})(?!\d)"#)) { g in
            isValidOGRN(g[0]) ? [StableKey(kind: .ruOGRN, value: normalize(g[0]))] : []
        },
        Rule(regex: regex(#"(?<![\p{L}\p{N}])(?:КПП|KPP)[\s:№.-]*(\d{4}[0-9A-Z]{2}\d{3})(?![\p{L}\p{N}])"#)) { g in
            isValidRussianKPP(g[0]) ? [StableKey(kind: .ruKPP, value: normalize(g[0]))] : []
        },
        Rule(regex: regex(#"(?<![\p{L}\p{N}])(?:БИК|BIK)[\s:№.-]*(04\d{7})(?!\d)"#)) { g in
            [StableKey(kind: .ruBIK, value: normalize(g[0]))]
        },
        // 20-digit Russian bank/personal accounts after р/с, л/с, к/с or "счёт" labels.
        Rule(regex: regex(#"(?<![\p{L}\p{N}])(?:р/сч?|л/сч?|к/сч?|р\.\s?с\.|(?:расч[её]тный|лицевой|корреспондентский|корр\.?)\s+сч[её]т|сч[её]т)[\s:№.-]*((?:\d\s?){19}\d)(?!\d)"#)) { g in
            [StableKey(kind: .ruAccount, value: normalize(g[0]))]
        },
        // EU VAT after a VAT label (country prefix may be separated by a space).
        Rule(regex: regex(#"(?<![\p{L}\p{N}])(?i:VAT|IVA|TVA|USt|UID|BTW)(?i:[\s-]*(?:reg(?:istration)?\.?\s*)?(?:No\.?|Nr\.?|Number|ID|IdNr\.?|n\.?\s?[ºo°]))?[\s:.#-]*("# + vatCountries + #")\s?([0-9A-Z+*]{2,12})(?![\p{L}\p{N}])"#, caseInsensitive: false)) { g in
            vatKeys(country: g[0], body: g[1])
        },
        // Compact EU VAT anywhere: a single token such as PT999999990 or DE123456789.
        Rule(regex: regex(#"(?<![\p{L}\p{N}])("# + vatCountries + #")([0-9A-Z+*]{8,12})(?![\p{L}\p{N}])"#, caseInsensitive: false)) { g in
            vatKeys(country: g[0], body: g[1])
        },
    ]

    /// The rules whose labels or number signs `labels` gives: the Portuguese NIF after its own name, and a number after
    /// one of the words that label an account or a policy number, matched as whole words.
    private static func labelledRules(_ labels: EntityConfig) -> [Rule] {
        let separator = separator(labels.numberSigns)
        // Portuguese NIF/NIPC after its label, optionally written with the PT VAT prefix or grouped by threes.
        let nif = Rule(regex: regex(#"(?<![\p{L}\p{N}])(?:NIF/NIPC|NIPC|N\.?\s?I\.?\s?F\.?|contribuinte|n[úu]mero\s+de\s+identifica[çc][ãa]o\s+fiscal)"# + separator + #"(?:PT\s?)?(\d{3}\s?\d{3}\s?\d{3})(?!\d)"#)) { g in
            isValidPortugueseNIF(g[0]) ? [StableKey(kind: .ptNIF, value: normalize(g[0]))] : []
        }
        let numbers = [(labels.accountLabels, StableKeyKind.accountNumber), (labels.policyLabels, .policyOrContract)].compactMap { words, kind in
            // A label that ends in a letter ends a word, so `договор n` is not the start of `договор NDA-2024`.
            LabelPhrases.alternation(words, endingWords: true).map { label in
                Rule(regex: LabelPhrases.regex(#"(?<![\p{L}\p{N}])"# + label + separator + labelledValue)) { g in
                    labelledKey(kind, g[0])
                }
            }
        }
        return [nif] + numbers
    }

    private static func vatKeys(country: String, body: String) -> [StableKey] {
        let vat = normalize(country + body)
        guard isValidEUVAT(vat) else { return [] }
        var keys = [StableKey(kind: .vatEU, value: vat)]
        if country == "PT" { keys.append(StableKey(kind: .ptNIF, value: normalize(body))) }
        return keys
    }

    /// Labelled generic numbers must contain at least `minLabelledDigits` digits so words are never captured.
    private static func labelledKey(_ kind: StableKeyKind, _ raw: String) -> [StableKey] {
        let value = normalize(raw)
        guard value.count >= minLabelledLength, value.filter(\.isNumber).count >= minLabelledDigits else { return [] }
        return [StableKey(kind: kind, value: value)]
    }

    private static let minLabelledLength = 4
    private static let minLabelledDigits = 3

    // MARK: Format tables

    /// IBAN lengths by country (ISO 13616 registry).
    private static let ibanLengths: [String: Int] = [
        "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16, "BG": 22, "BH": 22, "BR": 29, "BY": 28,
        "CH": 21, "CR": 22, "CY": 28, "CZ": 24, "DE": 22, "DK": 18, "DO": 28, "EE": 20, "EG": 29, "ES": 24, "FI": 18,
        "FO": 18, "FR": 27, "GB": 22, "GE": 22, "GI": 23, "GL": 18, "GR": 27, "GT": 28, "HR": 21, "HU": 28, "IE": 22,
        "IL": 23, "IQ": 23, "IS": 26, "IT": 27, "JO": 30, "KW": 30, "KZ": 20, "LB": 28, "LC": 32, "LI": 21, "LT": 20,
        "LU": 20, "LV": 21, "MC": 27, "MD": 24, "ME": 22, "MK": 19, "MR": 27, "MT": 31, "MU": 30, "NL": 18, "NO": 15,
        "PK": 24, "PL": 28, "PS": 29, "PT": 25, "QA": 29, "RO": 24, "RS": 22, "RU": 33, "SA": 24, "SC": 31, "SE": 24,
        "SI": 19, "SK": 24, "SM": 27, "ST": 25, "SV": 28, "TL": 23, "TN": 24, "TR": 26, "UA": 29, "VA": 22, "VG": 24,
        "XK": 20,
    ]

    /// EU VAT number bodies by country prefix (VIES formats).
    private static let vatFormats: [String: NSRegularExpression] = [
        "AT": #"U\d{8}"#, "BE": #"[01]\d{9}"#, "BG": #"\d{9,10}"#, "CY": #"\d{8}[A-Z]"#, "CZ": #"\d{8,10}"#,
        "DE": #"\d{9}"#, "DK": #"\d{8}"#, "EE": #"\d{9}"#, "EL": #"\d{9}"#, "ES": #"[A-Z0-9]\d{7}[A-Z0-9]"#,
        "FI": #"\d{8}"#, "FR": #"[A-HJ-NP-Z0-9]{2}\d{9}"#, "HR": #"\d{11}"#, "HU": #"\d{8}"#,
        "IE": #"\d{7}[A-W][A-I]?|\d[A-Z+*]\d{5}[A-W]"#, "IT": #"\d{11}"#, "LT": #"\d{9}|\d{12}"#, "LU": #"\d{8}"#,
        "LV": #"\d{11}"#, "MT": #"\d{8}"#, "NL": #"\d{9}B\d{2}"#, "PL": #"\d{10}"#, "PT": #"\d{9}"#,
        "RO": #"[1-9]\d{1,9}"#, "SE": #"\d{10}01"#, "SI": #"\d{8}"#, "SK": #"\d{10}"#, "XI": #"\d{9}|\d{12}"#,
    ].mapValues { regex("(?:\($0))", caseInsensitive: false) }

    private static let kppFormat = regex(#"\d{4}[0-9A-Z]{2}\d{3}"#, caseInsensitive: false)
    private static let bikFormat = regex(#"04\d{7}"#, caseInsensitive: false)

    /// Valid first digits of a NIF/NIPC (individuals 1–3, companies 5, public bodies 6, sole traders 8) and valid
    /// two-digit prefixes for the remaining categories (45 non-residents, 7x estates/funds, 9x irregular entities).
    private static let nifLeadingDigits: Set<Int> = [1, 2, 3, 5, 6, 8]
    private static let nifLeadingPairs: Set<Int> = [45, 70, 71, 72, 74, 75, 77, 78, 79, 90, 91, 98, 99]

    // MARK: Helpers

    /// Compiles a constant pattern. Patterns are literals in this file and covered by tests, so failure is a
    /// programming error.
    private static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("Invalid stable-key pattern \(pattern): \(error)")
        }
    }

    private static func matchesWhole(_ value: String, _ regex: NSRegularExpression) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        guard let match = regex.firstMatch(in: value, options: [.anchored], range: range) else { return false }
        return match.range == range
    }

    private static func digitArray(_ value: String) -> [Int]? {
        let digits = value.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
        return digits.count == value.count ? digits : nil
    }

    private static func base36Value(_ char: Character) -> Int? {
        guard char.isASCII, char.isLetter, let ascii = char.uppercased().first?.asciiValue else { return nil }
        return Int(ascii) - Int(Character("A").asciiValue ?? 0) + 10
    }
}
// swiftlint:enable line_length
