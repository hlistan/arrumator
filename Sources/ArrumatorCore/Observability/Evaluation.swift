import Foundation

/// How `arrumatorcli eval` scores the reading of a fixture corpus against `expected.json` (docs/evaluation.md): whether
/// each document was filed, waited for the user or was taken for a copy, whose original is read again in its place; its
/// type, sender, date and language labels and its file name; whether it got the other labels the corpus expects of it
/// (parties, objects, references, periods, deadlines, amounts, jurisdictions); how many labels of each kind documents
/// got; and how the model judged the corpus's pairs of labels that look alike. Every number of an eval run comes from
/// here, from what the run recorded, without a model.
public enum Evaluation {
    public struct Expected: Decodable, Sendable {
        public var status: DocumentStatus
        public var docType: String?
        public var correspondent: String?
        public var date: String?
        public var titleContains: [String]
        /// Labels expected by kind; each value, or one of its `|` alternatives, must be found in a label of that kind.
        public var labels: [String: [String]]?
        enum CodingKeys: String, CodingKey {
            case status, docType = "doc_type", correspondent, date, titleContains = "title_contains", labels
        }
    }

    public struct AcceptAlso: Decodable, Sendable {
        public var docType: [String]?
        public var correspondent: [String]?
        enum CodingKeys: String, CodingKey { case docType = "doc_type", correspondent }
    }

    public struct Fixture: Decodable, Sendable {
        public var file: String
        public var lang: String
        public var expected: Expected
        public var acceptAlso: AcceptAlso?
        /// For a byte-identical copy: the fixture it copies.
        public var duplicateOf: String?
        enum CodingKeys: String, CodingKey { case file, lang, expected, acceptAlso = "accept_also", duplicateOf = "duplicate_of" }
    }

    /// Two labels that look alike, as the corpus writes them, and whether they are one label written two ways: what the
    /// model judges (`LabelPairJudging`), shown how many documents have each and the names of some, as the archive would
    /// show it them.
    public struct PairCase: Decodable, Sendable {
        public var kind: LabelKind
        public var value: String
        public var into: String
        public var valueDocuments: Int
        public var valueNames: [String]
        public var intoDocuments: Int
        public var intoNames: [String]
        public var same: Bool
        public var why: String
        /// Of a kind of difference the judge's prompt neither names nor shows.
        public var heldOut: Bool
        enum CodingKeys: String, CodingKey {
            case kind, value, into, valueDocuments = "value_documents", valueNames = "value_names", intoDocuments = "into_documents",
                 intoNames = "into_names", same, why, heldOut = "held_out"
        }

        /// The pair as the archive would offer it to be judged.
        public var suggestion: LabelSuggestion {
            LabelSuggestion(kind: kind, value: value, into: into, similarity: LabelSimilarity.similarity(value, into), reason: .writtenAlike)
        }

        /// What each label is used for, as the model is shown it.
        public var use: LabelPairUse {
            LabelPairUse(valueDocuments: valueDocuments, valueNames: valueNames, intoDocuments: intoDocuments, intoNames: intoNames)
        }

        public var expected: LabelJudgement { same ? .same : .different }

        /// Why the pair cannot be asked as it is, as the archive could never offer it to be judged: a label not in its
        /// kind's form, a kind the vocabulary keeps no pairs of, or two labels written alike, which a reading makes one
        /// whatever the thresholds (`LabelSimilarity.sameWriting`); nil when it can. A pair less alike than its kind's
        /// `suggestSimilarity` can be asked: a lower threshold, which a user may set, offers it.
        public func problem(vocabulary: LabelVocabularyConfig) -> String? {
            guard vocabulary.kinds[kind] != nil else { return "\(kind.rawValue) is no kind the vocabulary keeps" }
            for label in [value, into] where DocumentLabel.normalized(label, kind: kind)?.value != label {
                return "“\(label)” is no \(kind.rawValue) as the archive keeps one"
            }
            if LabelSimilarity.sameWriting(value, into) { return "“\(value)” and “\(into)” are written alike, so the archive keeps them as one" }
            return nil
        }
    }

    public struct Corpus: Decodable, Sendable {
        public var fixtures: [Fixture]
        public var labelPairs: [PairCase]
        enum CodingKeys: String, CodingKey { case fixtures, labelPairs = "label_pairs" }
    }

    /// How the model judged one pair in one pass.
    public struct PairRow: Encodable, Sendable {
        public var pass: Int
        public var kind: LabelKind
        public var value: String
        public var into: String
        public var expected: LabelJudgement
        public var heldOut: Bool
        /// Nil when it gave no valid answer.
        public var judged: LabelJudgement?
        public var reason: String?
        public var seconds: Double

        public init(pass: Int, pair: PairCase, verdict: LabelVerdict, seconds: Double) {
            self.pass = pass
            kind = pair.kind
            value = pair.value
            into = pair.into
            expected = pair.expected
            heldOut = pair.heldOut
            judged = verdict.judgement
            reason = verdict.reason ?? verdict.problem
            self.seconds = seconds
        }
    }

    /// How one pass judged the pairs: the share judged right, and the wrong ones by what they would do. A pair merged that
    /// is two labels files documents together that do not belong so, which only the user can undo; one kept apart that
    /// is one leaves two labels side by side.
    public struct PairSummary: Encodable, Sendable {
        public var pass: Int
        public var pairs: Int
        public var accuracy: Double
        public var wronglyMerged: Int
        public var wronglyKeptApart: Int
        public var unanswered: Int
        /// Of the pairs held out from what the prompt names and shows, how many there are and the share judged right.
        public var heldOut: Int
        public var heldOutAccuracy: Double
        public var medianSeconds: Double
    }

    public static func summarize(pass: Int, pairs rows: [PairRow]) -> PairSummary {
        let seconds = rows.map(\.seconds).sorted()
        let right = { (rows: [PairRow]) in rows.isEmpty ? 0 : Double(rows.count { $0.judged == $0.expected }) / Double(rows.count) }
        let heldOut = rows.filter(\.heldOut)
        return PairSummary(pass: pass, pairs: rows.count, accuracy: right(rows),
                           wronglyMerged: rows.count { $0.judged == .same && $0.expected == .different },
                           wronglyKeptApart: rows.count { $0.judged == .different && $0.expected == .same },
                           unanswered: rows.count { $0.judged == nil }, heldOut: heldOut.count, heldOutAccuracy: right(heldOut),
                           medianSeconds: seconds.isEmpty ? 0 : seconds[seconds.count / 2])
    }

    /// How one fixture was read in one pass.
    public struct Row: Encodable, Sendable {
        public var pass: Int
        public var file: String
        public var status: String
        public var statusOK: Bool
        public var fileName: String
        public var labels: [DocumentLabel]?
        public var docTypeOK: Bool?
        public var correspondentOK: Bool?
        public var dateOK: Bool?
        public var titleOK: Bool?
        /// Whether the document's language labels include the language the corpus wrote it in.
        public var languageOK: Bool?
        /// For each expected label, as `kind: value`, whether the document got it.
        public var expectedLabels: [String: Bool]?
        /// Whether the model said what the document is (`DocumentAnalysis.interpretation`).
        public var interpreted: Bool?
        /// Whether what it said is in the language the corpus wrote the document in, as the prompt asks; nil when it said
        /// nothing, or the corpus names no language.
        public var interpretationLanguageOK: Bool?
        public var seconds: Double
    }

    /// How one pass over the corpus read it.
    public struct Summary: Encodable, Sendable {
        public var pass: Int
        public var statusAccuracy: Double
        public var docTypeAccuracy: Double
        public var correspondentAccuracy: Double
        public var dateAccuracy: Double
        public var titleAccuracy: Double
        public var languageAccuracy: Double
        /// Of the documents that should be filed, those the model labelled.
        public var labelled: Double
        public var labelsPerDocument: Double
        /// Of the labelled documents that should be filed, the share with at least one label of each kind.
        public var coverage: [String: Double]
        /// Of the labels the corpus expects, the share found, in all and by kind.
        public var expectedFound: Double
        public var expectedFoundByKind: [String: Double]
        /// Of the senders the corpus expects on more than one document, how many ways each was written on average: 1 when
        /// every document from one sender got the same sender label.
        public var senderWritings: Double
        /// How many different labels of each kind the documents got in all, as a label list would show them.
        public var distinctByKind: [String: Int]
        /// Of the documents that should be filed, those the model said what they are of; and of those whose language the
        /// corpus names, the share it said it in that language.
        public var interpreted: Double
        public var interpretationLanguage: Double
        public var medianSeconds: Double

        /// The share of details read right: type, sender, date and title together.
        public var details: Double { (docTypeAccuracy + correspondentAccuracy + dateAccuracy + titleAccuracy) / 4 }
    }

    /// The status of a fixture that became no document the run can find.
    public static let missing = "missing"

    /// The name `file` is put into Incoming under in `pass`: its own in the first, then marked with the pass.
    public static func droppedName(_ file: String, pass: Int) -> String {
        let name = (file as NSString).lastPathComponent
        return pass == 1 ? name : "\((name as NSString).deletingPathExtension) pass\(pass).\((name as NSString).pathExtension)"
    }

    /// A byte-identical copy becomes no document of its own: the document it copies is read again in its place. It is
    /// right when `original`, that document, is the one of the fixture the corpus says it copies.
    public static func copy(_ fixture: Fixture, pass: Int, original: DocumentRecord, seconds: Double) -> Row {
        let copies = fixture.duplicateOf.map { droppedName($0, pass: pass) }
        return Row(pass: pass, file: fixture.file, status: EventKind.duplicate.rawValue, statusOK: original.originalFilename == copies,
                   fileName: original.filename, labels: original.labels, seconds: seconds)
    }

    /// How `document`, the newest the run filed, read the fixture dropped as `dropped`: missing when it is another file's.
    /// `languages` tells the language the model said what it is in.
    public static func score(_ fixture: Fixture, pass: Int, document: DocumentRecord?, dropped: URL, languages: LanguageDetector,
                             seconds: Double) -> Row {
        let e = fixture.expected
        guard let doc = document, doc.originalFilename == dropped.lastPathComponent else {
            return Row(pass: pass, file: fixture.file, status: missing, statusOK: false, fileName: "", seconds: seconds)
        }
        func folded(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        func contains(_ actual: String?, anyOf expected: [String]) -> Bool? {
            guard !expected.isEmpty else { return nil }
            return actual.map { a in expected.contains { folded(a).contains(folded($0)) } } ?? false
        }
        let ordinary = e.status == .filed
        let senders = (e.correspondent.map { [$0] } ?? []) + (fixture.acceptAlso?.correspondent ?? [])
        let types = (e.docType.map { [$0] } ?? []) + (fixture.acceptAlso?.docType ?? [])
        let written = doc.labels?.filter { $0.kind == .language }.map(\.value)
        let interpretation = doc.analysis?.interpretation
        let known = DocumentLabel.languageCode(fixture.lang) != nil
        return Row(pass: pass, file: fixture.file, status: doc.status.rawValue, statusOK: doc.status == e.status, fileName: doc.filename,
                   labels: doc.labels,
                   docTypeOK: ordinary && !types.isEmpty ? doc.labels(.type).first.map(types.contains) ?? false : nil,
                   correspondentOK: ordinary && !senders.isEmpty ? doc.labels(.sender).contains { contains($0, anyOf: senders) == true } : nil,
                   dateOK: ordinary ? e.date.map { $0 == doc.labels(.date).first } : nil,
                   titleOK: ordinary && !e.titleContains.isEmpty ? e.titleContains.contains { folded(doc.filename).contains(folded($0)) } : nil,
                   languageOK: ordinary && known ? written?.contains(fixture.lang) ?? false : nil,
                   expectedLabels: ordinary ? e.labels.map { found($0, in: doc.labels ?? []) } : nil,
                   interpreted: ordinary ? interpretation != nil : nil,
                   interpretationLanguageOK: ordinary && known ? interpretation.map { languages.code(of: $0) == fixture.lang } : nil,
                   seconds: seconds)
    }

    /// Whether each expected label, as `kind: value`, is among the document's labels: an amount by its number and
    /// currency, a date or period by its start, anything else by its words, ignoring case, accents and spacing.
    public static func found(_ expected: [String: [String]], in labels: [DocumentLabel]) -> [String: Bool] {
        func folded(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).filter { !$0.isWhitespace }
        }
        func amount(_ s: String) -> (Double, String)? {
            let parts = s.split(separator: " ")
            guard parts.count == 2, let value = Double(parts[0]) else { return nil }
            return (value, String(parts[1]).uppercased())
        }
        var results: [String: Bool] = [:]
        for (key, values) in expected {
            guard let kind = LabelKind(rawValue: key) else { continue }
            let actual = labels.values(kind)
            for value in values {
                results["\(key): \(value)"] = value.split(separator: "|").map(String.init).contains { option in
                    actual.contains { label in
                        switch kind {
                        case .amount:
                            guard let want = amount(option), let got = amount(label) else { return false }
                            return abs(want.0 - got.0) < amountTolerance && want.1 == got.1
                        case .date, .deadline, .period: return label.hasPrefix(option)
                        default: return folded(label).contains(folded(option))
                        }
                    }
                }
            }
        }
        return results
    }

    /// Two amounts within half a cent are one: what a currency's smallest unit leaves of a rounding.
    static let amountTolerance = 0.005

    /// How the pass `pass` read `corpus`, from its `rows`.
    public static func summarize(pass: Int, rows: [Row], corpus: [Fixture]) -> Summary {
        func rate(_ values: [Bool?]) -> Double {
            let known = values.compactMap { $0 }
            return known.isEmpty ? 0 : Double(known.filter { $0 }.count) / Double(known.count)
        }
        let ordinary = Set(corpus.filter { $0.expected.status == .filed }.map(\.file))
        let filed = rows.filter { ordinary.contains($0.file) }
        let labelled = filed.filter { $0.labels != nil }
        let coverage = Dictionary(uniqueKeysWithValues: LabelKind.modelKinds.map { kind in
            (kind.rawValue, labelled.isEmpty ? 0 : Double(labelled.filter { $0.labels?.contains { $0.kind == kind } == true }.count)
                / Double(labelled.count))
        })
        let checks = filed.compactMap(\.expectedLabels).flatMap { $0 }
        let byKind = Dictionary(grouping: checks) { String($0.key.prefix { $0 != ":" }) }
            .mapValues { rate($0.map(\.value)) }
        let seconds = rows.map(\.seconds).sorted()
        let expectedSender = Dictionary(corpus.compactMap { f in f.expected.correspondent.map { (f.file, $0.lowercased()) } },
                                        uniquingKeysWith: { a, _ in a })
        let writings = Dictionary(grouping: labelled.filter { expectedSender[$0.file] != nil }) { expectedSender[$0.file] ?? "" }
            .values.filter { $0.count > 1 }
            .map { Double(Set($0.compactMap { $0.labels?.values(.sender).first }).count) }
        let distinct = Dictionary(uniqueKeysWithValues: LabelKind.modelKinds.map { kind in
            (kind.rawValue, Set(rows.flatMap { $0.labels?.values(kind) ?? [] }).count)
        })
        return Summary(pass: pass, statusAccuracy: rate(rows.map(\.statusOK)), docTypeAccuracy: rate(rows.map(\.docTypeOK)),
                       correspondentAccuracy: rate(rows.map(\.correspondentOK)), dateAccuracy: rate(rows.map(\.dateOK)),
                       titleAccuracy: rate(rows.map(\.titleOK)), languageAccuracy: rate(rows.map(\.languageOK)),
                       labelled: filed.isEmpty ? 0 : Double(labelled.count) / Double(filed.count),
                       labelsPerDocument: labelled.isEmpty ? 0 : Double(labelled.compactMap(\.labels?.count).reduce(0, +)) / Double(labelled.count),
                       coverage: coverage, expectedFound: rate(checks.map(\.value)), expectedFoundByKind: byKind,
                       senderWritings: writings.isEmpty ? 0 : writings.reduce(0, +) / Double(writings.count), distinctByKind: distinct,
                       interpreted: rate(filed.map(\.interpreted)), interpretationLanguage: rate(filed.map(\.interpretationLanguageOK)),
                       medianSeconds: seconds.isEmpty ? 0 : seconds[seconds.count / 2])
    }
}
