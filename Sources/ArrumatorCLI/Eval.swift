import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

/// Runs a fixture corpus through the full live pipeline in a throw-away home and archive, then scores how each
/// document was read against `expected.json`: whether it was filed, waited for the user or was taken for a copy, whose
/// original is read again in its place; its
/// type, sender, date and language labels and its file name; whether it got the other labels the corpus expects of it
/// (parties, objects, references, periods, deadlines, amounts, jurisdictions); and how many labels of each kind
/// documents got.
struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Evaluate the live pipeline on a fixture corpus (expected.json).")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Fixture directory containing expected.json.") var fixtures: String
    @Option(help: "Chat model to read documents with instead of the profile's.") var model: String?
    @Option(help: ArgumentHelp("A profile the app comes with to read with, by its id, instead of the one it comes set to. eval runs in "
        + "a throw-away home with the settings the app comes with, so your own profiles and your changes to the predefined ones are not used."))
    var profile: String?
    @Option(help: "Passes over the corpus; later passes show how consistently the model reads the same documents.") var passes = 1
    @Option(help: "Only the fixtures whose path starts with this, such as \"pt/\", for a quick look.") var only: String?
    @Option(help: "Write the full report as JSON to this path.") var report: String?
    @Option(help: "Fail when the first pass reads fewer than this share of details right (type, sender, date, title).")
    var minAccuracy: Double?

    struct Expected: Decodable {
        var status: DocumentStatus
        var docType: String?
        var correspondent: String?
        var date: String?
        var titleContains: [String]
        /// Labels expected by kind; each value, or one of its `|` alternatives, must be found in a label of that kind.
        var labels: [String: [String]]?
        enum CodingKeys: String, CodingKey {
            case status, docType = "doc_type", correspondent, date, titleContains = "title_contains", labels
        }
    }

    struct AcceptAlso: Decodable {
        var docType: [String]?
        var correspondent: [String]?
        enum CodingKeys: String, CodingKey { case docType = "doc_type", correspondent }
    }

    struct Fixture: Decodable {
        var file: String
        var lang: String
        var expected: Expected
        var acceptAlso: AcceptAlso?
        /// For a byte-identical copy: the fixture it copies.
        var duplicateOf: String?
        enum CodingKeys: String, CodingKey { case file, lang, expected, acceptAlso = "accept_also", duplicateOf = "duplicate_of" }
    }

    struct Corpus: Decodable { var fixtures: [Fixture] }

    struct Row: Encodable {
        var pass: Int
        var file: String
        var status: String
        var statusOK: Bool
        var fileName: String
        var labels: [DocumentLabel]?
        var docTypeOK: Bool?
        var correspondentOK: Bool?
        var dateOK: Bool?
        var titleOK: Bool?
        /// Whether the document's language labels include the language the corpus wrote it in.
        var languageOK: Bool?
        /// For each expected label, as `kind: value`, whether the document got it.
        var expectedLabels: [String: Bool]?
        var seconds: Double
    }

    struct Summary: Encodable {
        var pass: Int
        var statusAccuracy: Double
        var docTypeAccuracy: Double
        var correspondentAccuracy: Double
        var dateAccuracy: Double
        var titleAccuracy: Double
        var languageAccuracy: Double
        /// Of the documents that should be filed, those the model labelled.
        var labelled: Double
        var labelsPerDocument: Double
        /// Of the labelled documents that should be filed, the share with at least one label of each kind.
        var coverage: [String: Double]
        /// Of the labels the corpus expects, the share found, in all and by kind.
        var expectedFound: Double
        var expectedFoundByKind: [String: Double]
        /// Of the senders the corpus expects on more than one document, how many ways each was written on average: 1 when
        /// every document from one sender got the same sender label.
        var senderWritings: Double
        /// How many different labels of each kind the documents got in all, as a label list would show them.
        var distinctByKind: [String: Int]
        var medianSeconds: Double

        /// The share of details read right: type, sender, date and title together.
        var details: Double { (docTypeAccuracy + correspondentAccuracy + dateAccuracy + titleAccuracy) / 4 }
    }

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let dir = URL(fileURLWithPath: fixtures.expandingTilde, isDirectory: true)
        var corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: dir.appendingPathComponent("expected.json")))
        if let only { corpus.fixtures = corpus.fixtures.filter { $0.file.hasPrefix(only) } }
        guard !corpus.fixtures.isEmpty else { throw ValidationError("No fixture path starts with \(only ?? "")") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-eval-\(UUID().uuidString)", isDirectory: true)
        var environment = RuntimeEnvironment.current
        environment.home = home.path
        // The throw-away folders are chosen before the runtime opens, as the runtime is open on one archive; a profile the
        // settings do not list is refused before anything is read. The archive is new, so its folder is made here, as
        // setting an archive up makes it: the runtime never makes one by itself.
        let store = try SettingsStore(paths: AppPaths.resolve(environment))
        var chosen = await store.current
        let archive = home.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        chosen.archivePath = archive.path
        chosen.incomingPath = home.appendingPathComponent("Incoming").path
        if let profile { chosen.profile = profile }
        if let model { chosen = try chosen.reading(withChatModel: model) }
        try await store.save(chosen)
        // A copy goes into a Trash of the throw-away home, never the user's.
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: Arrumator.version, environment: environment,
                                                           echoLogsToStderr: options.verbose,
                                                           trash: FolderTrash(folder: home.appendingPathComponent("Trash", isDirectory: true)))
        try await runtime.openArchive()
        let settings = await runtime.settings.current
        guard await runtime.lifecycle.ensureRunning().isReady else { throw ValidationError("Ollama is not running") }
        print("Evaluating \(corpus.fixtures.count) fixtures × \(passes) pass(es) in \(home.path)")
        var rows: [Row] = []
        var summaries: [Summary] = []
        for pass in 1...passes {
            var passRows: [Row] = []
            for fixture in corpus.fixtures {
                let source = dir.appendingPathComponent(fixture.file)
                let target = settings.incomingURL.appendingPathComponent(Self.droppedName(fixture.file, pass: pass))
                try FileManager.default.createDirectory(at: settings.incomingURL, withIntermediateDirectories: true)
                var data = try Data(contentsOf: source)
                // Later passes need different bytes, otherwise they are (correctly) taken for copies of the first's.
                if pass > 1 { data.append(contentsOf: [UInt8](repeating: 0x0A, count: pass - 1)) }
                try data.write(to: target)
                let started = Date()
                await runtime.coordinator.enqueue(target)
                await runtime.coordinator.drain()
                let seconds = Date().timeIntervalSince(started)
                let row = fixture.expected.status == .duplicate
                    ? try await scoreCopy(fixture: fixture, pass: pass, dropped: target, seconds: seconds, runtime: runtime)
                    : try await score(fixture: fixture, pass: pass, filedFrom: target, seconds: seconds, runtime: runtime)
                passRows.append(row)
                print(String(format: "%@ %-44@ %-11@ %5.1fs %@", "p\(pass)", fixture.file, row.status, row.seconds, row.fileName))
            }
            let summary = Self.summarize(pass: pass, rows: passRows, corpus: corpus.fixtures)
            summaries.append(summary)
            rows += passRows
            print(String(format: "pass %d: status %.0f%% · type %.0f%% · sender %.0f%% · date %.0f%% · title %.0f%% · language %.0f%% · "
                                 + "labelled %.0f%%, %.1f labels each · median %.1fs",
                         pass, summary.statusAccuracy * 100, summary.docTypeAccuracy * 100, summary.correspondentAccuracy * 100,
                         summary.dateAccuracy * 100, summary.titleAccuracy * 100, summary.languageAccuracy * 100,
                         summary.labelled * 100, summary.labelsPerDocument, summary.medianSeconds))
            print("labels per kind: " + LabelKind.modelKinds.map { String(format: "%@ %.0f%%", $0.rawValue, (summary.coverage[$0.rawValue] ?? 0) * 100) }
                .joined(separator: " · "))
            print(String(format: "expected labels found: %.0f%% (", summary.expectedFound * 100)
                  + LabelKind.modelKinds.compactMap { kind in
                      summary.expectedFoundByKind[kind.rawValue].map { String(format: "%@ %.0f%%", kind.rawValue, $0 * 100) }
                  }.joined(separator: " · ") + ")")
            print(String(format: "sender writings: %.2f each · distinct labels: ", summary.senderWritings)
                  + LabelKind.modelKinds.compactMap { kind in summary.distinctByKind[kind.rawValue].map { "\(kind.rawValue) \($0)" } }
                  .joined(separator: " · "))
        }
        if let report {
            struct Report: Encodable { var rows: [Row]; var summaries: [Summary] }
            try JSON.prettyEncoder.encode(Report(rows: rows, summaries: summaries)).write(to: URL(fileURLWithPath: report.expandingTilde))
        }
        await runtime.stop()
        if let minAccuracy, let first = summaries.first, first.details < minAccuracy { throw ExitCode(1) }
    }

    /// The name `file` is put into Incoming under in `pass`: its own in the first, then marked with the pass.
    static func droppedName(_ file: String, pass: Int) -> String {
        let name = (file as NSString).lastPathComponent
        return pass == 1 ? name : "\((name as NSString).deletingPathExtension) pass\(pass).\((name as NSString).pathExtension)"
    }

    /// A byte-identical copy becomes no document of its own: it goes to the Trash, and the document it copies is read again
    /// in its place, as History records under that document. It is right when that is the document of the fixture the
    /// corpus says it copies; one taken for no copy, as when `--only` left its original out, is scored as a document.
    private func scoreCopy(fixture: Fixture, pass: Int, dropped: URL, seconds: Double, runtime: ArrumatorRuntime) async throws -> Row {
        let event = try await runtime.services.history.events(limit: 1, kinds: [.duplicate]).first
        guard let event, JSON.decode(CopyPayload.self, from: event.payloadJson)?.isCopy(at: dropped) == true,
              let docID = event.docId, let original = try await runtime.services.documents.document(id: docID) else {
            return try await score(fixture: fixture, pass: pass, filedFrom: dropped, seconds: seconds, runtime: runtime)
        }
        let copies = fixture.duplicateOf.map { Self.droppedName($0, pass: pass) }
        return Row(pass: pass, file: fixture.file, status: EventKind.duplicate.rawValue, statusOK: original.originalFilename == copies,
                   fileName: original.filename, labels: original.labels, seconds: seconds)
    }

    private func score(fixture: Fixture, pass: Int, filedFrom: URL, seconds: Double, runtime: ArrumatorRuntime) async throws -> Row {
        let e = fixture.expected
        guard let doc = try await runtime.services.documents.list(DocumentFilter(), limit: 1).first,
              doc.originalFilename == filedFrom.lastPathComponent else {
            return Row(pass: pass, file: fixture.file, status: "missing", statusOK: false, fileName: "", seconds: seconds)
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
                   expectedLabels: ordinary ? e.labels.map { Self.found($0, in: doc.labels ?? []) } : nil,
                   seconds: seconds)
    }

    /// Whether each expected label, as `kind: value`, is among the document's labels: an amount by its number and
    /// currency, a date or period by its start, anything else by its words, ignoring case, accents and spacing.
    static func found(_ expected: [String: [String]], in labels: [DocumentLabel]) -> [String: Bool] {
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
                            return abs(want.0 - got.0) < 0.005 && want.1 == got.1
                        case .date, .deadline, .period: return label.hasPrefix(option)
                        default: return folded(label).contains(folded(option))
                        }
                    }
                }
            }
        }
        return results
    }

    static func summarize(pass: Int, rows: [Row], corpus: [Fixture]) -> Summary {
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
