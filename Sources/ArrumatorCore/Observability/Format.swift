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

    /// Milliseconds as something readable: `8 ms`, `1.4 s`, `2 min 5 s`.
    public static func duration(_ milliseconds: Double) -> String {
        switch milliseconds {
        case ..<1_000: "\(Int(milliseconds.rounded())) ms"
        case ..<60_000: String(format: "%.1f s", milliseconds / 1_000)
        default: "\(Int(milliseconds / 60_000)) min \(Int((milliseconds / 1_000).truncatingRemainder(dividingBy: 60))) s"
        }
    }
}
