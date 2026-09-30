import Foundation

/// How alike two labels of one kind are written, from 0 to 1. Labels written the same way but for case, accents,
/// punctuation, spacing or the order of their words (`EDP-Comercial, S.A.` and `edp comercial SA`, `Silva, Maria` and
/// `Maria Silva`) are the same label, 1. Labels whose numbers differ are never alike, 0: a number is what tells one
/// account, invoice or address from the next. Anything else is compared by the Jaro-Winkler similarity of its words in
/// sorted order, the measure record linkage uses for names (Winkler 1990; docs/organizing-principles-sources.md), which
/// forgives a typo, a missing letter or swapped letters, and weighs the start of a name most.
///
/// Only writing is compared, never meaning: that one label is another in other words is the model's judgment, or the
/// user's.
public enum LabelSimilarity {
    /// Winkler's scaling factor for a common prefix, and the longest prefix it rewards: part of the measure's definition.
    static let prefixScale = 0.1
    static let maxPrefix = 4

    public static func similarity(_ a: String, _ b: String) -> Double {
        similarity(Key(a), Key(b))
    }

    /// Whether the two are one label written two ways.
    public static func sameWriting(_ a: String, _ b: String) -> Bool {
        Key(a).isSameWriting(as: Key(b))
    }

    static func similarity(_ a: Key, _ b: Key) -> Double {
        if a.isSameWriting(as: b) { return 1 }
        guard a.numbers == b.numbers else { return 0 }
        return jaroWinkler(a.sorted, b.sorted)
    }

    /// The most two keys could score, from their lengths alone: Jaro counts at most the shorter one's characters as
    /// matches, and Winkler's bonus is at most `maxPrefix` of them. Lets a search skip pairs that cannot reach a threshold.
    static func bound(_ a: Key, _ b: Key) -> Double {
        let (short, long) = (Double(min(a.sorted.count, b.sorted.count)), Double(max(a.sorted.count, b.sorted.count)))
        guard long > 0 else { return 1 }
        let jaro = (1 + short / long + 1) / 3
        return jaro + Double(maxPrefix) * prefixScale * (1 - jaro)
    }

    /// A label as it is compared: its words and numbers, folded to lowercase without accents or width.
    struct Key: Sendable, Hashable {
        let words: [String]
        let numbers: [String]
        let sorted: [Character]

        init(_ text: String) {
            let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            numbers = folded.split { !$0.isNumber }.map(String.init)
            sorted = Array(words.sorted().joined(separator: " "))
        }

        func isSameWriting(as other: Key) -> Bool {
            words.joined() == other.words.joined() || sorted == other.sorted
        }
    }

    /// Jaro similarity with Winkler's prefix bonus (Winkler 1990), over characters.
    static func jaroWinkler(_ a: [Character], _ b: [Character]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty && b.isEmpty ? 1 : 0 }
        let window = max(0, max(a.count, b.count) / 2 - 1)
        var aMatched = [Bool](repeating: false, count: a.count)
        var bMatched = [Bool](repeating: false, count: b.count)
        var matches = 0
        for i in a.indices {
            let lower = max(0, i - window)
            let upper = min(b.count - 1, i + window)
            guard lower <= upper else { continue }
            for j in lower...upper where !bMatched[j] && a[i] == b[j] {
                aMatched[i] = true
                bMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        var halfTranspositions = 0
        var k = 0
        for i in a.indices where aMatched[i] {
            while !bMatched[k] { k += 1 }
            if a[i] != b[k] { halfTranspositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - Double(halfTranspositions) / 2) / m) / 3
        let prefix = zip(a, b).prefix(maxPrefix).prefix { $0 == $1 }.count
        return jaro + Double(prefix) * prefixScale * (1 - jaro)
    }
}
