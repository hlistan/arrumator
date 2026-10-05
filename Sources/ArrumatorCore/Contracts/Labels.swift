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

    /// The label as `distinct()` tells labels apart: its kind, and its value whatever its case or accents.
    var distinctKey: String {
        kind.rawValue + ":" + value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
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
            guard seen.insert(label.distinctKey).inserted else { return false }
            return !label.kind.isSingle || kinds.insert(label.kind).inserted
        }
    }
}

extension DocumentLabel {
    /// ISO 639-1 codes are two letters.
    public static let languageCodeLength = 2

    /// What separates two labels the model wrote in one entry of its answer ("banking; account statement"), which no
    /// label of a kind it gives holds (`normalized`); only the user's own tags may.
    public static let entrySeparator: Character = ";"

    /// `labels` as an older version kept them, in the form the index keeps them since, as `v26_storedLabelsInTheirForm`
    /// left them: a label of a kind the model gives that holds `entrySeparator` is the labels it holds ("banking; account
    /// statement", as an older record file may still hold it), each trimmed, once, in its place, and a name or a word
    /// without a letter (`wordKinds`), as a tax number given as a party, is none. A tag, the user's own, stays as written.
    public static func split(_ labels: [DocumentLabel]) -> [DocumentLabel] {
        var split: [DocumentLabel] = []
        for label in labels {
            let parts = label.kind.isUsersOwn ? [label.value]
                : label.value.split(separator: entrySeparator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for part in parts.map({ DocumentLabel(kind: label.kind, value: $0) }) where !split.contains(part)
                && (!wordKinds.contains(label.kind) || part.value.contains(where: \.isLetter)) {
                split.append(part)
            }
        }
        return split
    }

    /// The kinds whose labels are names or words, each with a letter (`normalized`).
    public static let wordKinds: Set<LabelKind> = [.sender, .party, .topic, .object, .jurisdiction]

    /// A label of `kind` with `value` as a label keeps it, or nil when it is none, as the kind's form in
    /// docs/how-it-works.md#labels fixes it. Every value is one line. A date or deadline is ISO 8601 (`YYYY-MM-DD`, from
    /// day-first dates too), a period one or two ISO dates of any precision joined by `/`, a language its ISO 639-1 code,
    /// a type one of `DocumentType` other than `other`, and an amount a number and its currency (`amount`). A name, a
    /// topic, an object and a jurisdiction are words, so each has a letter; a reference has a number. An object or a
    /// reference is what it is followed by what identifies it, so one written as a field and its value
    /// (`invoice: FT 1`) is written so (`invoice FT 1`). A topic is lowercase. No label of a kind the model gives holds
    /// `entrySeparator`, which separates two of them in one entry of its answer. A tag is kept as written.
    public static func normalized(_ value: String, kind: LabelKind) -> DocumentLabel? {
        let written = oneLine(value)
        guard !written.isEmpty, kind.isUsersOwn || !written.contains(entrySeparator) else { return nil }
        let normalized: String? = switch kind {
        case .language: languageCode(written)
        case .type: DocumentType(rawValue: written.lowercased().replacingOccurrences(of: " ", with: "-"))
            .flatMap { $0 == .other ? nil : $0.rawValue }
        case .date, .deadline: isoDay(written)
        case .period: period(written)
        case .amount: amount(written)
        case .reference: written.contains(where: \.isNumber) ? withoutFieldColon(written) : nil
        case .object: written.contains(where: \.isLetter) ? withoutFieldColon(written) : nil
        case .topic: written.contains(where: \.isLetter) ? written.lowercased() : nil
        case .sender, .party, .jurisdiction: written.contains(where: \.isLetter) ? written : nil
        case .tag: written
        }
        return normalized.map { DocumentLabel(kind: kind, value: $0) }
    }

    /// `written` with a colon that ends a field's name (`invoice: FT 1`, `account : 123`) taken out, so what it is runs
    /// on into what identifies it (`invoice FT 1`), as the kind's form writes it. A colon inside a value, as in a time
    /// (`12:30`) or a code (`AB:12`), is no field's.
    private static func withoutFieldColon(_ written: String) -> String {
        written.replacing(/\s*:\s+/, with: " ")
    }

    /// An amount as `number CODE`: a number, with a dot for decimals and no grouping, and the ISO 4217 code of its
    /// currency, written before or after it, with or without a space or a colon (`EUR 54.21`, `54.21: EUR`, `54.21eur`),
    /// or a symbol only one currency is written with (`12,50 €` is `12.50 EUR`; `$` and `£` stand for several). The
    /// number may be grouped and have a decimal comma (`1 234,56`, `1.234,56`, `1,234.56`): of a dot and a comma, the
    /// last one is the decimal point, and so is either alone when it is there once. Nil for anything else: no number, a
    /// percentage, a currency left out or not known.
    public static func amount(_ written: String) -> String? {
        guard let match = written.firstMatch(of: amountNumber), let number = decimal(String(match.output.number)) else { return nil }
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":"))
        let before = written[..<match.range.lowerBound].trimmingCharacters(in: separators)
        let after = written[match.range.upperBound...].trimmingCharacters(in: separators)
        guard before.isEmpty != after.isEmpty, let code = currencyCode(before.isEmpty ? after : before) else { return nil }
        return "\(match.output.sign == nil ? "" : "-")\(number) \(code)"
    }

    /// A number as an amount writes it (`amount`), alone: its digits with a dot for decimals; nil for anything else.
    public static func amountValue(_ written: String) -> String? {
        let text = oneLine(written)
        guard let match = text.wholeMatch(of: amountNumber), let number = decimal(String(match.output.number)) else { return nil }
        return (match.output.sign == nil ? "" : "-") + number
    }

    /// A number with its sign: digits, which a dot, a comma, an apostrophe or a space may group, but only between
    /// digits.
    private static var amountNumber: Regex<(Substring, sign: Substring?, number: Substring)> {
        /(?<sign>-)?(?<number>[0-9](?:[0-9]|[.,' \u{00A0}\u{202F}](?=[0-9]))*)/
    }

    /// `number` (`amountNumber`) with a dot for decimals and no grouping: of a dot and a comma, the last is the decimal
    /// point when the other comes before it, and either is when it is there once; marks of one kind that come more than
    /// once group. Nil when the marks cannot be read so, as a dot after a comma after a dot.
    private static func decimal(_ number: String) -> String? {
        let digits = number.filter { !$0.isWhitespace && $0 != "'" }
        let marks = digits.filter { $0 == "." || $0 == "," }
        guard let last = marks.last else { return digits }
        let grouping = marks.dropLast()
        if grouping.isEmpty { return digits.replacingOccurrences(of: String(last), with: ".") }
        if Set(marks).count == 1 { return digits.filter(\.isNumber) }
        guard Set(grouping).count == 1, grouping.first != last, let point = digits.lastIndex(of: last) else { return nil }
        return digits[..<point].filter(\.isNumber) + "." + digits[digits.index(after: point)...]
    }

    /// The ISO 4217 code `text` is, in any case, or the code of the one currency `text` is the symbol of; nil for
    /// anything else.
    private static func currencyCode(_ text: String) -> String? {
        let code = text.uppercased()
        if isoCurrencyCodes.contains(code) { return code }
        return currencySymbols[text]
    }

    private static let isoCurrencyCodes = Set(Locale.Currency.isoCurrencies.map(\.identifier))

    /// Each currency symbol Foundation knows (CLDR: the symbol every locale and English write each currency with) that
    /// only one currency is written with, and its code. A symbol several currencies share, as `$`, `£`, `¥` and `kr`
    /// are, is none: which currency it stands for is the document's, not the symbol's.
    private static let currencySymbols: [String: String] = {
        var codes: [String: Set<String>] = [:]
        for code in isoCurrencyCodes {
            if let symbol = (english as NSLocale).displayName(forKey: .currencySymbol, value: code), symbol != code { codes[symbol, default: []].insert(code) }
        }
        for identifier in Locale.availableIdentifiers {
            let locale = Locale(identifier: identifier)
            if let code = locale.currency?.identifier, let symbol = locale.currencySymbol, symbol != code { codes[symbol, default: []].insert(code) }
        }
        return codes.compactMapValues { $0.count == 1 ? $0.first : nil }
    }()

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
