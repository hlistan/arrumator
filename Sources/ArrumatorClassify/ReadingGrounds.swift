import ArrumatorCore
import Foundation
import NaturalLanguage

/// What a reading is checked against: the document's own words, its text, the e-mail's sender and subject, and what the
/// vision model saw in it, and how the archive's owner wants labels written. Words are told apart as NaturalLanguage
/// tells them (`NLTokenizer`, AGENTS.md §4.5) and folded (`key`), and a word the document breaks is read whole: a run of
/// letters it spaces out one by one ("E D P  C O M E R C I A L"), and one a soft hyphen or a hyphen at the end of a line
/// ("Comer-\ncial") breaks. Words are never joined across the spaces between them, so a short name is not found across
/// two words ("EDP" in "Estimated payment").
///
/// A name the document writes is in its words: each of its words of `letters` letters or more (each of them, when it has
/// none that long), however it is cased, accented or written in width, as a word of the document or inside one, as a
/// name declined or written without spaces is. Every such word, not only the longest: "EDP Comercial" is not written by
/// "Banco Comercial Português". A name of several words the document writes as an abbreviation in capitals, the initials
/// of its words, is in its words too (`initials`): "Социальный фонд России" on a card that prints СФР, "HM Passport
/// Office" on a passport that prints HMPO, wherever it stands as a word of its own. Initials shorter than `letters`, so
/// many words and legal forms in capitals ("SA" after "EDP Comercial"), ground only a name with a word for each letter,
/// and only where the abbreviation begins a line, as a letterhead or heading writes it ("AT - Nota de cobrança"). A name
/// that only the archive's labels, the file's name or the model's own knowledge give, such as the sender most of the
/// archive's documents have, is not, unless it is how the owner wants a name the document writes written: any of the
/// owner's merges (`LabelGuidance.preferred`), not only those the prompt shows.
public struct ReadingGrounds: Sendable {
    /// The document's words, folded (`key`), a run of single letters also as the word it spells.
    let words: Set<String>
    /// The abbreviations the document writes, folded: its words all in capitals of `letters` letters or more, and those
    /// of two letters or more that begin a line.
    let abbreviations: Set<String>
    /// The letters a word needs to say on its own whether the document writes a name or a title (`labels.groundingLetters`).
    let letters: Int
    let preferred: [LabelPreference]
    /// Whether the document writes a day with its year: one the extractor finds in its text (`Entities.dates`), one the
    /// vision model saw in it, or an e-mail's own date; nil when it has neither text nor a date seen to tell by, as an
    /// image nothing was read of, which is not checked. Only whether it writes one is told, never which: a date written
    /// month first, or in another calendar, the extractor may read as another day.
    let writesADay: Bool?
    /// The runs of digits the document writes, which a date's year is told by (`writesYear(of:)`), however the day around
    /// it is written.
    let digitRuns: Set<Substring>
    /// The numbers the document writes, each by its digits without the zeros that begin it (`number(of:)`): every run of
    /// up to `labels.numberWords` words with digits that follow one another on a line, as `0123 456 789`, `1ESY 1160
    /// 4478 21` or `FT EDPC2026/926804564` write one number over several words. Whole words only: digits inside another
    /// number are none, so `DE 812871812` writes no `12`.
    let numbers: Set<String>
    /// What the document writes with digits, each by its letters and digits as names are compared (`spelled(_:)`): every
    /// run of up to `labels.numberWords` words that follow one another on a line and hold a digit, as `NL91 ABNA 0417 1643
    /// 00` writes an IBAN, which a machine writes unbroken, over a group of letters no number crosses.
    let writings: Set<String>
    /// How the document lays out its words and writes them, in the language it is written in.
    let layout: DocumentLayout

    /// The ISO 639-1 code of the language the document is written in, nil when that is not known.
    var language: String? { layout.language }

    /// The grounds of a reading of `content`. How it lays out and writes its words (`layout`) is read from its own text
    /// and the e-mail's sender and subject alone: what the vision model wrote of it is prose of the model's, which tells
    /// nothing of how the document writes a word.
    /// What the vision model saw is what the prompt shows of it (`ExtractedContent.classificationExcerpt`): its
    /// description, the text it read, and the organisations it named.
    public init(content: ExtractedContent, guidance: LabelGuidance, labels: LabelsConfig) {
        let visual = content.visual.map { [$0.description, $0.visibleTextSummary] + $0.organisations } ?? []
        let mail = [MetadataKey.emailFrom, MetadataKey.emailSubject].compactMap { content.metadata[$0] }
        let written = !content.entities.dates.isEmpty || content.metadata[MetadataKey.emailDate] != nil
            || content.visual?.dates.contains { DocumentLabel.normalized($0, kind: .date) != nil } == true
        let blank = content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let language = content.language.primary
        let own = ([content.text] + mail).joined(separator: "\n")
        self.init(text: ([own] + visual).joined(separator: "\n"), labels: labels, preferred: guidance.preferred,
                  writesADay: blank && !written ? nil : written,
                  language: language.count == DocumentLabel.languageCodeLength ? language : nil, laidOut: own)
    }

    /// The grounds of a reading of `text`, its layout read from `laidOut` when it is given, else from `text`.
    init(text: String, labels: LabelsConfig, preferred: [LabelPreference] = [], writesADay: Bool? = nil, language: String? = nil,
         laidOut: String? = nil) {
        let letters = labels.groundingLetters
        var words = Set<String>()
        var abbreviations = Set<String>()
        var numbers = Set<String>()
        var writings = Set<String>()
        let unbroken = Self.unbroken(text)
        for tokens in Self.lines(unbroken) {
            let folded = tokens.map(Self.key)
            words.formUnion(Self.keys(folded: folded))
            for (index, token) in tokens.enumerated() where token.count > 1 && token.allSatisfy(\.isUppercase) {
                if token.count >= letters || index == 0 { abbreviations.insert(Self.key(token)) }
            }
            numbers.formUnion(Self.numbers(in: tokens, words: labels.numberWords))
            writings.formUnion(Self.writings(in: folded.map(Self.spelled(key:)), words: labels.numberWords))
        }
        self.numbers = numbers
        self.writings = writings
        self.words = words
        self.abbreviations = abbreviations
        layout = DocumentLayout(text: laidOut.map(Self.unbroken) ?? unbroken, language: language)
        self.letters = letters
        self.preferred = preferred
        self.writesADay = writesADay
        digitRuns = Set(text.split { !($0.isASCII && $0.isNumber) })
    }

    /// The digits of `text`, in order, each as its value whatever its script or width ("０３", "٢٠٢٦"), with nothing
    /// between them. A numeral worth more than one digit, as `万` or `⑩`, is none.
    static func digits(of text: String) -> String {
        String(String.UnicodeScalarView(text.compactMap { character -> Unicode.Scalar? in
            guard let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
            return Unicode.Scalar(UInt8(ascii: "0") + UInt8(value))
        }))
    }

    /// The number `text` writes, as numbers are compared: its digits (`digits(of:)`) without the zeros that begin them,
    /// which a model may leave out ("customer 12345" for `00012345`); empty for a text without digits, or only zeros.
    static func number(of text: String) -> String {
        String(digits(of: text).drop { $0 == "0" })
    }

    /// The numbers `tokens`, a line's words, write (`numbers`): each run of up to `words` words with digits that follow
    /// one another, as one number.
    static func numbers(in tokens: [String], words: Int) -> Set<String> {
        var numbers = Set<String>()
        var run: [String] = []
        for token in tokens {
            let digits = Self.digits(of: token)
            guard !digits.isEmpty else {
                run = []
                continue
            }
            run = Array((run + [digits]).suffix(words))
            for start in run.indices { numbers.insert(Self.number(of: run[start...].joined())) }
        }
        return numbers
    }

    /// What `spellings`, a line's words each spelled (`spelled(_:)`), write with digits (`writings`): each run of up to
    /// `words` words that follow one another and hold a digit, spelled as one.
    static func writings(in spellings: [String], words: Int) -> Set<String> {
        let digits = spellings.map { $0.contains(where: \.isNumber) }
        var writings = Set<String>()
        for start in spellings.indices {
            var writing = ""
            var holdsDigit = false
            for index in start..<min(start + words, spellings.count) {
                writing += spellings[index]
                holdsDigit = holdsDigit || digits[index]
                if holdsDigit { writings.insert(writing) }
            }
        }
        return writings
    }

    /// `text` by its letters and digits alone, as names are compared (`key(_:)`), with nothing between them.
    static func spelled(_ text: String) -> String {
        spelled(key: key(text))
    }

    /// A key (`key(_:)`) with nothing between its words.
    static func spelled(key: String) -> String {
        key.filter { $0 != " " }
    }

    /// Whether the document writes the number of `value`, an object or a reference, or how the owner wants one it writes
    /// written, as a name is told (`holds`). Its number is written when the document writes it whole (`numbers`), however
    /// it groups it ("0123456789" by `0123 456 789`), or writes each of its words with digits, wherever: as a number
    /// ("cloud server CPX31 #42368634" by a line that names the server and another its number), or by its letters and
    /// digits over words that follow one another on a line (`writings`), as a machine writes `NL91ABNA0417164300` of
    /// `NL91 ABNA 0417 1643 00`. True for a value without digits, and for a document with no words to tell by, as an
    /// image nothing was read of, which is not checked.
    func writesNumber(of value: String) -> Bool {
        guard !words.isEmpty else { return true }
        return writtenNumber(value) || preferred.contains { LabelSimilarity.sameWriting($0.to, value) && writtenNumber($0.from.value) }
    }

    private func writtenNumber(_ value: String) -> Bool {
        guard !numbers.contains(Self.number(of: value)) else { return true }
        let parts = Self.tokens(Self.unbroken(value)).filter { !Self.number(of: $0).isEmpty }
        return parts.allSatisfy { numbers.contains(Self.number(of: $0)) || writings.contains(Self.spelled($0)) }
    }

    /// Whether the document writes the year of `day`, a `YYYY-MM-DD`: in four digits, alone or within a longer run
    /// (`20250201`), or in two standing alone, as `01 MAR 22` writes it.
    func writesYear(of day: String) -> Bool {
        let year = day.prefix(Self.yearDigits)
        return digitRuns.contains { $0.contains(year) } || digitRuns.contains(year.suffix(Self.shortYearDigits))
    }

    /// The digits of a year in full, and in short.
    static let yearDigits = 4
    static let shortYearDigits = 2

    /// `text` with what breaks a word inside it taken out: a soft hyphen, and a hyphen at the end of a line with the line
    /// break after it.
    static func unbroken(_ text: String) -> String {
        text.replacingOccurrences(of: softHyphen, with: "")
            .replacingOccurrences(of: lineEndHyphen, with: "", options: .regularExpression)
    }

    static let softHyphen = "\u{00AD}"
    /// A hyphen that ends a line, with the spaces around it and the line break.
    static let lineEndHyphen = #"-[ \t]*\r?\n[ \t]*"#

    /// The words of `text` as NaturalLanguage tells them apart, in one width, as `text` cases them.
    static func tokens(_ text: String) -> [String] {
        lines(text).flatMap(\.self)
    }

    /// The words of `text`, as `tokens` gives them, line by line: read in one pass, a line beginning at each word with a
    /// line break between it and the word before.
    static func lines(_ text: String) -> [[String]] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var lines: [[String]] = []
        var end = text.startIndex
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            if lines.isEmpty || text[end..<range.lowerBound].contains(where: \.isNewline) { lines.append([]) }
            lines[lines.count - 1].append(String(text[range]).folding(options: .widthInsensitive, locale: nil))
            end = range.upperBound
        }
        return lines
    }

    /// `tokens` folded (`key`), each run of two or more single letters also as the word it spells ("E D P" is edp).
    static func keys(_ tokens: [String]) -> [String] {
        keys(folded: tokens.map(key))
    }

    /// The keys of a line's words already folded (`key(_:)`), as `keys(_:)` gives them.
    static func keys(folded: [String]) -> [String] {
        var keys: [String] = []
        var spelled = ""
        var letters = 0
        func spell() {
            if letters > 1 { keys.append(spelled) }
            (spelled, letters) = ("", 0)
        }
        for folded in folded {
            let parts = folded.split(separator: " ").map(String.init)
            keys += parts
            if parts.count == 1, let part = parts.first, part.count == 1, part.first?.isLetter == true {
                spelled += part
                letters += 1
            } else {
                spell()
            }
        }
        spell()
        return keys
    }

    /// The words of `value`, folded as the document's are (`keys`).
    static func words(in value: String) -> [String] {
        keys(tokens(unbroken(value)))
    }

    /// The words of `text` in one width, as it cases them: every run of letters and digits.
    static func words(of text: String) -> [Substring] {
        text.folding(options: .widthInsensitive, locale: nil).split { !($0.isLetter || $0.isNumber) }
    }

    /// What a name of several words is abbreviated as, folded (`key`): the first letter of each of its words, a word
    /// written in capitals whole ("HM Passport Office" is HMPO, "Социальный фонд России" СФР), and the same of its words
    /// that begin with a capital alone ("Banco de Portugal" is BP). Empty for a name of one word, which is written whole
    /// or not at all.
    static func initials(of value: String) -> [String] {
        let words = Self.words(of: value)
        guard words.count > 1 else { return [] }
        func initials(_ words: [Substring]) -> String {
            key(words.map { $0.allSatisfy(\.isUppercase) ? String($0) : String($0.prefix(1)) }.joined())
        }
        return [initials(words), initials(words.filter { $0.first?.isUppercase == true })].filter { $0.count > 1 }
    }

    /// The dotless i of Turkish and Azerbaijani, which no case folding but theirs makes an i, as their I and İ are made
    /// one with it (Unicode `CaseFolding.txt`, the `T` mappings): the fold is locale-independent, so `IŞ BANKASI` and
    /// `İş Bankası` are one name.
    static let dotlessI: Character = "\u{0131}"

    /// `text` folded for grounding: lowercase whatever the locale, without accents, in one width (`ＮＴＴ` is `ntt`), the
    /// Turkish i's one letter (`dotlessI`), and every run of anything but letters and digits one space, so a soft hyphen
    /// or a hyphen at the end of a line separates no more than a space does.
    static func key(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .map { $0 == dotlessI ? "i" : $0 })
            .split { !($0.isLetter || $0.isNumber) }.joined(separator: " ")
    }

    /// Whether `value` is a name the document writes, or how the owner wants one it writes written.
    func holds(_ value: String) -> Bool {
        written(value) || preferred.contains { LabelSimilarity.sameWriting($0.to, value) && written($0.from.value) }
    }

    private func written(_ value: String) -> Bool {
        let parts = Self.words(in: value)
        let distinctive = parts.filter { $0.count >= letters }
        let needed = distinctive.isEmpty ? parts : distinctive
        if !needed.isEmpty, needed.allSatisfy({ writes($0) }) { return true }
        let named = Self.words(of: value).count
        return Self.initials(of: value).contains { initials in
            abbreviations.contains(initials) && (initials.count >= letters || initials.count == named)
        }
    }

    /// Whether the document writes `word`, folded, as a word or inside one.
    private func writes(_ word: String) -> Bool {
        words.contains(word) || words.contains { $0.contains(word) }
    }

    /// The words of `title` of `letters` letters or more, and of letters alone, that the document does not write, when
    /// it writes fewer than `share` of them; nil when it writes enough, when the title has no such words, or when the
    /// document has no words to tell by. Numbers and short words say nothing of the language a title is in.
    func unwritten(_ title: String, share: Double) -> [String]? {
        guard !words.isEmpty else { return nil }
        let counted = Self.tokens(Self.unbroken(title)).filter { $0.count >= letters && $0.allSatisfy(\.isLetter) }
        guard !counted.isEmpty else { return nil }
        let missing = counted.filter { !writes(Self.key($0)) }
        return Double(counted.count - missing.count) < share * Double(counted.count) ? missing : nil
    }
}
