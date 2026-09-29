import Foundation

/// A full calendar date found in text, with its position (UTF-16 offsets into the scanned string).
public struct DateCandidate: Sendable, Hashable, Encodable {
    public var day: CalendarDay
    public var location: Int
    public var length: Int
    public var matched: String

    public var end: Int { location + length }
}

/// Finds full dates in EN/RU/PT text: textual months in every grammatical form (`15 мая 2024 г.`,
/// `20 de maio de 2026`, `May 20, 2026`, `20 May 2026`), ISO `YYYY-MM-DD`, and day-first numeric dates
/// (`15.05.2024`, `15/05/24`). Month-first numeric dates are accepted only when day-first is impossible.
/// `NSDataDetector` adds any remaining date expressions that carry both a day number and a four-digit year.
struct DateScanner: Sendable {
    /// Two-digit years map to 20YY unless that is later than this year, then to 19YY.
    let twoDigitYearPivot: Int

    func candidates(in text: String) -> [DateCandidate] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var accepted: [DateCandidate] = []
        // Spans already matched by a pattern, including impossible dates (31.02.2025), so the data detector never
        // re-reads them with calendar rollover.
        var claimed: [NSRange] = []
        func overlaps(_ range: NSRange) -> Bool {
            claimed.contains { NSIntersectionRange($0, range).length > 0 }
        }
        for pattern in Self.patterns {
            for match in pattern.regex.matches(in: text, range: full) where !overlaps(match.range) {
                claimed.append(match.range)
                let groups = (1..<match.numberOfRanges).map { index -> String in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? "" : ns.substring(with: range)
                }
                guard let day = pattern.day(groups, twoDigitYearPivot) else { continue }
                accepted.append(DateCandidate(day: day, location: match.range.location, length: match.range.length,
                                              matched: ns.substring(with: match.range)))
            }
        }
        for match in Self.detector?.matches(in: text, range: full) ?? [] where !overlaps(match.range) {
            let matched = ns.substring(with: match.range)
            // Month-year phrases ("May 2024") come back as the 1st of the month; only full dates count.
            let matchedRange = NSRange(location: 0, length: (matched as NSString).length)
            guard let date = match.date, Self.fourDigitYear.firstMatch(in: matched, range: matchedRange) != nil,
                  Self.dayNumber.firstMatch(in: matched, range: matchedRange) != nil else {
                continue
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = match.timeZone ?? .current
            accepted.append(DateCandidate(day: CalendarDay(date: date, calendar: calendar), location: match.range.location,
                                          length: match.range.length, matched: matched))
        }
        return accepted.sorted { $0.location < $1.location }
    }

    // MARK: Patterns

    private struct Pattern: Sendable {
        let regex: NSRegularExpression
        let day: @Sendable ([String], Int) -> CalendarDay?
    }

    private static let months = MonthNames.alternation

    private static let patterns: [Pattern] = [
        // «15» мая 2024 г. | 20 de maio de 2026 | 1st of May 2024 | 15-mai-2024
        Pattern(regex: regex(#"(?<![\p{L}\p{N}])["«“]?(\d{1,2})(?:st|nd|rd|th|º|°|-?го|-?е)?["»”]?[\s./-]*(?:de\s+|of\s+)?("#
                             + months + #")(?![\p{L}])\.?,?[\s./-]*(?:de\s+)?(\d{4})(?!\d)"#)) { g, _ in
            guard let day = Int(g[0]), let month = MonthNames.month(for: g[1]), let year = Int(g[2]) else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        },
        // May 20, 2026 | Sept. 3 2025
        Pattern(regex: regex(#"(?<![\p{L}\p{N}])("# + months + #")(?![\p{L}])\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?!\d)"#)) { g, _ in
            guard let month = MonthNames.month(for: g[0]), let day = Int(g[1]), let year = Int(g[2]) else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        },
        // 2026-05-20 | 2026.05.20 | 2026/05/20
        Pattern(regex: regex(#"(?<![\d.,/-])(\d{4})([-./])(\d{1,2})\2(\d{1,2})(?![\d])"#)) { g, _ in
            guard let year = Int(g[0]), let month = Int(g[2]), let day = Int(g[3]) else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        },
        // 20.05.2026 | 20/05/26 | 20-05-2026 (day first; month first only when the first number exceeds 12)
        Pattern(regex: regex(#"(?<![\d.,/-])(\d{1,2})([./-])(\d{1,2})\2(\d{4}|\d{2})(?![\d]|[.,/-]\d)"#)) { g, pivot in
            guard var day = Int(g[0]), var month = Int(g[2]), var year = Int(g[3]) else { return nil }
            if g[3].count == 2 { year += (year + 2000 <= pivot) ? 2000 : 1900 }
            if month > 12, day <= 12 { swap(&day, &month) }
            return CalendarDay(year: year, month: month, day: day)
        },
    ]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let fourDigitYear = regex(#"(?<!\d)\d{4}(?!\d)"#)
    private static let dayNumber = regex(#"(?<!\d)\d{1,2}(?!\d)"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Invalid date pattern \(pattern): \(error)")
        }
    }
}

/// Month names and abbreviations in English, Portuguese and Russian (all grammatical cases), lowercased.
enum MonthNames {
    private static let forms: [[String]] = [
        ["january", "jan", "janeiro", "январь", "января", "январе", "янв"],
        ["february", "feb", "fevereiro", "fev", "февраль", "февраля", "феврале", "февр", "фев"],
        ["march", "mar", "março", "marco", "март", "марта", "марте", "мар"],
        ["april", "apr", "abril", "abr", "апрель", "апреля", "апреле", "апр"],
        ["may", "maio", "mai", "май", "мая", "мае"],
        ["june", "jun", "junho", "июнь", "июня", "июне", "июн"],
        ["july", "jul", "julho", "июль", "июля", "июле", "июл"],
        ["august", "aug", "agosto", "ago", "август", "августа", "августе", "авг"],
        ["september", "sept", "sep", "setembro", "set", "сентябрь", "сентября", "сентябре", "сент", "сен"],
        ["october", "oct", "outubro", "out", "октябрь", "октября", "октябре", "окт"],
        ["november", "nov", "novembro", "ноябрь", "ноября", "ноябре", "нояб", "ноя"],
        ["december", "dec", "dezembro", "dez", "декабрь", "декабря", "декабре", "дек"],
    ]

    private static let lookup: [String: Int] = {
        var map: [String: Int] = [:]
        for (index, names) in forms.enumerated() {
            for name in names { map[name] = index + 1 }
        }
        return map
    }()

    /// Regex alternation of every form, longest first so `março` wins over `mar`.
    static let alternation: String = lookup.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        .map { NSRegularExpression.escapedPattern(for: $0) }
        .joined(separator: "|")

    static func month(for name: String) -> Int? {
        lookup[name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))]
    }
}
