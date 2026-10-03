import Foundation

/// How `arrumatorcli eval` scores the reading of a fixture corpus against `expected.json` (docs/evaluation.md): whether
/// each document was filed, waited for the user or was taken for a copy, whose original is read again in its place; its
/// type, sender, date and language labels and its file name; whether it got the other labels the corpus expects of it
/// (parties, objects, references, periods, deadlines, amounts, jurisdictions); and how many labels of each kind
/// documents got. Every number of an eval run comes from here, from what the run recorded, without a model.
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

    public struct Corpus: Decodable, Sendable {
        public var fixtures: [Fixture]
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
    public static func score(_ fixture: Fixture, pass: Int, document: DocumentRecord?, dropped: URL, seconds: Double) -> Row {
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
        let languages = doc.labels?.filter { $0.kind == .language }.map(\.value)
        return Row(pass: pass, file: fixture.file, status: doc.status.rawValue, statusOK: doc.status == e.status, fileName: doc.filename,
                   labels: doc.labels,
                   docTypeOK: ordinary && !types.isEmpty ? doc.labels(.type).first.map(types.contains) ?? false : nil,
                   correspondentOK: ordinary && !senders.isEmpty ? doc.labels(.sender).contains { contains($0, anyOf: senders) == true } : nil,
                   dateOK: ordinary ? e.date.map { $0 == doc.labels(.date).first } : nil,
                   titleOK: ordinary && !e.titleContains.isEmpty ? e.titleContains.contains { folded(doc.filename).contains(folded($0)) } : nil,
                   languageOK: ordinary && DocumentLabel.languageCode(fixture.lang) != nil ? languages?.contains(fixture.lang) ?? false : nil,
                   expectedLabels: ordinary ? e.labels.map { found($0, in: doc.labels ?? []) } : nil,
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
                       medianSeconds: seconds.isEmpty ? 0 : seconds[seconds.count / 2])
    }
}
