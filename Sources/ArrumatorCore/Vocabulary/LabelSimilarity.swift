import Foundation

/// How alike two labels of one kind are written, from 0 to 1.
///
/// A number is what tells one account, invoice or address from the next, so the numbers are compared first, each as it
/// is written and in the order they are written. A number is a run of digits that only spaces break: an identifier
/// printed in groups is the one typed without them (`PT50 0002 0123` is `PT5000020123`, `123 456 789` is `123456789`),
/// while punctuation and letters end a number (`1/23` is two numbers, `A1B2` too). Labels whose numbers differ are never
/// alike, 0 (`FT 1/23` is not `FT 12/3`, nor `Rua das Flores 12, 3` the same as `Rua das Flores 3, 12`). The same digits
/// in the same order, which punctuation bounds in one label where the other runs on (`V/2026/532774` and
/// `V2026532774`), are no degree of likeness but a relation of their own: perhaps one number written two ways, perhaps
/// two, which only the user can tell (`Key.isRegrouping(of:)`, `lookAlike`).
///
/// Labels with the same numbers written the same way but for case, accents, punctuation, spacing or the order of their
/// words (`EDP-Comercial, S.A.` and `edp comercial SA`, `Silva, Maria` and `Maria Silva`) are the same label, 1. Words
/// change places only between two numbers, or between a number and an end, never across a number (`car AA-12-BB` is
/// not `car BB-12-AA`), and a word keeps its letters and digits in their order (`car AB12CD` is not `car CD12AB`).
/// Anything else is compared by the Jaro-Winkler similarity of its words so ordered, the measure record linkage uses for
/// names (Winkler 1990; docs/organizing-principles-sources.md), which forgives a typo, a missing letter or swapped
/// letters, and weighs the start of a name most.
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

    /// Up to `limit` of `others`, the most alike to `value` first, and of those as alike, in the order given: what a
    /// label is offered to be merged into. `value` itself is never among them.
    public static func mostAlike(to value: String, among others: [String], limit: Int) -> [String] {
        let key = Key(value)
        let scored = others.enumerated().filter { $0.element != value }.map { (place: $0.offset, value: $0.element, score: similarity(key, Key($0.element))) }
        let ordered = scored.sorted { ($0.score, -$0.place) > ($1.score, -$1.place) }
        return Array(ordered.prefix(max(0, limit)).map(\.value))
    }

    /// Whether the two are one label written two ways.
    public static func sameWriting(_ a: String, _ b: String) -> Bool {
        Key(a).isSameWriting(as: Key(b))
    }

    static func similarity(_ a: Key, _ b: Key) -> Double {
        guard a.numbers == b.numbers else { return 0 }
        return a.isSameWriting(as: b) ? 1 : jaroWinkler(a.sorted, b.sorted)
    }

    /// `similarity(a, b)` when it is at least `threshold`, nil when it is less. Jaro-Winkler, the one costly step, is
    /// worked out only where it could reach the threshold: never at 1, which only labels written the same way reach, nor
    /// for lengths too far apart (`bound`).
    static func similarity(_ a: Key, _ b: Key, atLeast threshold: Double) -> Double? {
        let similarity: Double
        if a.numbers != b.numbers {
            similarity = 0
        } else if a.isSameWriting(as: b) {
            similarity = 1
        } else if threshold >= 1 || bound(a, b) < threshold {
            return nil
        } else {
            similarity = jaroWinkler(a.sorted, b.sorted)
        }
        return similarity >= threshold ? similarity : nil
    }

    /// Why two labels look alike enough to be offered as one, and how alike they are written.
    struct LookAlike: Sendable, Hashable {
        let similarity: Double
        let reason: LabelSuggestion.Reason
    }

    /// Whether `a` and `b` are offered to the user as one: when they are written at least `threshold` alike, or, whatever
    /// the threshold, when they hold the same digits grouped otherwise, with how alike they are written but for where
    /// their numbers end. Nil when neither.
    static func lookAlike(_ a: Key, _ b: Key, atLeast threshold: Double) -> LookAlike? {
        guard a.isRegrouping(of: b) else {
            return similarity(a, b, atLeast: threshold).map { LookAlike(similarity: $0, reason: .writtenAlike) }
        }
        let similarity = a.joined == b.joined || a.sorted == b.sorted ? 1 : jaroWinkler(a.sorted, b.sorted)
        return LookAlike(similarity: similarity, reason: .sameDigitsGroupedOtherwise)
    }

    /// The most two keys could score, from their lengths alone: Jaro counts at most the shorter one's characters as
    /// matches, and Winkler's bonus is at most `maxPrefix` of them. Lets a search skip pairs that cannot reach a threshold.
    static func bound(_ a: Key, _ b: Key) -> Double {
        let (short, long) = (Double(min(a.sorted.count, b.sorted.count)), Double(max(a.sorted.count, b.sorted.count)))
        guard long > 0 else { return 1 }
        let jaro = (1 + short / long + 1) / 3
        return jaro + Double(maxPrefix) * prefixScale * (1 - jaro)
    }

    /// A label as it is compared, folded to lowercase without accents or width: its numbers, its letters and digits, and
    /// its words, as spaces and punctuation separate them.
    struct Key: Sendable, Hashable {
        /// The numbers, in the order they are written: each a run of digits that only spaces break, so `PT50 0002` holds
        /// one, `1/23` two and `A1B2` two.
        let numbers: [String]
        /// Every digit, in the order written: labels whose digits differ are never alike.
        let digits: String
        /// The letters and digits one after the other, with nothing between them (`S.A.` is `sa`, `PT50 0002` is
        /// `pt500002`): with the same numbers, the same label however it is spaced and punctuated.
        let joined: String
        /// The words in sorted order within each stretch that numbers bound, a space between each: what is alike however
        /// the words are ordered, as long as none moves across a number (`car AB 12 CD` is not `car CD 12 AB`). A word
        /// keeps its letters and digits in their order, so `AB12CD` never becomes `CD12AB`; a label without numbers is one
        /// stretch, its words in any order.
        let sorted: [Character]

        init(_ text: String) {
            let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            var numbers: [String] = []
            // The last letter or digit was a digit, and only spaces have come since: a digit now goes on its number.
            var inNumber = false
            for character in folded {
                if character.isNumber {
                    if inNumber { numbers[numbers.count - 1].append(character) } else { numbers.append(String(character)) }
                    inNumber = true
                } else if !character.isWhitespace {
                    inNumber = false
                }
            }
            self.numbers = numbers
            digits = numbers.joined()
            joined = String(folded.filter { $0.isLetter || $0.isNumber })
            // Each stretch of words between two numbers, or between a number and an end, in sorted order; the words
            // that hold a number where they are.
            var words: [String] = []
            var stretch: [String] = []
            for word in Self.words(folded) {
                guard word.contains(where: \.isNumber) else {
                    stretch.append(word)
                    continue
                }
                words += stretch.sorted() + [word]
                stretch = []
            }
            sorted = Array((words + stretch.sorted()).joined(separator: " "))
        }

        /// The words of `text`, as spaces and punctuation separate them, but for spaces between two digits, which part
        /// no number (`numbers`): `PT50 0002 0123` is one word, `pt5000020123`, as it is one number.
        private static func words(_ text: String) -> [String] {
            var words: [String] = []
            var word = ""
            // Something other than a letter or a digit has come since the last one, and whether it was only spaces.
            var separated = false
            var onlySpaces = true
            for character in text {
                guard character.isLetter || character.isNumber else {
                    separated = true
                    onlySpaces = onlySpaces && character.isWhitespace
                    continue
                }
                if separated, !(onlySpaces && character.isNumber && word.last?.isNumber == true), !word.isEmpty {
                    words.append(word)
                    word = ""
                }
                word.append(character)
                (separated, onlySpaces) = (false, true)
            }
            return word.isEmpty ? words : words + [word]
        }

        /// One label written two ways: the same numbers, and the same letters and digits or the same words in sorted
        /// order.
        func isSameWriting(as other: Key) -> Bool {
            numbers == other.numbers && (joined == other.joined || sorted == other.sorted)
        }

        /// Whether `other` has the same digits in the same order in other numbers, where one label's numbers end only
        /// where the other's do: one number written with punctuation between its groups and without
        /// (`V/2026/532774`, `V2026532774`), never two numbers that end in different places (`FT 1/23`, `FT 12/3`).
        func isRegrouping(of other: Key) -> Bool {
            guard numbers != other.numbers, digits == other.digits else { return false }
            let (mine, theirs) = (ends, other.ends)
            return mine.isSubset(of: theirs) || theirs.isSubset(of: mine)
        }

        /// Where each number but the last ends, counted in digits from the first.
        private var ends: Set<Int> {
            var counted = 0
            return Set(numbers.dropLast().map { number in
                counted += number.count
                return counted
            })
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
