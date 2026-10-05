import ArrumatorCore
import Foundation

/// The JSON schema a search request is answered in: one list of labels per kind the model gives, as a document's
/// answer has them and in the same order, each label with the words of the request that ask for it; then the words the
/// text must contain, the arrangement by those kinds, each with the words that ask for it too, and a name. A task never
/// asks for a tag, the user's own: the user adds tagged documents to its set and arranges it by them. Only string, array
/// and object types are used, which every grammar backend supports.
public enum SearchSchema {
    static let valueKey = "value"
    static let askedAsKey = "asked_as"
    static let wordsKey = "words"
    static let groupingKey = "group_by"
    static let titleKey = "title"

    public static func plan(_ tasks: TasksConfig) -> JSONValue {
        let types = DocumentType.allCases.filter { $0 != .other }.map(\.rawValue)
        return ClassificationSchema.object(ClassificationSchema.answerOrder.map { kind in
            JSONEntry(ClassificationSchema.labelsKey(kind), .orderedObject([
                JSONEntry("type", "array"),
                JSONEntry("items", ClassificationSchema.object([
                    JSONEntry(valueKey, ClassificationSchema.string(kind == .type ? types : nil)),
                    JSONEntry(askedAsKey, ClassificationSchema.string()),
                ])),
                JSONEntry("maxItems", .number(Double(tasks.maxValuesPerKind))),
            ]))
        } + [
            JSONEntry(wordsKey, ClassificationSchema.stringArray(maxItems: tasks.maxWords)),
            JSONEntry(groupingKey, .orderedObject([
                JSONEntry("type", "array"),
                JSONEntry("items", ClassificationSchema.object([
                    JSONEntry(valueKey, ClassificationSchema.string(LabelKind.modelKinds.map(\.rawValue))),
                    JSONEntry(askedAsKey, ClassificationSchema.string()),
                ])),
                JSONEntry("maxItems", .number(Double(tasks.maxGroupingDepth))),
            ])),
            JSONEntry(titleKey, ClassificationSchema.string()),
        ])
    }
}

/// Raw answer to a search request: a list per kind the schema asks for, and nothing else of labels.
struct SearchAnswer: Decodable {
    /// A label asked for, or a kind to arrange by, and the words of the request the model says ask for it.
    struct Criterion: Decodable {
        var value: String
        var askedAs: String

        enum CodingKeys: String, CodingKey {
            case value
            case askedAs = "asked_as"
        }
    }

    var labels: [LabelKind: [Criterion]]
    var words: [String]
    var grouping: [Criterion]
    var title: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnalysisAnswer.Key.self)
        var labels: [LabelKind: [Criterion]] = [:]
        for kind in ClassificationSchema.answerOrder {
            labels[kind] = try container.decode([Criterion].self, forKey: AnalysisAnswer.Key(stringValue: ClassificationSchema.labelsKey(kind)))
        }
        self.labels = labels
        words = try container.decode([String].self, forKey: AnalysisAnswer.Key(stringValue: SearchSchema.wordsKey))
        grouping = try container.decode([Criterion].self, forKey: AnalysisAnswer.Key(stringValue: SearchSchema.groupingKey))
        title = try container.decode(String.self, forKey: AnalysisAnswer.Key(stringValue: SearchSchema.titleKey))
    }
}

/// A plan the model gave, checked, and notes on what was changed or dropped.
public struct ValidatedSearchPlan: Sendable, Codable, Hashable {
    public var plan: SearchPlan
    public var notes: [String]
}

/// Parses and checks the answer to a search request against the request itself.
///
/// Every kind a plan gives leaves documents out, so a label nobody asked for, such as the country every document of the
/// archive is from, silently hides what was wanted. A label is therefore kept only when every word the model quotes for
/// it (`asked_as`) is a word of the request, whatever its case, accents or punctuation: the model must ground each label
/// in the request, and the app checks the quote, as generated claims are checked against the sources they cite (Gao et
/// al., ALCE, EMNLP 2023; docs/organizing-principles-sources.md#sources-for-search-tasks). Words are told apart as
/// NaturalLanguage tells them (`LabelUsage.searchWords`), so a request written without spaces between its words is read
/// word by word too. A quote may leave words out or run them together ("agosto de 2026" from "agosto e setembro de
/// 2026"), but never add one. Words ask for one thing: a label whose quote has only words a label of an earlier kind
/// (`ClassificationSchema.answerOrder`) already quotes is dropped, so "faturas de Portugal" asks for documents under
/// Portuguese law and not also for documents written in Portuguese. A label whose quote holds the whole quotes of labels
/// of other kinds that ask for two or more things ("квитанции за электричество" holding "квитанции" of a type and
/// "электричество" of a topic) quotes what asks for those, not for itself: an inferred sender quoted so would leave out
/// every bill of another, so it goes back to the model, named with the labels it holds (`spanning`), and given again it
/// stands, as the model's answer to being told. A quote that holds one other label's quote ("de Portugal" holding
/// "Portugal") is the ordinary case of one phrase read as two kinds, which the rule before decides. Arranging is not limiting: the arrangement quotes the
/// words that ask for it too, and a label of the kind it arranges by that those words alone ground is dropped, so "по
/// отправителю" ("by sender") arranges the documents by sender and asks for none, while a label of another kind stands
/// though the arrangement's quote runs over its words ("invoices by sender"). A word is kept only when it is a word of the
/// request, no label's quote already has it and it is not itself what the arrangement quotes ("по отправителю"). A word
/// that falls inside the arrangement's quote without being all of it ("Lisbon" in a quote of "contracts mentioning
/// Lisbon by sender") may limit or only arrange, which no structure tells: it goes back to the model, named, and given
/// as a word again it is kept (`sentBack`), never dropped unseen.
///
/// A document needs one label of a kind but every word, so an alternative of a kind's labels given as a word
/// ("insurance" in "electricity, water, insurance or rent") would be asked of every document together with the others,
/// and find none. Such a word goes back to the model, named, to be given as a label of that kind (`alternatives`); given
/// as a word again, it is the model's answer to being told and is kept (`sentBack`). A word is such an alternative when
/// the request writes it between the words two different labels of one kind quote, or carries on their list: within
/// `tasks.alternativesGap` words of one of them, or of another word so found. Where a label's quote stands is told by
/// those of its words the request writes once, so a word its quote shares with the rest of the request ("da" in "da
/// EDP") places nothing; where the request writes a word says so in any language.
///
/// A label is kept as a document's label of its kind is (`DocumentLabel.normalized`), except that a date or deadline may
/// be a year, a month or a span, as a period is, and an amount a number without its currency
/// (`DocumentLabel.amountValue`); one with nothing to match by is dropped, and so is any beyond
/// `tasks.maxValuesPerKind` of a kind. Words are kept once each, up to `tasks.maxWords`; the arrangement names each kind
/// once, up to `tasks.maxGroupingDepth`. What is dropped is noted for the trace. A list missing from the answer, a kind
/// the arrangement does not know, an alternative given as a word, a word inside the arrangement's quote, or a plan left
/// asking for nothing at all goes back to the model, with the reasons. The task is named in the language the request is
/// written in, as the model is told: a title `languages` is sure is in another goes back once, named, and stands when
/// given again (QA 2026-10-04, TSK-3). A request the model made for more documents from a person's question names a kind
/// of document only when the question does: a type whose quote the question does not write goes back, named, and is
/// kept when given again (QA 2026-10-04, CNV-4, a dental document missed by a find typed attestation or medical report).
public struct SearchPlanValidator: Sendable {
    public let tasks: TasksConfig
    public let labels: LabelsConfig
    public let languages: LanguageDetector

    public init(tasks: TasksConfig, labels: LabelsConfig, languages: LanguageDetector) {
        self.tasks = tasks
        self.labels = labels
        self.languages = languages
    }

    /// The plan `text` gives for `request`. `sentBack` holds what this exchange with the model already sent back: words,
    /// as alternatives or as inside the arrangement's quote, and labels whose quote holds others', which the model may
    /// give again; nil sends each back however often it comes.
    public func validate(_ text: String, request: String, question: String? = nil, sentBack: SentBack? = nil) throws -> ValidatedSearchPlan {
        let raw: SearchAnswer
        do {
            raw = try JSONDecoder().decode(SearchAnswer.self, from: Data(ModelOutput.jsonObject(text).utf8))
        } catch let DecodingError.keyNotFound(key, _) {
            throw AnswerValidationError.invalid(["\(key.stringValue) is missing; give [] when the request does not limit it"])
        } catch {
            throw AnswerValidationError.notJSON(String(describing: error))
        }
        let sequence = LabelUsage.searchWords(request)
        let asked = Set(sequence)
        var notes: [String] = []
        let (grouping, arranging, arrangingQuotes) = try arrangement(raw.grouping, asked: asked, notes: &notes)
        let candidates = ClassificationSchema.answerOrder.flatMap {
            candidates(of: $0, in: raw, asked: asked, arranging: arranging[$0] ?? [], notes: &notes)
        }
        let spanning = Self.spanning(candidates)
        var quoted = Set<String>()
        var alternatives: [LabelKind: [Set<String>]] = [:]
        let criteria = ClassificationSchema.answerOrder.flatMap {
            labels(of: $0, from: candidates, quoted: &quoted, alternatives: &alternatives, notes: &notes)
        }
        let given = distinct(raw.words.map(DocumentLabel.oneLine).filter { word in
            let key = Self.words(word)
            guard !key.isEmpty else { return false }
            guard key.isSubset(of: asked) else {
                notes.append("\(SearchSchema.wordsKey): “\(word)” is not in the request, dropped")
                return false
            }
            guard !arrangingQuotes.contains(where: { $0.words == key }) else {
                notes.append("\(SearchSchema.wordsKey): “\(word)” only asks to arrange the documents, dropped")
                return false
            }
            guard !key.isSubset(of: quoted) else {
                notes.append("\(SearchSchema.wordsKey): “\(word)” is asked for by a label already, dropped")
                return false
            }
            return true
        }, limit: tasks.maxWords, what: SearchSchema.wordsKey, notes: &notes)
        // A word inside a quote of the arrangement that is not the whole quote may limit ("Lisbon" in "contracts
        // mentioning Lisbon by sender") or only arrange: the model is asked, and its answer given again stands.
        let inArranging = given.compactMap { word -> (word: String, quote: String)? in
            let key = Self.words(word)
            return arrangingQuotes.first { key.isSubset(of: $0.words) }.map { (word, $0.written) }
        }
        let listed = Self.alternatives(given.filter { word in !inArranging.contains { $0.word == word } }, in: sequence, of: alternatives,
                                       gap: tasks.alternativesGap)
        let plan = SearchPlan(title: DocumentLabel.shortened(DocumentLabel.oneLine(raw.title), to: tasks.maxTitleChars), labels: criteria,
                              words: given, grouping: grouping)
        let guesses = Guesses(spanning: spanning, listed: listed, inArranging: inArranging,
                              unnamed: question.map { unnamedKinds(candidates, criteria: criteria, question: $0) } ?? [],
                              titled: otherLanguage(of: plan.title, request: request), sentBack: sentBack)
        if !guesses.problems.isEmpty {
            guard !plan.isEmpty else {
                guesses.sent()
                throw AnswerValidationError.invalid(guesses.problems)
            }
            throw GuessSentBack(problems: guesses.problems, standing: ValidatedSearchPlan(plan: plan, notes: notes + guesses.kept(unrepaired: true)),
                                sent: guesses.sent)
        }
        notes += guesses.kept(unrepaired: false)
        guard !plan.isEmpty else {
            throw AnswerValidationError.invalid(notes + ["nothing to search by: give the labels the request asks for, each with "
                + "\(SearchSchema.askedAsKey) copied from the request"])
        }
        return ValidatedSearchPlan(plan: plan, notes: notes)
    }

    /// The kinds `criteria` arrange the documents by, each once, up to `tasks.maxGroupingDepth`; the words of the request
    /// that ask for each, which ground no label of that kind; and each quote of the arrangement, as written and as its
    /// words: a word that is one of them is dropped, and one that only falls inside one goes back to the model.
    private func arrangement(_ criteria: [SearchAnswer.Criterion], asked: Set<String>, notes: inout [String]) throws
        -> (grouping: [LabelKind], arranging: [LabelKind: Set<String>], quotes: [(written: String, words: Set<String>)]) {
        var grouping: [LabelKind] = []
        var arranging: [LabelKind: Set<String>] = [:]
        var quotes: [(written: String, words: Set<String>)] = []
        for criterion in criteria {
            let written = criterion.value.trimmingCharacters(in: .whitespaces)
            guard let kind = LabelKind(rawValue: written), !kind.isUsersOwn else {
                throw AnswerValidationError.invalid(["\(SearchSchema.groupingKey): “\(written)” is no kind of label"])
            }
            if !grouping.contains(kind) { grouping.append(kind) }
            let quote = Self.words(criterion.askedAs)
            if !quote.isEmpty, quote.isSubset(of: asked) {
                arranging[kind, default: []].formUnion(quote)
                quotes.append((DocumentLabel.oneLine(criterion.askedAs), quote))
            }
        }
        if grouping.count > tasks.maxGroupingDepth {
            notes.append("\(SearchSchema.groupingKey): more than \(tasks.maxGroupingDepth), the rest dropped")
            grouping = Array(grouping.prefix(tasks.maxGroupingDepth))
        }
        return (grouping, arranging, quotes)
    }

    /// The title's language, when `languages` is sure of it and of the request's and they differ: what was found, and the
    /// request's language; nil otherwise, as for a title of names and numbers it cannot tell.
    private func otherLanguage(of title: String, request: String) -> (found: String, request: String)? {
        guard let asked = languages.name(of: request), let named = languages.name(of: title), named != asked else { return nil }
        return ("\(SearchSchema.titleKey): “\(title)” is in \(named), while the request is in \(asked)", asked)
    }

    /// The labels of a type `criteria` keep whose quote the person's `question`, and the questions before it, do not
    /// write: a kind of document the model's request for more named on its own. A word of the quote is written when the
    /// question writes it or the same word inflected (`inflected(_:_:)`).
    private func unnamedKinds(_ candidates: [Candidate], criteria: [DocumentLabel], question: String) -> [Candidate] {
        let named = Set(LabelUsage.searchWords(question).map(LabelUsage.searchKey))
        return candidates.filter { candidate in
            candidate.label.kind == .type && criteria.contains(candidate.label)
                && !candidate.quote.allSatisfy { word in named.contains { inflected(word, $0) } }
        }
    }

    /// Whether `a` and `b` are one word, inflected as a plural or a case inflects it ("invoice" and "invoices", "fatura"
    /// and "faturas", "квитанции" and "квитанция"): the same, one beginning the other, or both beginning with all but
    /// `tasks.inflectionLetters` letters of the shorter, and at least `labels.groundingLetters` letters.
    func inflected(_ a: String, _ b: String) -> Bool {
        if a == b || a.hasPrefix(b) && b.count >= labels.groundingLetters || b.hasPrefix(a) && a.count >= labels.groundingLetters { return true }
        let shared = zip(a, b).prefix { $0 == $1 }.count
        return shared >= max(labels.groundingLetters, min(a.count, b.count) - tasks.inflectionLetters)
    }

    /// What a plan holds that goes back to the model when this exchange has not yet told it of it (`SentBack`): a label
    /// whose quote holds other labels' (`spanning`), alternatives of a kind's labels given as words (`listed`), a word
    /// inside the arrangement's quote (`inArranging`), a kind of document the person's question never names (`unnamed`),
    /// and a title in another language than the request's (`titled`). What it was told of before it gave again, and
    /// stands; `sent` notes what a repair tells it.
    private struct Guesses {
        let spanning: [(label: Candidate, held: [Candidate])]
        let listed: [(kind: LabelKind, words: [String])]
        let inArranging: [(word: String, quote: String)]
        let unnamed: [Candidate]
        let titled: (found: String, request: String)?
        /// Those of them this exchange has not told the model of yet.
        struct Untold {
            let spanning: [Candidate]
            let listed: [(kind: LabelKind, words: [String])]
            let inArranging: [(word: String, quote: String)]
            let unnamed: [Candidate]
            let title: Bool
        }

        let new: Untold
        let sent: @Sendable () -> Void

        init(spanning: [(label: Candidate, held: [Candidate])], listed: [(kind: LabelKind, words: [String])],
             inArranging: [(word: String, quote: String)], unnamed: [Candidate], titled: (found: String, request: String)?, sentBack: SentBack?) {
            (self.spanning, self.listed, self.inArranging, self.unnamed, self.titled) = (spanning, listed, inArranging, unnamed, titled)
            let title = titled != nil && sentBack?.wasTold(SearchSchema.titleKey) != true
            new = Untold(spanning: spanning.filter { sentBack?.contains($0.label.label) != true }.map(\.label),
                         listed: listed.filter { sentBack?.contains($0.words) != true },
                         inArranging: inArranging.filter { sentBack?.contains([$0.word]) != true },
                         unnamed: unnamed.filter { sentBack?.contains($0.label) != true }, title: title)
            let words = new.listed.flatMap(\.words) + new.inArranging.map(\.word)
            let labels = new.spanning.map(\.label) + new.unnamed.map(\.label)
            sent = {
                sentBack?.insert(words)
                sentBack?.insert(labels)
                if title { sentBack?.tell([SearchSchema.titleKey]) }
            }
        }

        /// What goes back to the model, naming them.
        var problems: [String] {
            let held = Dictionary(spanning.map { ($0.label.label, $0.held) }) { first, _ in first }
            return new.spanning.map { label in
                "\(ClassificationSchema.labelsKey(label.label.kind)): “\(label.label.value)” is asked for by “\(label.written)”, which holds what "
                    + (held[label.label] ?? []).map { "\(ClassificationSchema.labelsKey($0.label.kind)) “\($0.label.value)” (“\($0.written)”)" }
                    .joined(separator: " and ")
                    + " ask for: give it only with the words that ask for it by themselves, or leave it out when none do"
            } + new.listed.map { kind, words in
                "\(SearchSchema.wordsKey): \(words.map { "“\($0)”" }.joined(separator: ", ")) sit among the "
                    + "\(ClassificationSchema.labelsKey(kind)) the request lists, of which a document needs only one, while it must hold "
                    + "every word: give them as \(ClassificationSchema.labelsKey(kind)), not words"
            } + new.inArranging.map { word, quote in
                "\(SearchSchema.wordsKey): “\(word)” is among the words \(SearchSchema.groupingKey) quotes as asking to arrange the "
                    + "documents (“\(quote)”): give it as a word only when every document found must contain it"
            } + new.unnamed.map {
                "\(ClassificationSchema.labelsKey(.type)): “\($0.label.value)” (“\($0.written)”) is a kind of document the person's question "
                    + "does not name: give a kind only when they name it"
            } + (new.title ? titled.map { ["\($0.found); name the task in \($0.request), the language of the request"] } ?? [] : [])
        }

        /// What the notes say of what was sent back and kept: given again, or, when `unrepaired`, what this answer was not
        /// told of yet as given with no repair left.
        func kept(unrepaired: Bool) -> [String] {
            let unrepairedKept = AnswerValidator.keptUnrepaired
            let again = { (isNew: Bool, givenAgain: String) in unrepaired && isNew ? unrepairedKept : givenAgain }
            let newLabels = Set(new.spanning.map(\.label) + new.unnamed.map(\.label))
            let newWords = Set(new.listed.flatMap(\.words) + new.inArranging.map(\.word))
            return spanning.map { label, _ in
                "\(ClassificationSchema.labelsKey(label.label.kind)): “\(label.label.value)” is asked for by “\(label.written)”, "
                    + "which holds other labels' words, and is " + again(newLabels.contains(label.label), AnswerValidator.keptGivenAgain)
            } + listed.map { kind, words in
                "\(SearchSchema.wordsKey): \(words.map { "“\($0)”" }.joined(separator: ", ")) sit among the "
                    + "\(ClassificationSchema.labelsKey(kind)) the request lists, and are "
                    + again(words.contains { newWords.contains($0) }, "kept as the model gives them as words again")
            } + inArranging.map { word, quote in
                "\(SearchSchema.wordsKey): “\(word)” is among the words that arrange the documents (“\(quote)”), and is "
                    + again(newWords.contains(word), "kept as the model gives it as a word again")
            } + unnamed.map {
                "\(ClassificationSchema.labelsKey(.type)): “\($0.label.value)” (“\($0.written)”) is a kind the person's question does not "
                    + "name, and is " + again(newLabels.contains($0.label), AnswerValidator.keptGivenAgain)
            } + (titled.map { ["\($0.found), and is " + again(new.title, AnswerValidator.keptGivenAgain)] } ?? [])
        }
    }

    /// A label the answer gives that is a label of its kind, grounded in the request and not only by the words that
    /// arrange the documents by its kind: its quote's words, and the quote as written.
    struct Candidate {
        var label: DocumentLabel
        var quote: Set<String>
        var written: String
    }

    /// The labels of `kind` the answer gives that are labels of their kind, grounded in the request (`asked`), and not
    /// asked for only by the words that arrange the documents by `kind` (`arranging`).
    private func candidates(of kind: LabelKind, in raw: SearchAnswer, asked: Set<String>, arranging: Set<String>,
                            notes: inout [String]) -> [Candidate] {
        let key = ClassificationSchema.labelsKey(kind)
        return (raw.labels[kind] ?? []).filter { !DocumentLabel.oneLine($0.value).isEmpty }.compactMap { criterion -> Candidate? in
            // A date or deadline asked for may be any span of time, as a period is, and an amount be in any currency.
            let normalized = DocumentLabel.normalized(criterion.value, kind: SearchPlan.timeKinds.contains(kind) ? .period : kind)?.value
                ?? (kind == .amount ? DocumentLabel.amountValue(criterion.value) : nil)
            guard let value = normalized, !LabelUsage.searchKey(value).isEmpty else {
                notes.append("\(key): “\(DocumentLabel.oneLine(criterion.value))” is no \(kind.rawValue), dropped")
                return nil
            }
            let quote = Self.words(criterion.askedAs)
            let written = DocumentLabel.oneLine(criterion.askedAs)
            guard !quote.isEmpty, quote.isSubset(of: asked) else {
                notes.append("\(key): “\(value)” is not asked for by the request (“\(written)”), dropped")
                return nil
            }
            guard !quote.isSubset(of: arranging) else {
                notes.append("\(key): “\(value)” is asked for only by words that arrange the documents (“\(written)”), dropped")
                return nil
            }
            return Candidate(label: DocumentLabel(kind: kind, value: DocumentLabel.shortened(value, to: labels.maxValueChars)), quote: quote,
                             written: written)
        }
    }

    /// The labels of `candidates` whose quote holds the whole quotes of labels of other kinds that ask for two or more
    /// things, each with those it holds: a quote that runs over what several labels ask for, which the model must say
    /// asks for its label too.
    static func spanning(_ candidates: [Candidate]) -> [(label: Candidate, held: [Candidate])] {
        candidates.compactMap { label in
            var quotes = Set<Set<String>>()
            let held = candidates.filter { other in
                other.label.kind != label.label.kind && other.quote.isStrictSubset(of: label.quote) && quotes.insert(other.quote).inserted
            }
            return held.count > 1 ? (label, held) : nil
        }
    }

    /// The labels of `kind` among `candidates` that are kept. Their quotes join `quoted`, and, when the kind keeps more
    /// than one, `alternatives`, one quote per label kept, as the request then lists alternatives of it.
    private func labels(of kind: LabelKind, from candidates: [Candidate], quoted: inout Set<String>,
                        alternatives: inout [LabelKind: [Set<String>]], notes: inout [String]) -> [DocumentLabel] {
        let key = ClassificationSchema.labelsKey(kind)
        // What labels of the kinds before this one quote: words that already ask for something.
        let earlier = quoted
        var quotes: [String: Set<String>] = [:]
        let kept = candidates.filter { $0.label.kind == kind }.compactMap { candidate -> String? in
            guard !candidate.quote.isSubset(of: earlier) else {
                notes.append("\(key): “\(candidate.label.value)” is asked for by words a label of another kind quotes (“\(candidate.written)”), dropped")
                return nil
            }
            quoted.formUnion(candidate.quote)
            quotes[AnswerValidator.folded(candidate.label.value), default: []].formUnion(candidate.quote)
            return candidate.label.value
        }
        let values = distinct(kept, limit: tasks.maxValuesPerKind, what: key, notes: &notes)
        if values.count > 1 { alternatives[kind] = values.map { quotes[AnswerValidator.folded($0)] ?? [] } }
        return values.map { DocumentLabel(kind: kind, value: $0) }
    }

    /// The words of `given`, kind by kind, that the request, as `sequence` of its words, lists among the alternatives
    /// `quotes` of a kind's labels: written between the words two different ones quote, or within `gap` words of one of
    /// them or of another word so found. A quote, and a word, stands where the request writes those of its words it writes
    /// once, or, when it writes each of them more than once, wherever it writes them (`places`).
    static func alternatives(_ given: [String], in sequence: [String], of quotes: [LabelKind: [Set<String>]],
                             gap: Int) -> [(kind: LabelKind, words: [String])] {
        ClassificationSchema.answerOrder.compactMap { kind -> (kind: LabelKind, words: [String])? in
            guard let quotes = quotes[kind], quotes.count > 1 else { return nil }
            let labelled = quotes.map { places($0, in: sequence) }
            let between = { (position: Int) in
                labelled.indices.contains { first in
                    labelled[first].contains { $0 < position }
                        && labelled.indices.contains { second in second != first && labelled[second].contains { $0 > position } }
                }
            }
            var listing = labelled.reduce(into: Set<Int>()) { $0.formUnion($1) }
            var listed: [String] = []
            var found = true
            while found {
                found = false
                for word in given where !listed.contains(word) {
                    let at = places(words(word), in: sequence)
                    guard at.contains(where: { position in between(position) || listing.contains { abs($0 - position) <= gap + 1 } }) else { continue }
                    listed.append(word)
                    listing.formUnion(at)
                    found = true
                }
            }
            return listed.isEmpty ? nil : (kind, given.filter(listed.contains))
        }
    }

    /// Where `sequence` writes `words`: at those of them it writes once, else wherever it writes them.
    static func places(_ words: Set<String>, in sequence: [String]) -> Set<Int> {
        let at = sequence.indices.filter { words.contains(sequence[$0]) }
        let once = at.filter { position in sequence.count { $0 == sequence[position] } == 1 }
        return Set(once.isEmpty ? at : once)
    }

    /// The words of a text, folded as labels are matched (`LabelUsage.searchWords`).
    static func words(_ text: String) -> Set<String> {
        Set(LabelUsage.searchWords(text))
    }

    /// Each value once, however it is cased or accented, the first `limit` of them.
    private func distinct(_ values: [String], limit: Int, what: String, notes: inout [String]) -> [String] {
        var seen = Set<String>()
        let unique = values.filter { seen.insert(AnswerValidator.folded($0)).inserted }
        if unique.count > limit { notes.append("\(what): more than \(limit), the rest dropped") }
        return Array(unique.prefix(limit))
    }
}

/// The production `SearchPromptInterpreting`. The local model reads the request with the app's own prompt
/// (`search-system.md`), told the archive's labels in use (`search-archive.md`), today's date and the language the request
/// is written in (`search-language.md`, as `LanguageDetector` names it), and answers in a fixed
/// schema (`SearchSchema`), which `SearchPlanValidator` checks; an invalid answer goes back to the model with what was
/// wrong, as a document's does. One model reads it: the chat model of the profile it is given, the task's own or the one
/// Settings uses, which must be installed, with the context documents are read with. The task's effort
/// (`tasks.efforts`) says how much that model thinks before it answers, with the answer length and time thinking needs,
/// how often an answer goes back and how much vocabulary it is shown; an answer that takes longer than that time is no
/// answer, and is not asked for again (`LLMClassifier.ask`). Every call is recorded in the trace, with what the effort
/// wanted the model told about thinking and what it was sent.
public struct SearchPromptInterpreter: SearchPromptInterpreting {
    public let gate: InferenceGate
    public let models: ModelManager
    public let library: PromptTemplates

    public init(gate: InferenceGate, models: ModelManager, library: PromptTemplates) {
        self.gate = gate
        self.models = models
        self.library = library
    }

    public func interpret(_ prompt: String, question: String?, effort: TaskEffort, profile: ModelProfile, vocabulary: [LabelKind: [LabelUsage]],
                          today: String, config: PipelineConfig, trace: TraceContext) async throws -> SearchInterpretation {
        let preset = try config.tasks.preset(effort)
        // A chat model Ollama does not have fails the task with that reason (`LLMClassifier`), rather than another model
        // reading it in its place unasked.
        let model = profile.chatModel
        let languages = LanguageDetector(config: config.extraction)
        let validator = SearchPlanValidator(tasks: config.tasks, labels: config.labels, languages: languages)
        let system = try library.render("search-system", [
            "max_per_kind": String(config.tasks.maxValuesPerKind), "max_words": String(config.tasks.maxWords),
            "max_depth": String(config.tasks.maxGroupingDepth), "max_title_chars": String(config.tasks.maxTitleChars)])
        let language = languages.name(of: prompt)
        let library = library
        // Fitted at `ollama.charsPerToken` first, then, while Ollama counts the prompt filling the context, at what it
        // counted (`PromptBudget.measured`), as often as `ollama.refitAttempts` allows; every call is traced.
        var charsPerToken = config.ollama.charsPerToken
        var refits: [Double] = []
        var earlier: [ModelCall] = []
        let started = Date()
        while true {
            // The archive's labels are shown fewer, the least used first, until the prompt fits the model's context.
            let budget = PromptBudget(numCtx: config.analysis.numCtx, numPredict: preset.numPredict, charsPerToken: charsPerToken)
            var limits = preset.promptLabels
            var leftOut = 0
            var user = try userPrompt(prompt, vocabulary: vocabulary, limits: limits, today: today, language: language)
            while !budget.fits(system, user), let kind = Self.mostShown(vocabulary, limits: limits) {
                limits[kind] = min(limits[kind] ?? 0, vocabulary[kind]?.count ?? 0) - 1
                leftOut += 1
                user = try userPrompt(prompt, vocabulary: vocabulary, limits: limits, today: today, language: language)
            }
            guard budget.fits(system, user) else {
                throw PromptError.tooLong(template: "search-user", chars: system.count + user.count, room: budget.room)
            }
            let input = InterpretInput(effort: effort, model: model, think: preset.think, today: today, language: language,
                                       labelsLeftOut: leftOut == 0 ? nil : leftOut, refitted: refits.isEmpty ? nil : refits)
            var fitted = config
            fitted.ollama.charsPerToken = charsPerToken
            let calls: [ModelCall]
            let outcome: Result<ModelAnswer<ValidatedSearchPlan>, ModelAnswerError>
            // A refit asks afresh, without the repairs before it, so the model has been told of no word yet.
            let sentBack = SentBack()
            do {
                let answer = try await LLMClassifier(gate: gate, models: models, effort: .task(preset, config: fitted)).ask(
                    system: system, user: user, schema: SearchSchema.plan(config.tasks), model: model,
                    repairPrompt: { try library.render("repair-user", ["errors": $0]) }, validate: { try validator.validate($0, request: prompt, question: question, sentBack: sentBack) })
                (calls, outcome) = (answer.calls, .success(answer))
            } catch let error as ModelAnswerError {
                (calls, outcome) = (error.calls, .failure(error))
            }
            let interrupted = if case let .failure(error) = outcome { error.cause != nil } else { false }
            if !interrupted, refits.count < config.ollama.refitAttempts, let measured = budget.measured(calls) {
                refits.append(measured)
                earlier += calls
                charsPerToken = measured
                continue
            }
            let notes = [PromptBudget.refitted(refits), budget.full(calls)].compactMap { $0 }
            switch outcome {
            case let .success(answer):
                await trace.record(.interpret, status: answer.calls.count > 1 || !notes.isEmpty ? .warn : .ok, startedAt: started, input: input,
                                   output: InterpretTrace(answer: answer.answer, promptTokens: PromptBudget.promptTokens(earlier + calls),
                                                          exchange: earlier + calls), error: notes.isEmpty ? nil : notes.joined(separator: "; "))
                return SearchInterpretation(plan: answer.answer.plan, model: answer.model, problem: nil)
            case let .failure(error):
                await trace.record(.interpret, status: error.status, startedAt: started, input: input,
                                   output: InterpretTrace(answer: nil, promptTokens: PromptBudget.promptTokens(earlier + calls), exchange: earlier + calls),
                                   error: ([error.localizedDescription] + notes).joined(separator: "; "))
                if let cause = error.cause { throw cause }
                Log.warning(.classify, "The model gave no valid answer to a search request", ["error": error.localizedDescription])
                return SearchInterpretation(plan: nil, model: nil, problem: "the model gave no valid answer (\(error.localizedDescription))")
            }
        }
    }

    /// What the model is asked: the archive's labels as `limits` shows them, today's date, the request and, when it is
    /// sure of it, the language the request is written in, which the task is named in.
    func userPrompt(_ prompt: String, vocabulary: [LabelKind: [LabelUsage]], limits: [LabelKind: Int], today: String,
                    language: String?) throws -> String {
        let written = try language.map { try library.render("search-language", ["language": $0]) + "\n\n" } ?? ""
        return try library.render("search-user", ["archive": try archiveBlock(vocabulary, limits: limits), "today": today, "request": prompt,
                                                  "language": written])
    }

    /// The kind of which `limits` shows the most labels, the one to show one fewer of; nil when none is shown.
    static func mostShown(_ vocabulary: [LabelKind: [LabelUsage]], limits: [LabelKind: Int]) -> LabelKind? {
        let shown = ClassificationSchema.answerOrder.map { ($0, min(limits[$0] ?? 0, vocabulary[$0]?.count ?? 0)) }.filter { $0.1 > 0 }
        return shown.max { $0.1 < $1.1 }?.0
    }

    /// The labels the archive uses of each kind `limits` names, the most used first, by the answer's name for their
    /// kind, one kind per line, each label a JSON string (`ClassificationSchema.listed`); empty for an archive without
    /// any. A kind `limits` does not name is shown none.
    func archiveBlock(_ vocabulary: [LabelKind: [LabelUsage]], limits: [LabelKind: Int]) throws -> String {
        let used = ClassificationSchema.answerOrder.compactMap { kind -> String? in
            guard let limit = limits[kind] else { return nil }
            let values = (vocabulary[kind] ?? []).prefix(limit).map(\.label.value)
            return values.isEmpty ? nil : "- \(ClassificationSchema.labelsKey(kind)): " + ClassificationSchema.listed(values)
        }
        guard !used.isEmpty else { return "" }
        return try library.render("search-archive", ["used": used.joined(separator: "\n")]) + "\n\n"
    }
}

/// What reading a search request records it was read with: the effort, the model, what the effort wanted the model told
/// about thinking, the day, the language the model was told the request is in, when it was, how many of the archive's
/// labels the effort would show were left out so the prompt fit the model's context, when any were, and the characters
/// a token it was fitted at again each time Ollama counted it filling the context (`PromptBudget.measured`). What was
/// sent, as the model allows, is each `ModelCall.think` of the exchange, which retention clears; this stays, so the trace
/// still says how much the model was asked to think once the exchange is gone.
struct InterpretInput: Encodable {
    var effort: TaskEffort
    var model: String
    var think: OllamaThink
    var today: String
    var language: String?
    var labelsLeftOut: Int?
    var refitted: [Double]?
}

/// What reading a search request records: the validated plan, and every model call under `TraceStep.exchangeKey`, which
/// retention clears.
struct InterpretTrace: Codable {
    var answer: ValidatedSearchPlan?
    /// The tokens each call's prompt took, as Ollama counted them (`PromptBudget.promptTokens`), which retention keeps.
    var promptTokens: [Int]
    var exchange: [ModelCall]
}
