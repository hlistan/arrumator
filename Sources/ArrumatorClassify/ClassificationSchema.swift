import ArrumatorCore
import Foundation

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

/// A value of an answer written otherwise than the prompt asks, whose writing the document itself tells
/// (`AnswerValidator.toldByTheDocument`): a label of `kind`, or the title when `kind` is nil, written `from` by the model
/// and `to` as the document tells; `note` says so.
struct Mend: Sendable, Hashable {
    let kind: LabelKind?
    let from: String
    let to: String
    let note: String
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
/// more, as a lease naming both its sides as parties. What the prompt asks to be written otherwise, told by form alone,
/// is written as the document itself tells, at once, as a fact of the document rather than a guess, with a note
/// (`toldByTheDocument`): a party that joins a sender's name to the party's the document prints beside it, as the
/// document prints it (`DocumentLayout.joined`); a title of several words all in capitals (`inCapitals`), as a sentence
/// of the document's own writing (`DocumentLayout.asSentence`); a reference whose words for what it is are not in English
/// (`describedOtherwise`), as its number, where the document prints them as the field's name beside it (`numbered`).
/// What the document does not tell the writing of goes back, as the guesses above do: a title in capitals whose words
/// it writes only so, and a reference whose words it does not set apart. Each guess is told once in an exchange, when a
/// repair sends it (`GuessSentBack.sent`).
public struct AnswerValidator: Sendable {
    public let labels: LabelsConfig
    public let titleGroundedShare: Double
    public let partiesWithoutSender: Int
    public let grounds: ReadingGrounds
    /// Tells the language a reference's words for what it is are in (`describedOtherwise`).
    public let languages: LanguageDetector

    /// The kinds whose labels are names, as the document writes them.
    static let groundedKinds: Set<LabelKind> = [.sender, .party]

    public init(labels: LabelsConfig, titleGroundedShare: Double, partiesWithoutSender: Int, grounds: ReadingGrounds,
                languages: LanguageDetector, titleMaxChars: Int) {
        self.labels = labels
        self.titleGroundedShare = titleGroundedShare
        self.partiesWithoutSender = partiesWithoutSender
        self.grounds = grounds
        self.languages = languages
        self.titleMaxChars = titleMaxChars
    }

    /// The longest title written as a sentence of the document's words (`sentence`): no file name holds a longer one
    /// (`naming.maxChars`), whose name the file name builder cuts.
    public let titleMaxChars: Int

    /// `title`, written in capitals, as a sentence of the document's own writing (`DocumentLayout.asSentence`); nil for a
    /// title longer than `titleMaxChars`, which no file name holds, so a title of hundreds of words is never looked for
    /// across the document.
    func sentence(_ title: String) -> String? {
        title.count <= titleMaxChars ? grounds.layout.asSentence(title) : nil
    }

    /// The language the prompt asks the words of topics and of what a reference is to be written in, as ISO 639-1 writes
    /// it (`labels-system.md`).
    static let wordsLanguage = "en"
    /// A letter of a script other than the Latin one English is written in.
    static var otherScript: Regex<Substring> { #/[^\p{Latin}\P{L}]/# }

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
        // What the document itself tells the writing of is written so before anything is checked further: telling the
        // model would cost a call, and a weak one gives again what it is told of.
        let written = DocumentLabel.oneLine(raw.title)
        // Looked for once: a title in capitals the document does not write as a sentence goes back, below.
        let sentence = Self.inCapitals(written) ? self.sentence(written) : nil
        let told = toldByTheDocument(title: written, sentence: sentence, labels: ordered)
        let mended = Self.mended(ordered, title: written, by: told)
        notes += told.map(\.note)
        let title = mended.title
        let guesses = guesses(title: title, unidentified: unidentified, date: mended.labels.first { $0.kind == .date }?.value,
                              unissued: mended.labels.contains { $0.kind == .sender } ? [] : mended.labels.values(.party))
            + self.written(title: title, sentence: title == written ? sentence : nil, labels: mended.labels)
        let untold = guesses.filter { sentBack?.wasTold($0.subject) != true }
        let reading = { (kept: [String]) in
            ValidatedAnalysis(labels: mended.labels, title: title.isEmpty ? nil : title, notes: notes + kept)
        }
        guard !untold.isEmpty else { return reading(guesses.map { $0.kept(told: true, untold: Self.keptUnrepaired) }) }
        let standing = guesses.map { guess in guess.kept(told: !untold.contains { $0.subject == guess.subject }, untold: Self.keptUnrepaired) }
        let subjects = untold.map(\.subject)
        throw GuessSentBack(problems: untold.map { "\($0.found); \($0.asked)" }, standing: reading(standing),
                            sent: { sentBack?.tell(subjects) })
    }

    /// `labels` and `title` with each value `mends` tells written as it tells, a label kept once however it comes to
    /// be written.
    static func mended(_ labels: [DocumentLabel], title: String, by mends: [Mend]) -> (labels: [DocumentLabel], title: String) {
        var seen = Set<String>()
        let written = labels.compactMap { label -> DocumentLabel? in
            var label = label
            if let mend = mends.first(where: { $0.kind == label.kind && $0.from == label.value }) { label.value = mend.to }
            return seen.insert(label.kind.rawValue + "\u{1F}" + folded(label.value)).inserted ? label : nil
        }
        return (written, mends.first { $0.kind == nil && $0.from == title }?.to ?? title)
    }

    /// What the answer writes otherwise than the prompt asks, told by form, whose writing the document itself tells: a
    /// party joined to the sender's name printed beside it, as printed; a title in capitals, as a sentence of the
    /// document's own writing; a reference described in the document's words, which it prints as the field's name, as
    /// its number. Each with the note that says so.
    private func toldByTheDocument(title: String, sentence: String?, labels: [DocumentLabel]) -> [Mend] {
        let parties = ClassificationSchema.labelsKey(.party)
        let joined = labels.values(.party).compactMap { party -> Mend? in
            guard let alone = grounds.layout.joined(party, senders: labels.values(.sender)),
                  let label = DocumentLabel.normalized(alone, kind: .party) else { return nil }
            return Mend(kind: .party, from: party, to: label.value,
                        note: "\(parties): “\(party)” joins a sender's name to the party's the document prints beside it, \(Self.writtenAsTold)“\(label.value)”")
        }
        let titleKey = ClassificationSchema.titleKey
        let titled = sentence.flatMap { sentence in
            sentence == title ? nil : Mend(kind: nil, from: title, to: sentence,
                                           note: "\(titleKey): “\(title)” is written in capitals, \(Self.writtenAsTold)“\(sentence)”")
        }
        return joined + [titled].compactMap(\.self) + labels.values(.reference).filter(describedOtherwise).compactMap(numbered)
    }

    /// What the answer writes otherwise than the prompt asks, told by form, whose writing the document does not tell, to
    /// go back to the model: a title in capitals whose words it does not write in a sentence, unless it writes each of
    /// them in capitals beside a word of a sentence, as abbreviations stand (`DocumentLayout.writesInCapitals`);
    /// and references described in another language than English whose words it does not set apart
    /// (`toldByTheDocument` writes the rest).
    private func written(title: String, sentence: String?, labels: [DocumentLabel]) -> [Guess] {
        var guesses: [Guess] = []
        if Self.inCapitals(title), sentence == nil, !grounds.layout.writesInCapitals(title) {
            guesses.append(Guess(subject: ClassificationSchema.titleKey,
                                 found: "\(ClassificationSchema.titleKey): “\(title)” is written in capitals",
                                 asked: "write it as a sentence is written, with names as the document writes them"))
        }
        let references = ClassificationSchema.labelsKey(.reference)
        let otherwise = labels.values(.reference).filter(describedOtherwise)
        if !otherwise.isEmpty {
            guesses.append(Guess(subject: references, found: "\(references): \(Self.named(otherwise)) say what they are in another language",
                                 asked: "write one or two English words for what each is, then its number as the document writes it"))
        }
        return guesses
    }

    /// Whether `title` is written in capitals: of more than one word with a letter that has a case, and every such letter
    /// a capital, as a heading printed so ("TÍTULO DE RESIDÊNCIA"); one word, as an abbreviation, and words of a script
    /// without case are not, beside it or alone ("NTT 請求書"). One the document writes so, as abbreviations ("IMI
    /// AT"), is written as asked already (`DocumentLayout.writesInCapitals`).
    static func inCapitals(_ title: String) -> Bool {
        let worded = title.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isCased) }
        let cased = title.filter { $0.isUppercase || $0.isLowercase }
        return worded.count > 1 && !cased.isEmpty && cased.allSatisfy(\.isUppercase)
    }

    /// Whether `reference` says what it is otherwise than in English, as the prompt asks, by the words before what
    /// identifies it (`described`): words of another script than the Latin one ("お客さま番号 03-3542-5545-25", "номер
    /// договора 1234"); or, when one of them is no English word the system knows (`EnglishWords`), words more likely of
    /// the document's language than of English, in a document not in English ("Fatura n.º FT EDPC2026/926804564"), or of
    /// another language as surely as `LanguageDetector` names a short text's ("Zählernummer 1ESY 1160 4478 21"). Words
    /// English and the document's language share ("Client", "Contract") are English.
    func describedOtherwise(_ reference: String) -> Bool {
        let words = Self.described(reference).joined(separator: " ")
        guard words.contains(where: \.isLetter) else { return false }
        if words.contains(Self.otherScript) { return true }
        let telling = ReadingGrounds.tokens(words).map { $0.lowercased() }.filter { $0.count >= labels.groundingLetters }
        let english = EnglishWords()
        guard !telling.isEmpty, !telling.allSatisfy(english.knows) else { return false }
        if let language = grounds.language, language != Self.wordsLanguage,
           languages.prefers(language, over: Self.wordsLanguage, in: words) { return true }
        return languages.code(of: words).map { $0 != Self.wordsLanguage } ?? false
    }

    /// The words of `reference` that say what it is: those before what identifies it, which begins at its first word
    /// that holds a digit, is in capitals, as an abbreviation or a series' letters are ("NIF", "FT", "A", "ΙΚΤ", "СА"),
    /// or is of another script than its first word ("Licence plate 品川 300 あ 12-34").
    static func described(_ reference: String) -> [Substring] {
        let words = reference.split(whereSeparator: \.isWhitespace)
        let script = words.first?.contains(otherScript)
        return Array(words.prefix { word in
            !word.contains(where: \.isNumber) && !DocumentLayout.casedInCapitals(word) && word.contains(otherScript) == script
        })
    }

    /// `reference` without the words that say what it is (`described`): only when the document writes them as the name of
    /// the field the rest is the value of, that value beside it or below it (`DocumentLayout.writesAsLabel`), so what is
    /// left is the number as the document writes it ("Fatura n.º FT EDPC2026/926804564" is "FT EDPC2026/926804564"). Nil
    /// otherwise: words the document runs into the number, or writes elsewhere, may be part of what identifies it.
    private func numbered(_ reference: String) -> Mend? {
        let described = Self.described(reference)
        let number = reference.split(whereSeparator: \.isWhitespace).dropFirst(described.count).joined(separator: " ")
        guard grounds.layout.writesAsLabel(described.joined(separator: " "), of: number) else { return nil }
        let references = ClassificationSchema.labelsKey(.reference)
        return DocumentLabel.normalized(number, kind: .reference).map {
            Mend(kind: .reference, from: reference, to: $0.value,
                 note: "\(references): “\(reference)” says what it is in the document's words, its field's name, \(Self.writtenAsTold)“\($0.value)”")
        }
    }

    static let keptGivenAgain = "kept as the model gives it again"
    static let keptUnrepaired = "kept as given, with no repair left"
    static let writtenAsTold = "written as the document tells: "

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
