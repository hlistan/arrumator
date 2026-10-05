import ArrumatorCore
import Foundation

/// How a document lays out its words and writes them, which what a reading writes otherwise than the prompt asks is
/// told by and written as the document tells from (`AnswerValidator.toldByTheDocument`): its lines, each as the cells a
/// tab parts it into, as two columns side by side or a label and its value are (`PDFPageText`, OCR's tables); and the
/// words of each cell as it spells them, but the letters of a run whose form is a web or e-mail address's, a user's
/// name's or a path's (`withoutAddresses`, `phrases`).
struct DocumentLayout: Sendable {
    /// A cell of a line: as the document writes it, trimmed, and folded (`ReadingGrounds.key`).
    struct Cell: Sendable {
        let text: String
        let key: String
    }

    /// A word of a cell: as the document spells it, folded (`ReadingGrounds.key`), whether it holds a small letter,
    /// whether it is in capitals (`casedInCapitals`), and whether it is a word of a sentence: one holding a small letter
    /// and no capital after its first letter, not joined to another by a dot, as an abbreviation's letters or a unit
    /// are, nor followed by a number, as a number's name is and a month before its year ("de", "é", "Comercial", but not
    /// "n" of "n.º", "nº", "kWh", "No" of "No. INV-2026-118", "Nr" of "Nr. 4711", "Αρ" of "Αρ. 123" nor "julho" of
    /// "julho 2026").
    struct Word: Sendable {
        let text: String
        let key: String
        let small: Bool
        let capitals: Bool
        let ofSentence: Bool

        init(_ text: Substring, dotted: Bool, naming: Bool) {
            self.text = String(text)
            key = ReadingGrounds.key(self.text)
            small = text.contains(where: \.isSmallLetter)
            capitals = DocumentLayout.casedInCapitals(text)
            ofSentence = small && !dotted && !naming && text.dropFirst().filter(\.isCased).allSatisfy(\.isSmallLetter)
        }
    }

    let lines: [[Cell]]
    /// The words of each cell, as the document spells them, but the letters of a run whose form is a web or e-mail
    /// address's, a user's name's or a path's (`withoutAddresses`), which spell a name the way such a thing must, not the
    /// way the document writes it ("vodafone.pt", "maria.exemplo@gmail.com", "maria_exemplo").
    let phrases: [[Word]]
    /// The words, folded, the document writes in capitals beside a word of a sentence, as abbreviations stand in one
    /// ("IMI" of "O IMI é cobrado"), read once (`writesInCapitals`).
    let abbreviations: Set<String>
    /// The ISO 639-1 code of the language the document is written in, whose rules of case its capitals are written by
    /// ("i" is "İ" in Turkish; Greek capitals leave out the tonos, "Μαΐου" is "ΜΑΪΟΥ"); nil when it is not known.
    let language: String?
    /// The locale of `language`, whose capitals a title is compared with (`spells`).
    private let locale: Locale

    init(text: String, language: String?) {
        lines = Self.cells(of: text)
        phrases = Self.cells(of: Self.withoutAddresses(text)).flatMap { $0.map { Self.words(of: $0.text) } }
        abbreviations = Set(phrases.flatMap { phrase in
            phrase.indices.filter { phrase[$0].capitals && Self.besideSentence($0, in: phrase) }.map { phrase[$0].key }
        })
        self.language = language
        locale = Locale(identifier: language ?? "")
    }

    /// The words of a cell, each noted as joined to the word before or after it by a dot with no space ("n.º", "S.A."),
    /// and as followed by a number: by what follows the spaces and signs after it, up to the next space, when that
    /// holds a digit, after a dot or a degree sign, as end a number's name ("No. 4711", "No. ABC123", "n° AB12"), or,
    /// after spaces or a colon, begins with a digit or holds more digits than letters ("julho 2026", "Nr: 12", "No:1",
    /// "nr 1A", "nr INV-2026-118"); not by a name with a digit in it after spaces or a colon, as parts any label from its
    /// value ("vacinação COVID-19", "automóvel: AA-12-BB", "Relatório: Q3"), nor by letters before the number, as a
    /// sentence's end before an abbreviation and its year is written ("maio. IMI 2025", "Relatório IRS 2025"), which a
    /// series' letters are too ("No. FT 2026/1"). One pass: each run is counted once, from the cell's end.
    private static func words(of cell: String) -> [Word] {
        let runs = runs(of: Substring(cell))
        func gap(_ index: Int) -> Substring { cell[runs[index].endIndex..<runs[index + 1].startIndex] }
        // The digits and letters of each run and of those a gap without a space joins after it.
        var rest = Array(repeating: (digits: 0, letters: 0), count: runs.count)
        for index in runs.indices.reversed() {
            let (digits, letters) = index + 1 < runs.count && !gap(index).contains(where: \.isWhitespace) ? rest[index + 1] : (0, 0)
            rest[index] = (digits + runs[index].count(where: \.isNumber), letters + runs[index].count(where: \.isLetter))
        }
        func dot(_ index: Int) -> Bool {
            index + 1 < runs.count && gap(index).contains(".") && !gap(index).contains(where: \.isWhitespace)
        }
        func numbered(_ index: Int) -> Bool {
            guard index + 1 < runs.count, gap(index).allSatisfy({ $0.isWhitespace || numberSigns.contains($0) }) else { return false }
            let next = index + 1, (digits, letters) = rest[next]
            if gap(index).contains(where: namesEnd.contains) { return digits > 0 }
            return runs[next].first?.isNumber == true || digits > letters
        }
        return runs.indices.map { index in
            Word(runs[index], dotted: (index > 0 && dot(index - 1)) || dot(index), naming: numbered(index))
        }
    }

    /// What stands between a number's name and the number, but spaces: "No. 4711", "Nr: 12", "n° 12".
    private static let numberSigns: Set<Character> = [".", ":", "°"]
    /// Of `numberSigns`, those that end a number's name, as its abbreviation: "No.", "n°".
    private static let namesEnd: Set<Character> = [".", "°"]

    /// `text`'s lines, each as the cells a tab parts it into, those with no word left out.
    private static func cells(of text: String) -> [[Cell]] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let cells = line.split(separator: "\t").compactMap { cell -> Cell? in
                let written = cell.trimmingCharacters(in: .whitespaces)
                let key = ReadingGrounds.key(written)
                return key.isEmpty ? nil : Cell(text: written, key: key)
            }
            return cells.isEmpty ? nil : cells
        }
    }

    /// The runs of letters, the marks on them, and digits of `text`, in one pass.
    static func runs(of text: Substring) -> [Substring] {
        text.split { !($0.isLetter || $0.isNumber) }
    }

    /// `text` with the letters of each web and e-mail address, user's name and path it holds blanked out, told by its
    /// form, in one pass: a run of characters between spaces that holds an "@", a dot with two letters after it, as a
    /// domain's has ("faturas@edp.pt", "@Fatura-Eletronica", "vodafone.pt/faturas"), an underscore or a backslash, or a
    /// slash before a letter ("maria_exemplo", "https://edp.pt", "/srv/maria", "~/Faturas", "C:/Maria", and a unit's
    /// "€/kWh"), but not an abbreviation's dots ("S.A.", "I.P.", "n.º") nor a slash before a number ("2026/926804564",
    /// "julho/2026", "FV/2025/123"). Its digits are kept, so a number such a run holds is still a number
    /// ("FV_2025_123").
    private static func withoutAddresses(_ text: String) -> String {
        var kept = ""
        kept.reserveCapacity(text.utf8.count)
        var run: [Character] = []
        func end() {
            guard !run.isEmpty else { return }
            kept += isAddress(run) ? String(run.map { $0.isNumber ? $0 : " " }) : String(run)
            run.removeAll(keepingCapacity: true)
        }
        for character in text {
            if character.isWhitespace {
                end()
                kept.append(character)
            } else {
                run.append(character)
            }
        }
        end()
        return kept
    }

    /// Whether `run`, characters between spaces, is an address, a user's name or a path by its form (`withoutAddresses`).
    private static func isAddress(_ run: [Character]) -> Bool {
        for (index, character) in run.enumerated() {
            if character == "@" || character == "_" || character == "\\" { return true }
            let next = run.dropFirst(index + 1).prefix(2)
            if character == ".", next.count == 2, next.allSatisfy(\.isLetter) { return true }
            if character == "/", next.first?.isLetter == true { return true }
        }
        return false
    }

    /// Whether every letter of `word` that has a case is a capital, and it has one ("FT", "A", "ΙΚΤ", "СА"); a letter
    /// that is both, as an ordinal sign is ("N.º"), is no capital.
    static func casedInCapitals(_ word: Substring) -> Bool {
        let cased = word.filter(\.isCased)
        return !cased.isEmpty && cased.allSatisfy(\.isCapitalLetter)
    }

    /// The party `party` names when it joins two neighbouring cells of one line, one of them a sender's name or the
    /// start of one, as a reading that copied the line two columns stand on does ("EDP Comercial" beside "Maria
    /// Exemplo"): the other cell, as the document writes it. Nil for a name the document writes within one cell, as a
    /// name it wraps onto the next line, and for one that joins two cells neither of which is a sender's, which cannot
    /// tell which is the party.
    func joined(_ party: String, senders: [String]) -> String? {
        let key = ReadingGrounds.key(party)
        let senders = senders.map(ReadingGrounds.key).filter { !$0.isEmpty }
        // A cell is a sender's when it begins with a sender's whole name, or is the start of one in more than one word, as
        // a letterhead shortens it ("EDP Comercial"): one word alone may be a surname a sender's name begins with.
        func isSender(_ cell: Cell) -> Bool {
            senders.contains { Self.begins(cell.key, with: $0) || Self.wordCount(cell.key) > 1 && Self.begins($0, with: cell.key) }
        }
        for cells in lines {
            for (one, other) in zip(cells, cells.dropFirst()) where one.key + " " + other.key == key {
                // A name is never cut down to one word, which may be one of a name printed across two cells.
                switch (isSender(one), isSender(other)) {
                case (true, false) where Self.wordCount(other.key) > 1: return other.text
                case (false, true) where Self.wordCount(one.key) > 1: return one.text
                default: continue
                }
            }
        }
        return nil
    }

    /// How many words a folded text holds.
    static func wordCount(_ key: String) -> Int {
        key.split(separator: " ").count
    }

    /// Whether the folded words of `key` begin with those of `start`.
    static func begins(_ key: String, with start: String) -> Bool {
        key == start || key.hasPrefix(start + " ")
    }

    /// Whether the document writes `words` as the name of the field `number` is the value of: at the end of a cell, the
    /// cell after it, or the first of the line below, beginning with the number ("Fatura n.º" beside "FT
    /// EDPC2026/926804564", "お客さま番号" above its number); not a word it runs into the number, nor one it writes
    /// elsewhere.
    func writesAsLabel(_ words: String, of number: String) -> Bool {
        let (key, value) = (ReadingGrounds.key(words), ReadingGrounds.key(number))
        guard !key.isEmpty, !value.isEmpty else { return false }
        for (index, cells) in lines.enumerated() {
            for (position, cell) in cells.enumerated() where cell.key == key || cell.key.hasSuffix(" " + key) {
                let next = cells.indices.contains(position + 1) ? cells[position + 1] : lines.indices.contains(index + 1) ? lines[index + 1].first : nil
                if let next, Self.begins(next.key, with: value) { return true }
            }
        }
        return false
    }

    /// `title`, written in capitals, as the document writes it in a sentence: where the document writes the title's words
    /// in a row, within one cell, beginning with a capital, as a sentence or a name does, and as a sentence writes them
    /// (`inSentence`), the words as the document spells them there, letter for letter ("TAXE FONCIERE A PAYER" of "Taxe
    /// foncière à payer : 1 234 €" is "Taxe foncière à payer"). The document's words are the title's when the title is
    /// what they are in capitals (`spells`). Nil when the document does not write them so, as a card printed in capitals
    /// alone, a heading whose words the document writes nowhere else in a row, or a sentence that begins them with a
    /// small letter, which no capital is written for, or when it writes them more ways than one ("Caixa Geral de
    /// Depósitos" beside "Caixa geral de depósitos"): what its small letters are, only the document can say. One pass
    /// over the document's words for each word of the title.
    func asSentence(_ title: String) -> String? {
        let words = Self.runs(of: Substring(title))
        guard !words.isEmpty else { return nil }
        let keys = words.map { ReadingGrounds.key(String($0)) }
        let keepsMarks = !Self.marks(title).isEmpty
        var spelled: ArraySlice<Word>?
        for phrase in phrases where phrase.count >= keys.count {
            for start in 0...(phrase.count - keys.count) where phrase[start].key == keys[0] && phrase[start].text.first?.isCapitalLetter == true {
                let run = phrase[start..<start + keys.count]
                guard zip(run, keys).allSatisfy({ $0.key == $1 }), Self.inSentence(run, of: phrase) else { continue }
                // A run spelled as one found already is that one again; another that is the title too spells it otherwise.
                if let spelled, spelled.elementsEqual(run, by: { $0.text == $1.text }) { continue }
                guard zip(run, words).allSatisfy({ spells($0.text, $1, keepingMarks: keepsMarks) }) else { continue }
                guard spelled == nil else { return nil }
                spelled = run
            }
        }
        guard let run = spelled else { return nil }
        var sentence = ""
        var last = title.startIndex
        for (word, written) in zip(words, run) {
            sentence += title[last..<word.startIndex] + written.text
            last = word.endIndex
        }
        return sentence + title[last...]
    }

    /// Whether `word` of the title is the document's `written` in capitals: as the document's language writes its
    /// capitals, or as any does ("faturası" is "FATURASI" in Turkish; "Μαΐου" is "ΜΑΪΟΥ" in Greek, "Όροι" "ΌΡΟΙ"
    /// elsewhere); in a title that bears no marks, as capitals in some scripts leave them out, but for its marks
    /// ("Été" of "ETE"), the dot of a Turkish "İ" kept, which makes it another letter than "I".
    private func spells(_ written: String, _ word: Substring, keepingMarks: Bool) -> Bool {
        let capitals = [written.uppercased(with: locale), written.uppercased()]
        return capitals.contains { keepingMarks ? $0 == word : Self.unmarked(Substring($0)) == Self.unmarked(word) }
    }

    /// Whether the document writes `run`, words of `phrase`, as a sentence writes them: one holds a small letter, and each
    /// in capitals stands beside a word of a sentence (`Word.ofSentence`), in the cell, as an abbreviation does ("fatura
    /// da EDP", "Comercial S.A. Lisboa"), never with words in capitals, an abbreviation's letters or a unit alone around
    /// it, as a heading's words stand ("CONSUMO EM kWh", "FATURA n.º").
    private static func inSentence(_ run: ArraySlice<Word>, of phrase: [Word]) -> Bool {
        run.contains(where: \.small) && run.indices.allSatisfy { !phrase[$0].capitals || besideSentence($0, in: phrase) }
    }

    /// Whether a word beside the word at `index` of `phrase` is a word of a sentence (`Word.ofSentence`).
    private static func besideSentence(_ index: Int, in phrase: [Word]) -> Bool {
        (index > 0 && phrase[index - 1].ofSentence) || (index + 1 < phrase.count && phrase[index + 1].ofSentence)
    }

    /// Whether the document writes every word of `title` that has a case in capitals, each beside a word of a sentence,
    /// as abbreviations stand in one ("IMI", "AT" of "O IMI é cobrado pela AT"): a title written as the document writes
    /// it already (`abbreviations`). A heading's words, beside one another or an abbreviation's letters, are not
    /// ("FATURA n.º").
    func writesInCapitals(_ title: String) -> Bool {
        let cased = Self.runs(of: Substring(title)).filter { $0.contains(where: \.isCased) }
        return !cased.isEmpty && cased.allSatisfy { abbreviations.contains(ReadingGrounds.key(String($0))) }
    }

    /// The marks `text` bears, its accents and the like: none for "e", one for "é" and for "ż"; the dot over a Turkish
    /// capital "İ" is none, as its small letter has its own.
    static func marks(_ text: String) -> String {
        let scalars = Array(text.decomposedStringWithCanonicalMapping.unicodeScalars)
        return String(String.UnicodeScalarView(scalars.indices.filter { isMark(at: $0, of: scalars) }.map { scalars[$0] }))
    }

    /// `text` without its marks, but the dot over a Turkish "İ", which tells it from "I".
    static func unmarked(_ text: Substring) -> String {
        let scalars = Array(text.decomposedStringWithCanonicalMapping.unicodeScalars)
        return String(String.UnicodeScalarView(scalars.indices.filter { !isMark(at: $0, of: scalars) }.map { scalars[$0] }))
    }

    /// Whether the scalar at `index` of `scalars`, decomposed, is a mark: a nonspacing one, but the dot over an "I", which
    /// makes the Turkish "İ" another letter than "I".
    private static func isMark(at index: Int, of scalars: [Unicode.Scalar]) -> Bool {
        guard scalars[index].properties.generalCategory == .nonspacingMark else { return false }
        return !(scalars[index] == dotAbove && index > 0 && scalars[index - 1] == "I")
    }

    /// The combining dot above, of the Turkish "İ".
    static let dotAbove: Unicode.Scalar = "\u{0307}"
}

extension Character {
    /// A small letter, and not also a capital, as an ordinal sign is both ("º").
    var isSmallLetter: Bool { isLowercase && !isUppercase }
    /// A capital, and not also a small letter.
    var isCapitalLetter: Bool { isUppercase && !isLowercase }
}
