import Foundation

/// Case-, diacritic- and punctuation-insensitive text for keyword and alias matching (EN/RU/PT).
public enum TextNormalizer {
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    /// Normalised text padded with spaces so whole-word phrases can be found with `contains(" phrase ")`.
    public static func padded(_ s: String) -> String { " " + normalize(s) + " " }

    /// Case-sensitive whole-word match on raw text, for short ambiguous tokens like "AT" or "NOS".
    public static func containsExactWord(_ text: String, _ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
    }
}
