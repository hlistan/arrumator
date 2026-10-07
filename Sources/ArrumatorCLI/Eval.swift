import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

/// Runs a fixture corpus through the full live pipeline in a throw-away home and archive, then scores how each
/// document was read against `expected.json` (`Evaluation`).
struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Evaluate the live pipeline on a fixture corpus (expected.json).")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Fixture directory containing expected.json.") var fixtures: String
    @Option(help: "Chat model to read documents with instead of the profile's.") var model: String?
    @Option(help: ArgumentHelp("A profile the app comes with to read with, by its id, instead of the one it comes set to. eval runs in "
        + "a throw-away home with the settings the app comes with, so your own profiles and your changes to the predefined ones are not used."))
    var profile: String?
    @Option(help: "Passes over the corpus, at least 1; later passes show how consistently the model reads the same documents.")
    var passes = 1
    @Option(help: "Only the fixtures whose path starts with this, such as \"pt/\", for a quick look.") var only: String?
    @Option(help: "Write the full report as JSON to this path.") var report: String?
    @Option(help: "Fail when the first pass reads fewer than this share of details right (type, sender, date, title).")
    var minAccuracy: Double?

    func validate() throws {
        if passes < 1 { throw ValidationError("--passes must be at least 1") }
    }

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let dir = URL(fileURLWithPath: fixtures.expandingTilde, isDirectory: true)
        var corpus = try JSONDecoder().decode(Evaluation.Corpus.self, from: Data(contentsOf: dir.appendingPathComponent("expected.json")))
        if let only { corpus.fixtures = corpus.fixtures.filter { $0.file.hasPrefix(only) } }
        guard !corpus.fixtures.isEmpty else { throw ValidationError("No fixture path starts with \(only ?? "")") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-eval-\(UUID().uuidString)", isDirectory: true)
        // Thrown away when the command ends, however it ends, Ctrl-C included (`Arrumator.main`).
        OpenedArchives.current?.discardAfterwards(home)
        var environment = RuntimeEnvironment.current
        environment.home = home.path
        // The throw-away folders are chosen before the runtime opens, as the runtime is open on one archive; a profile the
        // settings do not list is refused before anything is read. The archive is new, so its folder is made here, as
        // setting an archive up makes it: the runtime never makes one by itself.
        let (profile, model) = (profile, model)
        let archive = home.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let paths = AppPaths.resolve(environment)
        let config = try PipelineConfig.load(paths: paths, environment: environment)
        try await SettingsStore(paths: paths, config: config.settingsLock, time: SystemTime()).update { chosen in
            chosen.archivePath = archive.path
            chosen.incomingPath = home.appendingPathComponent("Incoming").path
            if let profile { chosen.profile = profile }
            if let model { chosen = try chosen.reading(withChatModel: model) }
        }
        // A copy goes into a Trash of the throw-away home, never the user's.
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: Arrumator.version, environment: environment,
                                                           echoLogsToStderr: options.verbose,
                                                           resolver: SystemHostResolver(),
                                                           trash: FolderTrash(folder: home.appendingPathComponent("Trash", isDirectory: true)))
        // Stopped with the command, as every runtime a command opens (`Arrumator.main`).
        OpenedArchives.current?.add(runtime)
        try await runtime.openArchive()
        let settings = await runtime.settings.current
        print("Evaluating \(corpus.fixtures.count) fixtures × \(passes) pass(es) in \(home.path)")
        guard await runtime.lifecycle.ensureRunning().isReady else { throw ValidationError("Ollama is not running") }
        var rows: [Evaluation.Row] = []
        var summaries: [Evaluation.Summary] = []
        for pass in 1...passes {
            var passRows: [Evaluation.Row] = []
            for fixture in corpus.fixtures {
                try Task.checkCancellation()
                let source = dir.appendingPathComponent(fixture.file)
                let target = settings.incomingURL.appendingPathComponent(Evaluation.droppedName(fixture.file, pass: pass))
                try FileManager.default.createDirectory(at: settings.incomingURL, withIntermediateDirectories: true)
                var data = try Data(contentsOf: source)
                // Later passes need different bytes, otherwise they are (correctly) taken for copies of the first's.
                if pass > 1 { data.append(contentsOf: [UInt8](repeating: 0x0A, count: pass - 1)) }
                try data.write(to: target)
                let started = Date()
                // Read once Ollama is back, should it be away a while, rather than scored unread (`ollamaRetryAt`).
                if let job = await runtime.coordinator.enqueue(target) {
                    await runtime.coordinator.drain(waitingOutOllamaFor: job)
                } else {
                    await runtime.coordinator.drain()
                }
                try Task.checkCancellation()
                let seconds = Date().timeIntervalSince(started)
                let row = fixture.expected.status == .duplicate
                    ? try await scoreCopy(fixture: fixture, pass: pass, dropped: target, seconds: seconds, runtime: runtime)
                    : try await score(fixture: fixture, pass: pass, dropped: target, seconds: seconds, runtime: runtime)
                passRows.append(row)
                print(String(format: "%@ %-44@ %-11@ %5.1fs %@", "p\(pass)", fixture.file, row.status, row.seconds, row.fileName))
            }
            let summary = Evaluation.summarize(pass: pass, rows: passRows, corpus: corpus.fixtures)
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
            struct Report: Encodable { var rows: [Evaluation.Row]; var summaries: [Evaluation.Summary] }
            try JSON.prettyEncoder.encode(Report(rows: rows, summaries: summaries)).write(to: URL(fileURLWithPath: report.expandingTilde))
        }
        if let minAccuracy, let first = summaries.first, first.details < minAccuracy { throw ExitCode(1) }
    }

    /// A byte-identical copy becomes no document of its own: it goes to the Trash, and the document it copies is read again
    /// in its place, as History records under that document. One taken for no copy, as when `--only` left its original
    /// out, is scored as a document.
    private func scoreCopy(fixture: Evaluation.Fixture, pass: Int, dropped: URL, seconds: Double, runtime: ArrumatorRuntime) async throws
        -> Evaluation.Row {
        let event = try await runtime.services.history.events(limit: 1, kinds: [.duplicate]).first
        guard let event, JSON.decode(CopyPayload.self, from: event.payloadJson)?.isCopy(at: dropped) == true,
              let docID = event.docId, let original = try await runtime.services.documents.document(id: docID) else {
            return try await score(fixture: fixture, pass: pass, dropped: dropped, seconds: seconds, runtime: runtime)
        }
        return Evaluation.copy(fixture, pass: pass, original: original, seconds: seconds)
    }

    /// Scores the document the run filed last, which the fixture dropped as `dropped` became.
    private func score(fixture: Evaluation.Fixture, pass: Int, dropped: URL, seconds: Double, runtime: ArrumatorRuntime) async throws
        -> Evaluation.Row {
        let newest = try await runtime.services.documents.list(DocumentFilter(), limit: 1).first
        return Evaluation.score(fixture, pass: pass, document: newest, dropped: dropped, seconds: seconds)
    }
}
