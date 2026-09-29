import ArrumatorCore
import Foundation

/// Raw entities found in a text, before the document date is resolved.
public struct EntityScan: Sendable {
    public var dateCandidates: [DateCandidate]
    public var amounts: [MoneyAmount]
    public var emails: [String]
    public var urls: [String]
    public var phones: [String]
    public var stableKeys: [StableKey]
}

/// Pure entity extraction: dates (see `DateScanner`), money with €/EUR/R$/₽/руб/RUB/$/USD, e-mail addresses,
/// URLs and phone numbers (`NSDataDetector`), and checksum-validated stable keys (`StableKeys`).
public struct EntityExtractor: Sendable {
    private let config: EntityConfig

    public init(config: EntityConfig) {
        self.config = config
    }

    public func scan(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> EntityScan {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let pivot = calendar.component(.year, from: now) + config.yearsForward
        let dates = DateScanner(twoDigitYearPivot: pivot).candidates(in: text)
        let keys = StableKeys.detect(in: text)

        var urls: [String] = []
        var phones: [String] = []
        let keyDigits = keys.map { $0.value.filter(\.isNumber) }
        let dateRanges = dates.map { NSRange(location: $0.location, length: $0.length) }
        for match in Self.detector?.matches(in: text, range: full) ?? [] {
            switch match.resultType {
            case .link:
                if let url = match.url, url.scheme?.lowercased() != "mailto" { urls.append(url.absoluteString) }
            case .phoneNumber:
                guard let phone = match.phoneNumber else { continue }
                let digits = phone.filter(\.isNumber)
                let overlapsDate = dateRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
                guard digits.count >= Self.minPhoneDigits, !overlapsDate,
                      !keyDigits.contains(where: { $0.contains(digits) }) else { continue }
                phones.append(phone)
            default:
                continue
            }
        }
        let emails = Self.emailRegex.matches(in: text, range: full).map { ns.substring(with: $0.range).lowercased() }
        return EntityScan(dateCandidates: dates, amounts: Self.amounts(in: text), emails: emails.uniqued(),
                          urls: urls.uniqued(), phones: phones.uniqued(), stableKeys: keys)
    }

    // MARK: Money

    static func amounts(in text: String) -> [MoneyAmount] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [(location: Int, amount: MoneyAmount)] = []
        for (regex, currencyGroup, amountGroup) in [(currencyFirst, 1, 2), (amountFirst, 2, 1)] {
            for match in regex.matches(in: text, range: full) {
                let symbol = ns.substring(with: match.range(at: currencyGroup))
                guard let currency = currencyCode(symbol),
                      let value = normalizeAmount(ns.substring(with: match.range(at: amountGroup))) else { continue }
                found.append((match.range.location, MoneyAmount(value: value, currency: currency)))
            }
        }
        return found.sorted { $0.location < $1.location }.map(\.amount).uniqued()
    }

    /// Canonical decimal string (`1234.56`) from grouped EU/US/RU notations (`1.234,56`, `1,234.56`, `12 500,00`).
    static func normalizeAmount(_ raw: String) -> String? {
        var digits = raw.filter { !groupingSpaces.contains($0) }
        let dots = digits.filter { $0 == "." }.count
        let commas = digits.filter { $0 == "," }.count
        let decimal: Character?
        if dots > 0, commas > 0 {
            decimal = (digits.lastIndex(of: ".") ?? digits.startIndex) > (digits.lastIndex(of: ",") ?? digits.startIndex) ? "." : ","
        } else if let separator: Character = dots > 0 ? "." : commas > 0 ? "," : nil,
                  dots + commas == 1,
                  let index = digits.lastIndex(of: separator),
                  digits.distance(from: index, to: digits.endIndex) - 1 <= maxDecimals {
            decimal = separator
        } else {
            decimal = nil
        }
        digits = String(digits.compactMap { char -> Character? in
            if char == decimal { return "." }
            return char.isNumber ? char : nil
        })
        guard !digits.isEmpty, Double(digits) != nil else { return nil }
        return digits
    }

    private static func currencyCode(_ symbol: String) -> String? {
        let lower = symbol.lowercased()
        switch lower {
        case "€", "eur": return "EUR"
        case "r$": return "BRL"
        case "$", "us$", "usd": return "USD"
        case "₽", "rub", "р.": return "RUB"
        default: return lower.hasPrefix("руб") ? "RUB" : nil
        }
    }

    // MARK: Patterns

    private static let amountPattern = #"(\d{1,3}(?:[   .,'’]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)"#
    private static let currencyFirst = regex(#"(?<![\p{L}\p{N}])(R\$|US\$|€|EUR|USD|RUB|₽|\$)\s?"# + amountPattern + #"(?!\d)"#)
    private static let amountFirst = regex(#"(?<![\d.,])"# + amountPattern + #"\s?(R\$|€|EUR|USD|RUB|₽|руб(?:лей|ля|ль|\.)?|р\.|\$)(?![\p{L}])"#)
    private static let emailRegex = regex(#"(?<![A-Z0-9._%+-])[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}(?![A-Z0-9])"#)
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
        | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    private static let groupingSpaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "'", "’"]
    /// Cents are written with at most two digits; three digits after a lone separator mean thousands.
    private static let maxDecimals = 2
    /// Shortest digit run accepted as a phone number (shorter runs are extensions, codes or amounts).
    private static let minPhoneDigits = 7

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Invalid entity pattern \(pattern): \(error)")
        }
    }
}

extension Array where Element: Hashable {
    /// Elements in original order without repeats.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
