import Foundation

/// A full calendar date found in text, with its position (UTF-16 offsets into the scanned string).
public struct DateCandidate: Sendable, Hashable, Encodable {
    public var day: CalendarDay
    public var location: Int
    public var length: Int
    public var matched: String

    public var end: Int { location + length }
}

/// Finds full dates in text of any language: a day, a month named in any language in any of its forms and a year
/// (`15 мая 2024 г.`, `20 de maio de 2026`, `May 20, 2026`, `3. März 2025`), year-month-day with CJK markers
/// (`2025年3月5日`, `2025년 3월 5일`), ISO `YYYY-MM-DD`, and numeric dates, day first (`15.05.2024`, `15/05/24`,
/// `24. 9. 2026`, each end of `01/03/2024-31/03/2024`) or year first with dots and spaces (`2026. 9. 7.`), in the decimal
/// digits of any script (`٢٠/٠٥/٢٠٢٦`), and day first with spaces as an identity card prints it (`01 02 2025`). Every
/// day is Gregorian.
/// Month-first numeric dates are accepted only when day-first is impossible. `NSDataDetector` adds any remaining date
/// expressions that carry both a day number and a four-digit year.
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
                let groups = (1..<match.numberOfRanges).map { index -> String in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? "" : ns.substring(with: range)
                }
                // A word that is no month leaves the text to the other patterns.
                if let word = pattern.monthWord, MonthNames.month(for: groups[word]) == nil { continue }
                claimed.append(match.range)
                guard let day = pattern.day(groups, twoDigitYearPivot) else { continue }
                accepted.append(DateCandidate(day: day, location: match.range.location, length: match.range.length,
                                              matched: ns.substring(with: match.range)))
            }
        }
        for match in Self.detector.matches(in: text, range: full) where !overlaps(match.range) {
            let matched = ns.substring(with: match.range)
            // Month-year phrases ("May 2024") come back as the 1st of the month; only full dates count.
            let matchedRange = NSRange(location: 0, length: (matched as NSString).length)
            guard let date = match.date, Self.fourDigitYear.firstMatch(in: matched, range: matchedRange) != nil,
                  Self.dayNumber.firstMatch(in: matched, range: matchedRange) != nil else {
                continue
            }
            // The detector reads a date written without a zone in the process's time zone, so its day is read there.
            let day = GregorianCalendar(timeZone: match.timeZone ?? TimeZone.current).day(of: date)
            accepted.append(DateCandidate(day: day, location: match.range.location, length: match.range.length,
                                          matched: matched))
        }
        return accepted.sorted { $0.location < $1.location }
    }

    // MARK: Patterns

    private struct Pattern: Sendable {
        let regex: NSRegularExpression
        /// The group holding a word that must be a month for the match to count.
        var monthWord: Int?
        let day: @Sendable ([String], Int) -> CalendarDay?
    }

    private static let patterns: [Pattern] = [
        // «15» мая 2024 г. | 20 de maio de 2026 | 1st of May 2024 | 3. März 2025 | 1er avril 2025 | 15-mai-2024
        Pattern(regex: regex(#"(?<![\p{L}\p{N}])["«“]?(\d{1,2})(?:st|nd|rd|th|er|e|º|°|-?го|-?е)?["»”]?[\s./-]*"#
                             + #"(?:de\s+|of\s+)?(\p{L}+)\.?,?[\s./-]*(?:de\s+)?(\d{4})(?!\d)"#), monthWord: 1) { g, _ in
            guard let day = number(g[0]), let month = MonthNames.month(for: g[1]), let year = number(g[2]) else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        },
        // May 20, 2026 | Sept. 3 2025
        Pattern(regex: regex(#"(?<![\p{L}\p{N}])(\p{L}+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?!\d)"#), monthWord: 0) { g, _ in
            guard let month = MonthNames.month(for: g[0]), let day = number(g[1]), let year = number(g[2]) else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        },
        // 2025年3月5日 | 2025년 3월 5일
        Pattern(regex: regex(#"(?<!\d)(\d{4})\s*[年년]\s*(\d{1,2})\s*[月월]\s*(\d{1,2})\s*[日일]"#)) { g, _ in
            guard let year = number(g[0]), let month = number(g[1]), let day = number(g[2]) else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        },
        // 2026. 9. 7. (year first, as Hungarian or Korean write it; before day first, which would read its end)
        Pattern(regex: regex(#"(?<![\d.,/-])(\d{4})\.\h(\d{1,2})\.\h(\d{1,2})\.?(?!\d)"#)) { g, _ in
            guard let year = number(g[0]), let month = number(g[1]), let day = number(g[2]) else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        },
        // 24. 9. 2026 (day first, as Czech, Slovak or German write it)
        Pattern(regex: regex(#"(?<![\d.,/-])(\d{1,2})\.\h(\d{1,2})\.\h(\d{4})(?!\d)"#)) { g, _ in
            guard let day = number(g[0]), let month = number(g[1]), let year = number(g[2]) else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        },
        // 01 02 2025 (day first, spaced, as identity cards and permits print it: two digits each, and a four-digit year)
        Pattern(regex: regex(#"(?<![\d.,/-]|\d\h)(\d{2})\h(\d{2})\h(\d{4})(?!\d|\h\d)"#)) { g, _ in
            guard let day = number(g[0]), let month = number(g[1]), let year = number(g[2]) else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        },
        // 2026-05-20 | 2026.05.20 | 2026/05/20
        Pattern(regex: regex(#"(?<![\d.,/-])(\d{4})([-./])(\d{1,2})\2(\d{1,2})(?![\d])"#)) { g, _ in
            guard let year = number(g[0]), let month = number(g[2]), let day = number(g[3]) else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        },
        // 20.05.2026 | 20/05/26 | 20-05-2026 (day first; month first only when the first number exceeds 12), and each
        // end of a range written without spaces, 01/03/2024-31/03/2024
        Pattern(regex: regex(#"(?:(?<![\d.,/-])|(?<=[./-]\d{2}-|[./-]\d{4}-))(\d{1,2})([./-])(\d{1,2})\2(\d{4}|\d{2})"#
                             + #"(?:(?![\d]|[.,/-]\d)|(?=-\d{1,2}\2\d{1,2}\2\d))"#)) { g, pivot in
            guard var day = number(g[0]), var month = number(g[2]), var year = number(g[3]) else { return nil }
            if g[3].count == 2 { year += (year + 2000 <= pivot) ? 2000 : 1900 }
            if month > 12, day <= 12 { swap(&day, &month) }
            return CalendarDay(year: year, month: month, day: day)
        },
    ]

    private static let detector: NSDataDetector = {
        do {
            return try NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        } catch {
            preconditionFailure("No date detector: \(error)")
        }
    }()
    private static let fourDigitYear = regex(#"(?<!\d)\d{4}(?!\d)"#)
    private static let dayNumber = regex(#"(?<!\d)\d{1,2}(?!\d)"#)

    /// The number `digits` writes, in the decimal digits of any script (`٢٠٢٦`, `२०२६`, `２０２６`), as `\d` matches them;
    /// `Int(_:)` reads ASCII digits alone.
    private static func number(_ digits: String) -> Int? {
        guard !digits.isEmpty else { return nil }
        var value = 0
        for character in digits {
            guard let digit = character.wholeNumberValue, (0...9).contains(digit) else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Invalid date pattern \(pattern): \(error)")
        }
    }
}

/// Month names in every language the system knows, in each form its calendar writes them (full and short, as in a
/// date and on their own, such as Russian `мая` and `май`), lowercased and without accents or a final dot. A word
/// that names different months in different languages (`listopad`) names none.
enum MonthNames {
    private static let lookup: [String: Int] = {
        var months: [String: Set<Int>] = [:]
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        for identifier in Locale.availableIdentifiers {
            formatter.locale = Locale(identifier: identifier)
            for names in [formatter.monthSymbols, formatter.shortMonthSymbols, formatter.standaloneMonthSymbols,
                          formatter.shortStandaloneMonthSymbols] {
                for (index, name) in (names ?? []).enumerated() {
                    let key = folded(name)
                    // Numbered months (`1月`, `tháng 1`) are read as numbers, not names.
                    guard !key.isEmpty, key.allSatisfy(\.isLetter) else { continue }
                    months[key, default: []].insert(index + 1)
                }
            }
        }
        return months.compactMapValues { $0.count == 1 ? $0.first : nil }
    }()

    static func month(for name: String) -> Int? {
        lookup[folded(name)]
    }

    private static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
