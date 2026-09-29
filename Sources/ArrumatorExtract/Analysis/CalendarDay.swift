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

    /// The day `date` falls on in `calendar`'s time zone.
    public init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 0
        month = components.month ?? 0
        day = components.day ?? 0
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
