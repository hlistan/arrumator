import ArrumatorCore
import Foundation
import Testing

/// Dates labels write in ISO 8601 are shown as dates are read, a period as its days are, so a card never says
/// "31 Jul 2026" above "2026-07-01/2026-07-31" (docs/using-arrumator.md).
@Suite struct FormatTests {
    /// A locale of the test's own, so what is shown does not depend on the Mac's.
    static let british = Locale(identifier: "en_GB")

    @Test func aPeriodIsShownAsItsDaysAreEachBoundToItsOwnPrecision() {
        #expect(Format.day("2026-07-31", locale: Self.british) == "31 Jul 2026", "a date label as a day is shown")
        let shown: [(String, String)] = [
            ("2026-07-01/2026-07-31", "1 Jul 2026 – 31 Jul 2026"),
            ("2026-07", "Jul 2026"),
            ("2026", "2026"),
            ("2025/2026-03", "2025 – Mar 2026"),
            ("2026-07-15", "15 Jul 2026"),
        ]
        for (period, words) in shown {
            #expect(Format.period(period, locale: Self.british) == words, "\(period): each bound to its precision, as a day is shown")
        }
        let bounds = ["2026-07-01", "2026-07-31"].compactMap { Format.day($0, locale: Self.british) }
        #expect(Format.period("2026-07-01/2026-07-31", locale: Self.british) == bounds.joined(separator: Format.rangeSeparator),
                "a period's days are shown just as a date's day is, one formatter for both")
    }

    @Test(arguments: ["2026-13-45", "2026-02-30", "26-07-01", "2026-7", "2026/2026/2027", "/2026", "2026/", "", "٢٠٢٦", "2026-07-01T10:00"])
    func whatIsNoPeriodIsNotShownAsOne(value: String) {
        #expect(Format.period(value, locale: Self.british) == nil, "“\(value)” is no period, so it is shown as written")
    }

    @Test func aDateLabelIsADayAndNothingElse() {
        #expect(Format.day("2026-07", locale: Self.british) == nil, "a month is no date")
        #expect(Format.day("2026-02-29", locale: Self.british) == nil, "nor a day 2026 has not")
        #expect(Format.day("2028-02-29", locale: Self.british) == "29 Feb 2028", "one a leap year has is")
    }

    @Test func aDayIsShownInTheGregorianCalendarItIsWrittenIn() {
        let buddhist = Locale(identifier: "en_GB@calendar=buddhist")
        #expect(Format.day("2026-07-31", locale: buddhist) == "31 Jul 2026",
                "a label names a Gregorian day, which a Mac set to another calendar is shown as written, never as 2569")
    }

    @Test func theMonthOfADateIsShownInTheGregorianCalendarItIsWrittenIn() {
        let buddhist = Locale(identifier: "en_GB@calendar=buddhist")
        #expect(Format.month("2026-07-31", locale: buddhist) == "July 2026",
                "the heading the documents of July 2026 are listed under, on a Mac set to the Buddhist calendar, says 2026 as their cards do")
        #expect(Format.month("2026-07", locale: Self.british) == "July 2026", "a month is a month")
        #expect(Format.month("2026", locale: Self.british) == nil && Format.month("2026-13-01", locale: Self.british) == nil,
                "a year alone has no month, and what is no date none")
    }
}
