import Foundation

/// Fixed conversions between units, facts of the calendar and of binary prefixes rather than anything to tune.
public enum Units {
    public static let secondsPerMinute: Double = 60
    public static let secondsPerHour: Double = 3_600
    public static let secondsPerDay: Double = 86_400
    public static let millisecondsPerSecond: Double = 1_000
    /// A gibibyte, the unit Finder and `df -g` call a gigabyte.
    public static let bytesPerGigabyte: Double = 1_073_741_824
}

extension Date {
    /// Milliseconds from this date to `end`, as traces and logs record durations.
    public func milliseconds(until end: Date) -> Double { end.timeIntervalSince(self) * Units.millisecondsPerSecond }
}
