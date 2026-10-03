import ArrumatorCore
import Foundation

/// A validated Gregorian calendar day without time or time zone.
public struct CalendarDay: Sendable, Hashable, Encodable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Returns `nil` for impossible days (31 February, month 13, …).
    public init?(year: Int, month: Int, day: Int) {
        let components = DateComponents(calendar: Self.gregorian, year: year, month: month, day: day)
        guard components.isValidDate else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// A day a Gregorian calendar gave, which needs no check.
    fileprivate init(reckoned year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// ISO `YYYY-MM-DD`.
    public var iso: String {
        let yyyy = String(year).leftPadded(to: 4)
        let mm = String(month).leftPadded(to: 2)
        let dd = String(day).leftPadded(to: 2)
        return "\(yyyy)-\(mm)-\(dd)"
    }

    public var description: String { iso }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }

    private static let gregorian = Calendar(identifier: .gregorian)
}

/// The Gregorian calendar in one time zone, which every day extraction reads, weighs or writes is reckoned in. ISO 8601
/// days, and the dates the model is shown and gives back, are Gregorian, whatever calendar the Mac shows: on a Mac set to
/// the Buddhist calendar, the system's own calendar puts 2026 in 2569. The registry makes one for each file it reads,
/// in the Mac's time zone at that moment.
public struct GregorianCalendar: Sendable {
    private let calendar: Calendar

    public init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// The day `date` falls on in this calendar's time zone.
    public func day(of date: Date) -> CalendarDay {
        CalendarDay(reckoned: year(of: date), month: calendar.component(.month, from: date),
                    day: calendar.component(.day, from: date))
    }

    public func year(of date: Date) -> Int {
        calendar.component(.year, from: date)
    }
}

/// A date read from file metadata (EXIF, PDF info dictionary, media capture) rather than from the text.
public struct MetadataDate: Sendable, Hashable, Encodable {
    public var day: CalendarDay
    public var source: DateSource
    /// Where the date came from, e.g. `EXIF DateTimeOriginal`.
    public var label: String

    public init(day: CalendarDay, source: DateSource, label: String) {
        self.day = day
        self.source = source
        self.label = label
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
