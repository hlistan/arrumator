import Foundation

/// A calendar day. Fixtures never read the clock; every date is spelled out in the content files.
struct Day: Sendable, Hashable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    init(_ year: Int, _ month: Int, _ day: Int) {
        precondition((1...12).contains(month) && (1...31).contains(day), "invalid day \(year)-\(month)-\(day)")
        self.year = year
        self.month = month
        self.day = day
    }

    static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Midnight UTC of this day.
    var date: Date {
        Day.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func adding(days: Int) -> Day {
        let shifted = Day.calendar.date(byAdding: .day, value: days, to: date)!
        let parts = Day.calendar.dateComponents([.year, .month, .day], from: shifted)
        return Day(parts.year!, parts.month!, parts.day!)
    }

    /// Last day of this day's month.
    var endOfMonth: Day {
        Day(year, month, Day.calendar.range(of: .day, in: .month, for: date)!.count)
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    // Portuguese
    var ptNumeric: String { String(format: "%02d/%02d/%04d", day, month, year) }
    var ptDashed: String { String(format: "%02d-%02d-%04d", day, month, year) }
    var ptMonthYear: String { "\(Months.pt[month - 1]) de \(year)" }
    var ptShort: String { String(format: "%02d/%02d", day, month) }

    // Russian
    var ruNumeric: String { String(format: "%02d.%02d.%04d", day, month, year) }
    /// "12 марта 1985 года", as printed on certificates.
    var ruWords: String { "\(day) \(Months.ruGenitive[month - 1]) \(year) года" }

    // English
    var enLong: String { "\(day) \(Months.en[month - 1]) \(year)" }
    var enUS: String { "\(Months.en[month - 1]) \(day), \(year)" }
    var enShort: String { String(format: "%02d %@ %04d", day, String(Months.en[month - 1].prefix(3)), year) }
}

/// A local wall-clock moment, e.g. for EXIF DateTimeOriginal and e-mail headers.
struct DateTimeStamp: Sendable, Hashable {
    let day: Day
    let hour: Int
    let minute: Int
    let second: Int
    /// Offset from UTC in minutes (Lisbon summer time = +60).
    let utcOffsetMinutes: Int

    init(_ day: Day, hour: Int, minute: Int, second: Int, utcOffsetMinutes: Int = 0) {
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.utcOffsetMinutes = utcOffsetMinutes
    }

    var exif: String {
        String(format: "%04d:%02d:%02d %02d:%02d:%02d", day.year, day.month, day.day, hour, minute, second)
    }

    var exifOffset: String {
        let sign = utcOffsetMinutes < 0 ? "-" : "+"
        return String(format: "%@%02d:%02d", sign, abs(utcOffsetMinutes) / 60, abs(utcOffsetMinutes) % 60)
    }

    var clock: String { String(format: "%02d:%02d", hour, minute) }

    /// RFC 5322 date, e.g. "Wed, 04 Mar 2026 10:12:44 +0000".
    var rfc5322: String {
        let weekday = Months.weekdays[Day.weekdayIndex(day)]
        let sign = utcOffsetMinutes < 0 ? "-" : "+"
        return String(format: "%@, %02d %@ %04d %02d:%02d:%02d %@%02d%02d", weekday, day.day,
                      String(Months.en[day.month - 1].prefix(3)), day.year, hour, minute, second,
                      sign, abs(utcOffsetMinutes) / 60, abs(utcOffsetMinutes) % 60)
    }

    /// Absolute instant (the wall clock minus its UTC offset).
    var date: Date {
        day.date.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second - utcOffsetMinutes * 60))
    }
}

extension Day {
    /// 0 = Sunday … 6 = Saturday (Zeller-free: count days from a known Sunday).
    static func weekdayIndex(_ day: Day) -> Int {
        let knownSunday = Day(2026, 1, 4).date
        let days = Int((day.date.timeIntervalSince(knownSunday) / 86_400).rounded())
        return ((days % 7) + 7) % 7
    }
}

enum Months {
    static let pt = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto",
                     "setembro", "outubro", "novembro", "dezembro"]
    static let ruNominative = ["январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август",
                               "сентябрь", "октябрь", "ноябрь", "декабрь"]
    static let ruGenitive = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа",
                             "сентября", "октября", "ноября", "декабря"]
    static let en = ["January", "February", "March", "April", "May", "June", "July", "August",
                     "September", "October", "November", "December"]
    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
}

/// An amount in minor units. Arithmetic stays exact; formatting follows each country's conventions.
struct Money: Sendable, Hashable, Comparable {
    let cents: Int

    init(cents: Int) { self.cents = cents }
    init(_ units: Int, _ cents: Int = 0) { self.cents = units * 100 + (units < 0 ? -cents : cents) }

    static let zero = Money(cents: 0)
    static func + (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents + rhs.cents) }
    static func - (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents - rhs.cents) }
    static prefix func - (value: Money) -> Money { Money(cents: -value.cents) }
    static func < (lhs: Money, rhs: Money) -> Bool { lhs.cents < rhs.cents }

    /// `rate` percent of this amount, rounded half away from zero.
    func percent(_ rate: Double) -> Money {
        Money(cents: Int((Double(cents) * rate / 100).rounded(.toNearestOrAwayFromZero)))
    }

    /// Unit price × quantity, rounded to cents.
    func times(_ quantity: Double) -> Money {
        Money(cents: Int((Double(cents) * quantity).rounded(.toNearestOrAwayFromZero)))
    }

    var units: Double { Double(cents) / 100 }

    private func grouped(thousands: String, decimal: String) -> String {
        let magnitude = abs(cents)
        var integer = String(magnitude / 100)
        var groups: [String] = []
        while integer.count > 3 {
            groups.insert(String(integer.suffix(3)), at: 0)
            integer = String(integer.dropLast(3))
        }
        groups.insert(integer, at: 0)
        return (cents < 0 ? "-" : "") + groups.joined(separator: thousands) + decimal + String(format: "%02d", magnitude % 100)
    }

    /// "1.234,56"
    var pt: String { grouped(thousands: ".", decimal: ",") }
    /// "1.234,56 €"
    var eurPT: String { pt + " €" }
    /// "1 234,56"
    var ru: String { grouped(thousands: " ", decimal: ",") }
    /// "1 234,56 руб."
    var rub: String { ru + " руб." }
    /// "1,234.56"
    var en: String { grouped(thousands: ",", decimal: ".") }
    /// "€1,234.56" / "-€1,234.56"
    var eurEN: String { (cents < 0 ? "-€" : "€") + Money(cents: abs(cents)).en }
    /// "£1,234.56"
    var gbp: String { (cents < 0 ? "-£" : "£") + Money(cents: abs(cents)).en }
    /// Plain decimal for spreadsheet cells: "1234.56".
    var decimal: String { (cents < 0 ? "-" : "") + "\(abs(cents) / 100)." + String(format: "%02d", abs(cents) % 100) }
}
