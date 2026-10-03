import Foundation

/// The words that label a value in a document, as `EntityConfig` lists them (`Data de emissão`, `Customer number`,
/// `n. º. de cliente`, `договор * №`). Each is matched whatever its case, as it is written but for three rules, so that a
/// phrase holds each way it is written:
/// - a space matches any run of white space, and none at all beside a character that is neither a letter nor a digit
///   (`n. º. cliente` matches `nºcliente`, `клиент №` matches `клиент№`);
/// - a dot may be left out, as an abbreviation's often is (`n. º.` matches `nº`, `n.º` and `nº.`);
/// - `*` on its own is any one word, at most `maxAnyWords` of them in a phrase (`договор * №` matches `договор аренды №`).
public enum LabelPhrases {
    /// What stands for any one word in a phrase.
    public static let anyWord = "*"
    /// The words of its own a phrase holds at most, so a label stays close to its value.
    public static let maxAnyWords = 3

    /// A regular-expression alternation of `phrases`, the longest first so that the longest label written wins
    /// (`Data de nascimento` over `Data`); nil when there is none. With `endingWords`, a phrase that ends in a letter or a
    /// digit ends a word there (`договор n` is no start of `договор NDA`), and one that ends in a sign or a dot may run
    /// into what follows (`Policy #A1234567`).
    public static func alternation(_ phrases: [String], endingWords: Bool = false) -> String? {
        let parts = phrases.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .map { phrase in pattern(phrase) + (endingWords && endsWord(phrase) ? #"(?!\p{L})"# : "") }
        return parts.isEmpty ? nil : "(?:" + parts.joined(separator: "|") + ")"
    }

    /// What is wrong with `phrase` as a label, if anything: a phrase of `anyWord` alone would take every word for a
    /// label, and more than `maxAnyWords` of them would reach far from it.
    public static func problem(_ phrase: String) -> String? {
        let words = phrase.split(separator: " ")
        let anyWords = words.count { $0 == anyWord }
        if words.isEmpty { return "is empty" }
        if anyWords == words.count { return "has no word of its own besides \(anyWord)" }
        if anyWords > maxAnyWords { return "has more than \(maxAnyWords) of \(anyWord)" }
        return nil
    }

    /// Compiles a pattern built from phrases and the code's own constants, which cannot fail: every character of a
    /// phrase is escaped.
    public static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Invalid label pattern \(pattern): \(error)")
        }
    }

    /// One phrase as a pattern, by the rules above.
    private static func pattern(_ phrase: String) -> String {
        let words = phrase.split(separator: " ").map(String.init)
        var pattern = ""
        for (index, word) in words.enumerated() {
            if index > 0 {
                let previous = words[index - 1]
                let joinsSign = (previous != anyWord && !isLetterOrDigit(previous.last))
                    || (word != anyWord && !isLetterOrDigit(word.first))
                pattern += joinsSign ? #"\s*"# : #"\s+"#
            }
            pattern += word == anyWord ? #"\p{L}+"# : word.map { $0 == "." ? #"\.?"# : NSRegularExpression.escapedPattern(for: String($0)) }
                .joined()
        }
        return pattern
    }

    /// Whether `phrase` ends in a letter or a digit, so a letter after it would be part of its last word. The ordinal
    /// indicators, `º` and `ª`, are letters to Unicode but signs as they are written (`nºCT2024001`).
    private static func endsWord(_ phrase: String) -> Bool {
        guard let last = phrase.last else { return false }
        return isLetterOrDigit(last) && !ordinalIndicators.contains(last)
    }

    private static let ordinalIndicators: Set<Character> = ["º", "ª"]

    private static func isLetterOrDigit(_ character: Character?) -> Bool {
        character.map { $0.isLetter || $0.isNumber } ?? false
    }
}
