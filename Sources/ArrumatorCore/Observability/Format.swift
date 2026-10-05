import Foundation

/// Number and date formatting shared by the app and the command line, so both say the same thing the same way.
public enum Format {
    public static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    /// "1 document", "3 documents".
    public static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// "a", "a and b", "a, b and c": parts of a sentence, the same in every language the Mac is set to.
    public static func and(_ parts: [String]) -> String {
        guard let last = parts.last, parts.count > 1 else { return parts.last ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    public static func date(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
    }

    /// A date or deadline label, `YYYY-MM-DD`, as a day is shown in `locale`: "31 Jul 2026"; nil when it is no day.
    public static func day(_ value: String, locale: Locale) -> String? {
        guard let day = LabelDate(value), day.precision == .day else { return nil }
        return day.formatted(locale: locale)
    }

    /// A period label, `YYYY`, `YYYY-MM` or `YYYY-MM-DD`, or two of them as `start/end`, shown as `day(_:locale:)` shows a
    /// day, each bound to its own precision: "2026", "Jul 2026", "1 Jul 2026 – 31 Jul 2026" in `locale`; nil when it is
    /// no period.
    public static func period(_ value: String, locale: Locale) -> String? {
        let bounds = value.split(separator: "/", omittingEmptySubsequences: false).map { LabelDate(String($0)) }
        guard (1...2).contains(bounds.count) else { return nil }
        let shown = bounds.compactMap { $0?.formatted(locale: locale) }
        return shown.count == bounds.count ? shown.joined(separator: rangeSeparator) : nil
    }

    /// The month of a date label, `YYYY-MM-DD` or `YYYY-MM`, in the Gregorian calendar it is written in, as a heading of
    /// the documents of that month is shown in `locale`: "July 2026"; nil when it names no month.
    public static func month(_ value: String, locale: Locale) -> String? {
        guard let label = LabelDate(value), label.precision != .year else { return nil }
        return label.date.formatted(LabelDate.wideMonth(locale: locale))
    }

    /// Between the start and the end of a period shown.
    public static let rangeSeparator = " – "

    /// Milliseconds as something readable: `8 ms`, `1.4 s`, `2 min 5 s`.
    public static func duration(_ milliseconds: Double) -> String {
        switch milliseconds {
        case ..<1_000: "\(Int(milliseconds.rounded())) ms"
        case ..<60_000: String(format: "%.1f s", milliseconds / 1_000)
        default: "\(Int(milliseconds / 60_000)) min \(Int((milliseconds / 1_000).truncatingRemainder(dividingBy: 60))) s"
        }
    }
}

/// A date a label writes in ISO 8601, `YYYY`, `YYYY-MM` or `YYYY-MM-DD`, to the precision it is written to. A label
/// names a Gregorian day, so it is read and shown in the Gregorian calendar, at midnight in one zone, which names the
/// same day wherever the user is.
private struct LabelDate {
    enum Precision { case year, month, day }

    let date: Date
    let precision: Precision

    /// The digits of a year, a month and a day, in that order.
    private static let widths = [4, 2, 2]

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...Self.widths.count).contains(parts.count),
              zip(parts, Self.widths).allSatisfy({ part, width in part.count == width && part.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        var components = DateComponents()
        components.year = Int(parts[0])
        components.month = parts.count > 1 ? Int(parts[1]) : 1
        components.day = parts.count > 2 ? Int(parts[2]) : 1
        guard components.isValidDate(in: Self.calendar), let date = Self.calendar.date(from: components) else { return nil }
        self.date = date
        precision = parts.count == 1 ? .year : parts.count == 2 ? .month : .day
    }

    /// A month in full and its year in `locale`, in the Gregorian calendar a label is written in.
    static func wideMonth(locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt).month(.wide).year()
    }

    func formatted(locale: Locale) -> String {
        switch precision {
        case .year: date.formatted(Date.FormatStyle(locale: locale, calendar: Self.calendar, timeZone: .gmt).year())
        case .month: date.formatted(Date.FormatStyle(locale: locale, calendar: Self.calendar, timeZone: .gmt).month(.abbreviated).year())
        case .day: date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: Self.calendar, timeZone: .gmt))
        }
    }
}
