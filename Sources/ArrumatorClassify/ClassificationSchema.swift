import ArrumatorCore
import Foundation
import NaturalLanguage

/// The JSON schema sent as Ollama `format`: one list of signals per kind the model gives (`LabelKind.modelKinds`: every
/// kind but the user's own tags, which it is never asked for), then the document's title, which its file name is made
/// of with its date and its sender once the user's rules have kept them (`PipelineServices.read`). Under constrained
/// decoding the model writes the properties in this order, so the facts come first and the title last, from what it has
/// found. Only string, array and object types are used, which every grammar backend supports.
public enum ClassificationSchema {
    static func string(_ enumValues: [String]? = nil) -> JSONValue {
        var e: [JSONEntry] = [JSONEntry("type", "string")]
        if let enumValues { e.append(JSONEntry("enum", .array(enumValues.map(JSONValue.string)))) }
        return .orderedObject(e)
    }

    static func stringArray(maxItems: Int, enumValues: [String]? = nil) -> JSONValue {
        .orderedObject([JSONEntry("type", "array"), JSONEntry("items", string(enumValues)), JSONEntry("maxItems", .number(Double(maxItems)))])
    }

    static func object(_ properties: [JSONEntry]) -> JSONValue {
        .orderedObject([
            JSONEntry("type", "object"),
            JSONEntry("properties", .orderedObject(properties)),
            JSONEntry("required", .array(properties.map { .string($0.key) })),
        ])
    }

    /// The kinds in the order the model writes them: those it gives (`LabelKind.modelKinds`), never a tag.
    static let answerOrder: [LabelKind] = [.sender, .type, .date, .party, .topic, .object, .reference, .period, .deadline, .amount,
                                           .jurisdiction, .language]

    /// The document's signals, the most significant first, and its title. A type is one of `DocumentType` other than
    /// `other`: a document no type fits has none.
    public static func analysis(maxPerKind: Int) -> JSONValue {
        let types = DocumentType.allCases.filter { $0 != .other }.map(\.rawValue)
        return object(answerOrder.map { kind in
            JSONEntry(labelsKey(kind), stringArray(maxItems: kind.isSingle ? 1 : maxPerKind, enumValues: kind == .type ? types : nil))
        } + [JSONEntry(titleKey, string())])
    }

    /// The answer's key for the labels of `kind`: "senders", "parties", "types", …
    static func labelsKey(_ kind: LabelKind) -> String { kind == .party ? "parties" : kind.rawValue + "s" }

    static let titleKey = "title"

    /// The labels `values` as a prompt lists them, each a JSON string, so a label that holds a comma, a semicolon or a
    /// quote reads as the one label it is: `"banking", "account statement"`.
    static func listed(_ values: [String]) -> String {
        values.map { JSONValue.string($0).serialized() }.joined(separator: ", ")
    }
}

/// Raw model answer: a list per kind the schema asks for (`ClassificationSchema.answerOrder`), and the title. Nothing
/// else in it is read: a list of tags is none.
struct AnalysisAnswer: Decodable {
    var signals: [LabelKind: [String]]
    var title: String

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var signals: [LabelKind: [String]] = [:]
        for kind in ClassificationSchema.answerOrder {
            signals[kind] = try container.decode([String].self, forKey: Key(stringValue: ClassificationSchema.labelsKey(kind)))
        }
        self.signals = signals
        title = try container.decode(String.self, forKey: Key(stringValue: ClassificationSchema.titleKey))
    }
}

/// A validated answer: the labels, cleaned, the title on one line (nil when it gave none), and notes on what was
/// changed or dropped.
public struct ValidatedAnalysis: Sendable, Codable, Hashable {
    public var labels: [DocumentLabel]
    public var title: String?
    public var notes: [String]
}

public enum AnswerValidationError: Error, LocalizedError, Hashable {
    case notJSON(String)
    case invalid([String])
    /// The answer stopped at its length limit, in tokens, before it was complete.
    case cutOff(Int)
    /// No answer came within the seconds the request's effort gives one (`LLMClassifier.Effort.timeout`).
    case timedOut(Double)

    public var errorDescription: String? {
        switch self {
        case let .notJSON(why): "The answer is not valid JSON: \(why)"
        case let .invalid(problems): problems.joined(separator: "; ")
        case let .cutOff(limit): "The answer was cut off at its length limit of \(limit) tokens before it was complete; answer more briefly"
        case let .timedOut(seconds): "No answer came within the \(Int(seconds.rounded())) s an answer may take at this effort; a lower effort thinks less"
        }
    }
}

/// An answer holding a structural guess the model is told of (AGENTS.md §4.5): `problems` go back to it, and `standing`
/// is the answer as it is, its notes saying what was kept, which stands when no repair is left
/// (`LLMClassifier.ask`), as an answer the model was told of and gave again does: a guess never fails a reading.
public struct GuessSentBack<Answer: Sendable>: Error, LocalizedError {
    public let problems: [String]
    public let standing: Answer
    /// Notes in the exchange's `SentBack` that the model was told of these guesses: called only once a repair sends them,
    /// so a guess never sent, as in an answer cut off, is not taken for one the model gave again.
    let sent: @Sendable () -> Void

    public var errorDescription: String? { problems.joined(separator: "; ") }
}

/// A guess an answer holds: what it is about, by the field's key, which the model is told of once in an exchange
/// (`SentBack`); what was found; and what the model is asked to do.
struct Guess: Sendable {
    let subject: String
    let found: String
    let asked: String

    /// The note that says it was kept: `untold` when the model was not told of it, else as given again.
    func kept(told: Bool, untold: String) -> String {
        "\(found), " + (told ? AnswerValidator.keptGivenAgain : untold)
    }
}

/// Parses and checks the model's answer. An entry holding the list separator is as many entries as it holds
/// (`DocumentLabel.entrySeparator`), as the prompt asks for one label per entry, each without the quotes the prompt
/// lists labels in (`unquoted`). Each signal is kept as `DocumentLabel.normalized` keeps it, cut to `maxValueChars`, once
/// however it is written; each kind keeps its most significant first, at most `maxPerKind` of it (one of a single-valued
/// kind). A sender or a party is a name the document itself writes (`ReadingGrounds`). What is no label of its kind, or
/// not written in the document, is dropped rather than repaired, and noted; a list missing from the answer goes back to
/// the model. The title is kept on one line, for the file name that is made of it once the user's rules have kept the
/// labels (`PipelineServices.read`). It is made of the document's own words, in its own language, as the prompt asks: a
/// title fewer than `titleGroundedShare` of whose words the document writes (`ReadingGrounds.unwritten`), as a
/// Portuguese title of an English invoice, goes back to the model once, naming them, and the title it gives then stands,
/// whatever its words, as the model's answer to being told (AGENTS.md §4.5). An object is a thing the document
/// identifies, by a number, a plate or an address, so one with no word of `labels.objectIdentifierDigits` digits or more,
/// as a job title or a product bought, goes back with the title, named, for the model to keep only what a number, a plate,
/// an address or a name identifies, and stands when given again; so does a date given to a document that writes none,
/// nor its year (`ReadingGrounds.writesADay`, `writesYear(of:)`), as a note, and a reading without a sender that names `partiesWithoutSender` parties or
/// more, as a lease naming both its sides as parties. Each is told once in an exchange, when a repair sends it
/// (`GuessSentBack.sent`).
public struct AnswerValidator: Sendable {
    public let labels: LabelsConfig
    public let titleGroundedShare: Double
    public let partiesWithoutSender: Int
    public let grounds: ReadingGrounds

    /// The kinds whose labels are names, as the document writes them.
    static let groundedKinds: Set<LabelKind> = [.sender, .party]

    public init(labels: LabelsConfig, titleGroundedShare: Double, partiesWithoutSender: Int, grounds: ReadingGrounds) {
        self.labels = labels
        self.titleGroundedShare = titleGroundedShare
        self.partiesWithoutSender = partiesWithoutSender
        self.grounds = grounds
    }

    /// The reading `text` gives. `sentBack` holds whether this exchange with the model already sent its title back, so
    /// the title it gives after that stands; nil sends a title back however often it comes.
    public func validate(_ text: String, sentBack: SentBack? = nil) throws -> ValidatedAnalysis {
        let raw: AnalysisAnswer
        do {
            raw = try JSONDecoder().decode(AnalysisAnswer.self, from: Data(ModelOutput.jsonObject(text).utf8))
        } catch let DecodingError.keyNotFound(key, _) {
            throw AnswerValidationError.invalid(["\(key.stringValue) is missing; give [] when the document shows none"])
        } catch {
            throw AnswerValidationError.notJSON(String(describing: error))
        }
        var notes: [String] = []
        var unidentified: [String] = []
        let kept = ClassificationSchema.answerOrder.flatMap { labels(of: $0, in: raw, notes: &notes, unidentified: &unidentified) }
        // Kinds in their own order, as the rest of the app lists them.
        let ordered = LabelKind.allCases.flatMap { kind in kept.filter { $0.kind == kind } }
        let title = DocumentLabel.oneLine(raw.title)
        let guesses = guesses(title: title, unidentified: unidentified, date: ordered.first { $0.kind == .date }?.value,
                              unissued: ordered.contains { $0.kind == .sender } ? [] : ordered.values(.party))
        let untold = guesses.filter { sentBack?.wasTold($0.subject) != true }
        guard !untold.isEmpty else {
            let kept = guesses.map { $0.kept(told: true, untold: Self.keptUnrepaired) }
            return ValidatedAnalysis(labels: ordered, title: title.isEmpty ? nil : title, notes: notes + kept)
        }
        let standing = guesses.map { guess in guess.kept(told: !untold.contains { $0.subject == guess.subject }, untold: Self.keptUnrepaired) }
        let subjects = untold.map(\.subject)
        throw GuessSentBack(problems: untold.map { "\($0.found); \($0.asked)" },
                            standing: ValidatedAnalysis(labels: ordered, title: title.isEmpty ? nil : title, notes: notes + standing),
                            sent: { sentBack?.tell(subjects) })
    }

    static let keptGivenAgain = "kept as the model gives it again"
    static let keptUnrepaired = "kept as given, with no repair left"

    /// What the answer holds that the document may not bear out, each as what was found and what the model is asked to
    /// do: a title not of the document's words, objects nothing identifies, a date it does not write, and `unissued`,
    /// the parties of a reading without a sender, when there are `partiesWithoutSender` of them or more.
    private func guesses(title: String, unidentified: [String], date: String?, unissued: [String]) -> [Guess] {
        var guesses: [Guess] = []
        let senders = ClassificationSchema.labelsKey(.sender)
        if unissued.count >= partiesWithoutSender {
            guesses.append(Guess(subject: senders, found: "\(senders): none, while the parties name \(Self.named(unissued))",
                                 asked: "give who issued, offers or sent the document, such as the landlord, the seller, the employer or the "
                                     + "insurer of a lease or a contract, as its sender and not also as a party, or [] when it names no one who did"))
        }
        let dates = ClassificationSchema.labelsKey(.date)
        if let date, grounds.writesADay == false, !grounds.writesYear(of: date) {
            guesses.append(Guess(subject: dates, found: "\(dates): “\(date)”, while the document writes no date, nor that year",
                                 asked: "give a date only as the document writes it, with its year, or [] when it writes none"))
        }
        if let unwritten = grounds.unwritten(title, share: titleGroundedShare) {
            guesses.append(Guess(subject: ClassificationSchema.titleKey,
                                 found: "\(ClassificationSchema.titleKey): the title's words \(Self.named(unwritten)) are not in the document",
                                 asked: "make the title of the document's own words, in its own language"))
        }
        let objects = ClassificationSchema.labelsKey(.object)
        if !unidentified.isEmpty {
            guesses.append(Guess(subject: objects, found: "\(objects): \(Self.named(unidentified)) hold no number",
                                 asked: "keep each only when a number, a plate, an address or a name the document writes identifies one thing, "
                                     + "never a fact about a person nor a kind of thing alone"))
        }
        return guesses
    }

    /// Whether an object holds what identifies a thing: a word of `digits` digits or more, as a number, a plate or an
    /// address writes, which a quantity or a size ("1L", "x6") does not; or a number standing alone beside a name, as an
    /// address writes a house number after its street ("Calle del Ejemplo 7").
    static func identifies(_ object: String, digits: Int) -> Bool {
        let words = object.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        if words.contains(where: { $0.filter(\.isNumber).count >= digits }) { return true }
        return words.contains { !$0.isEmpty && $0.allSatisfy(\.isNumber) } && words.contains { $0.first?.isUppercase == true }
    }

    static func named(_ values: [String]) -> String {
        values.map { "“\($0)”" }.joined(separator: ", ")
    }

    /// The labels of `kind` the answer gives that are kept, and in `unidentified` those of them that are objects nothing
    /// identifies, as kept: told by the whole value, before it is cut, so a number at its end still identifies it.
    private func labels(of kind: LabelKind, in raw: AnalysisAnswer, notes: inout [String], unidentified: inout [String]) -> [DocumentLabel] {
        let key = ClassificationSchema.labelsKey(kind)
        let limit = kind.isSingle ? 1 : labels.maxPerKind
        var seen = Set<String>()
        var kept: [DocumentLabel] = []
        let entries = (raw.signals[kind] ?? []).flatMap { $0.split(separator: DocumentLabel.entrySeparator).map(Self.unquoted) }
        for written in entries where !DocumentLabel.oneLine(written).isEmpty {
            guard var label = DocumentLabel.normalized(written, kind: kind) else {
                notes.append("\(key): “\(DocumentLabel.oneLine(written))” is no \(kind.rawValue), dropped")
                continue
            }
            guard !Self.groundedKinds.contains(kind) || grounds.holds(label.value) else {
                notes.append("\(key): “\(label.value)” is not written in the document, dropped")
                continue
            }
            let identified = kind != .object || Self.identifies(label.value, digits: labels.objectIdentifierDigits)
            label.value = DocumentLabel.shortened(label.value, to: labels.maxValueChars)
            guard seen.insert(Self.folded(label.value)).inserted else { continue }
            guard seen.count <= limit else {
                notes.append("\(key): more than \(limit), the rest dropped")
                break
            }
            if !identified { unidentified.append(label.value) }
            kept.append(label)
        }
        return kept
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// An entry without the double quotes it is wrapped in, as a label the prompt lists in them
    /// (`ClassificationSchema.listed`) may be copied with them.
    static func unquoted(_ entry: Substring) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 1, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return String(entry) }
        return String(trimmed.dropFirst().dropLast())
    }
}

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
    let numbers: Set<Substring>

    public init(content: ExtractedContent, guidance: LabelGuidance, letters: Int) {
        let visual = content.visual.map { [$0.description] + $0.organisations } ?? []
        let mail = [MetadataKey.emailFrom, MetadataKey.emailSubject].compactMap { content.metadata[$0] }
        let written = !content.entities.dates.isEmpty || content.metadata[MetadataKey.emailDate] != nil
            || content.visual?.dates.contains { DocumentLabel.normalized($0, kind: .date) != nil } == true
        let blank = content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.init(text: ([content.text] + mail + visual).joined(separator: "\n"), letters: letters, preferred: guidance.preferred,
                  writesADay: blank && !written ? nil : written)
    }

    init(text: String, letters: Int, preferred: [LabelPreference] = [], writesADay: Bool? = nil) {
        var words = Set<String>()
        var abbreviations = Set<String>()
        for tokens in Self.lines(Self.unbroken(text)) {
            words.formUnion(Self.keys(tokens))
            for (index, token) in tokens.enumerated() where token.count > 1 && token.allSatisfy(\.isUppercase) {
                if token.count >= letters || index == 0 { abbreviations.insert(Self.key(token)) }
            }
        }
        self.words = words
        self.abbreviations = abbreviations
        self.letters = letters
        self.preferred = preferred
        self.writesADay = writesADay
        numbers = Set(text.split { !($0.isASCII && $0.isNumber) })
    }

    /// Whether the document writes the year of `day`, a `YYYY-MM-DD`: in four digits, alone or within a longer run
    /// (`20250201`), or in two standing alone, as `01 MAR 22` writes it.
    func writesYear(of day: String) -> Bool {
        let year = day.prefix(Self.yearDigits)
        return numbers.contains { $0.contains(year) } || numbers.contains(year.suffix(Self.shortYearDigits))
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
        var keys: [String] = []
        var spelled = ""
        var letters = 0
        func spell() {
            if letters > 1 { keys.append(spelled) }
            (spelled, letters) = ("", 0)
        }
        for token in tokens {
            let parts = key(token).split(separator: " ").map(String.init)
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
