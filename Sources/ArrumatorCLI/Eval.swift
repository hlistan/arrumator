import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

/// Runs a fixture corpus through the full live pipeline in a throw-away home and archive, then scores how each
/// document was read against `expected.json`: whether it was filed, waited for the user or was taken for a copy; its
/// type, sender, date and language labels and its file name; and how many labels of each kind documents got.
struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Evaluate the live pipeline on a fixture corpus (expected.json).")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Fixture directory containing expected.json.") var fixtures: String
    @Option(help: "Chat model to use instead of the profile's.") var model: String?
    @Option(help: "Model profile from pipeline.json.") var profile: String?
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
        enum CodingKeys: String, CodingKey {
            case status, docType = "doc_type", correspondent, date, titleContains = "title_contains"
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
        enum CodingKeys: String, CodingKey { case file, lang, expected, acceptAlso = "accept_also" }
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
        // The throw-away folders are chosen before the runtime opens, as the runtime is open on one archive.
        let (model, profile) = (model, profile)
        try await SettingsStore(paths: AppPaths.resolve(environment)).update { s in
            s.archivePath = home.appendingPathComponent("Archive").path
            s.incomingPath = home.appendingPathComponent("Incoming").path
            if let profile { s.models.profile = profile }
            if let model { s.models.chatModel = model }
        }
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: Arrumator.version, environment: environment,
                                                           echoLogsToStderr: options.verbose)
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
                let name = pass == 1 ? source.lastPathComponent
                    : "\((source.lastPathComponent as NSString).deletingPathExtension) pass\(pass).\(source.pathExtension)"
                let target = settings.incomingURL.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: settings.incomingURL, withIntermediateDirectories: true)
                var data = try Data(contentsOf: source)
                // Later passes need different bytes, otherwise they are (correctly) taken for copies.
                if pass > 1 { data.append(contentsOf: [UInt8](repeating: 0x0A, count: pass - 1)) }
                try data.write(to: target)
                let started = Date()
                await runtime.coordinator.enqueue(target)
                await runtime.coordinator.drain()
                let row = try await score(fixture: fixture, pass: pass, filedFrom: target, seconds: Date().timeIntervalSince(started),
                                          runtime: runtime)
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
            print("labels per kind: " + LabelKind.allCases.map { String(format: "%@ %.0f%%", $0.rawValue, (summary.coverage[$0.rawValue] ?? 0) * 100) }
                .joined(separator: " · "))
        }
        if let report {
            struct Report: Encodable { var rows: [Row]; var summaries: [Summary] }
            try JSON.prettyEncoder.encode(Report(rows: rows, summaries: summaries)).write(to: URL(fileURLWithPath: report.expandingTilde))
        }
        await runtime.stop()
        if let minAccuracy, let first = summaries.first, first.details < minAccuracy { throw ExitCode(1) }
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
                   seconds: seconds)
    }

    static func summarize(pass: Int, rows: [Row], corpus: [Fixture]) -> Summary {
        func rate(_ values: [Bool?]) -> Double {
            let known = values.compactMap { $0 }
            return known.isEmpty ? 0 : Double(known.filter { $0 }.count) / Double(known.count)
        }
        let ordinary = Set(corpus.filter { $0.expected.status == .filed }.map(\.file))
        let filed = rows.filter { ordinary.contains($0.file) }
        let labelled = filed.filter { $0.labels != nil }
        let coverage = Dictionary(uniqueKeysWithValues: LabelKind.allCases.map { kind in
            (kind.rawValue, labelled.isEmpty ? 0 : Double(labelled.filter { $0.labels?.contains { $0.kind == kind } == true }.count)
                / Double(labelled.count))
        })
        let seconds = rows.map(\.seconds).sorted()
        return Summary(pass: pass, statusAccuracy: rate(rows.map(\.statusOK)), docTypeAccuracy: rate(rows.map(\.docTypeOK)),
                       correspondentAccuracy: rate(rows.map(\.correspondentOK)), dateAccuracy: rate(rows.map(\.dateOK)),
                       titleAccuracy: rate(rows.map(\.titleOK)), languageAccuracy: rate(rows.map(\.languageOK)),
                       labelled: filed.isEmpty ? 0 : Double(labelled.count) / Double(filed.count),
                       labelsPerDocument: labelled.isEmpty ? 0 : Double(labelled.compactMap(\.labels?.count).reduce(0, +)) / Double(labelled.count),
                       coverage: coverage,
                       medianSeconds: seconds.isEmpty ? 0 : seconds[seconds.count / 2])
    }
}
