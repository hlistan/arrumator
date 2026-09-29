import Foundation

enum TextNormalizer {
    /// NFC, `\n` line endings, form feeds as paragraph breaks, other control characters removed, trailing spaces
    /// trimmed and runs of blank lines collapsed to one.
    static func normalize(_ text: String) -> String {
        let unified = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0C}", with: "\n\n")
        let cleanedScalars = unified.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(CharacterSet.controlCharacters.contains(scalar)
                || scalar == "\u{FEFF}")
        }
        var lines: [Substring] = []
        var blankRun = 0
        for line in String(String.UnicodeScalarView(cleanedScalars)).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingTrailingWhitespace()
            if trimmed.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps at most `maxChars` characters. Returns whether anything was cut.
    static func cap(_ text: String, maxChars: Int) -> (text: String, truncated: Bool) {
        guard maxChars > 0, text.count > maxChars else { return (text, false) }
        return (String(text.prefix(maxChars)), true)
    }

    /// A single-line preview for traces and logs.
    static func preview(_ text: String, maxChars: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > maxChars ? String(flat.prefix(maxChars)) + "…" : flat
    }

    /// Non-empty lines, the paragraph measure used for text formats without explicit structure.
    static func nonEmptyLineCount(_ text: String) -> Int {
        text.split(separator: "\n").count { !$0.allSatisfy(\.isWhitespace) }
    }
}

extension Substring {
    func trimmingTrailingWhitespace() -> Substring {
        var end = endIndex
        while end > startIndex, let previous = self[..<end].last, previous.isWhitespace {
            end = index(before: end)
        }
        return self[startIndex..<end]
    }
}
