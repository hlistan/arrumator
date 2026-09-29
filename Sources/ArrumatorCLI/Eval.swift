import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

/// Runs a fixture corpus through the full live pipeline in a throw-away home and archive, then scores it.
/// Folders are created dynamically, so placement is scored as grouping consistency: documents with the same
/// expected category should share a folder, and different categories should not.
struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Evaluate the live pipeline on a fixture corpus (expected.json).")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Fixture directory containing expected.json.") var fixtures: String
    @Option(help: "Chat model to use instead of the profile's.") var model: String?
    @Option(help: "Model profile from pipeline.json.") var profile: String?
    @Option(help: "Passes over the corpus; later passes show how much was learned.") var passes = 1
    @Option(help: "A file with the logic to file by, instead of the built-in logic.") var logic: String?
    @Option(help: "Only the fixtures whose path starts with this, such as \"pt/\", for a quick look.") var only: String?
    @Option(help: "Write the full report as JSON to this path.") var report: String?
    @Option(help: "Fail when grouping F1 is below this value.") var minF1: Double?
    @Flag(help: "Simulate a user who confirms consistent placements and moves inconsistent ones (exercises learning).")
    var feedback = false

    struct Expected: Decodable {
        var category: String?
        var yearFolder: String?
        var docType: String?
        var correspondent: String?
        var date: String?
        enum CodingKeys: String, CodingKey {
            case category, yearFolder = "year_folder", docType = "doc_type", correspondent, date
        }
    }

    struct Fixture: Decodable {
        var file: String
        var lang: String
        var core: Bool?
        var expected: Expected
        var acceptAlso: [String: [String]]?
        enum CodingKeys: String, CodingKey { case file, lang, core, expected, acceptAlso = "accept_also" }
    }

    struct Corpus: Decodable { var fixtures: [Fixture] }

    struct Row: Encodable {
        var pass: Int
        var file: String
        var expectedCategory: String?
        var status: String
        var folder: String?
        var fileName: String
        var decidedBy: String?
        var band: String?
        var docTypeOK: Bool?
        var dateOK: Bool?
        var correspondentOK: Bool?
        var yearFolderOK: Bool?
        var seconds: Double
        /// Levels from the top of the archive to the folder it was filed in.
        var depth: Int?
        /// Who the corpus says the document is from, and whether the folder it was filed in stands for a sender.
        var expectedCorrespondent: String?
        var inSenderFolder: Bool = false
        var feedback: String?
    }

    struct Summary: Encodable {
        var pass: Int
        var groupingPrecision: Double
        var groupingRecall: Double
        var groupingF1: Double
        var systemRoutingAccuracy: Double?
        var docTypeAccuracy: Double
        var dateAccuracy: Double
        var correspondentAccuracy: Double
        var yearFolderAccuracy: Double?
        var modelFree: Int
        var medianSeconds: Double
        /// Folders of the user's that hold documents.
        var folders: Int
        /// Mean levels from the top of the archive to the folders documents were filed in.
        var meanDepth: Double?
        /// Sender folders holding documents the corpus says come from different senders: misfilings by identity.
        var senderMixups: Int
        /// Ordinary documents held for review rather than filed: what keeping misfilings down costs.
        var heldForReview: Int
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
        if let logic { try await runtime.logic.update(body: try String(contentsOf: URL(fileURLWithPath: logic.expandingTilde), encoding: .utf8)) }
        let settings = await runtime.settings.current
        guard await runtime.lifecycle.ensureRunning().isReady else { throw ValidationError("Ollama is not running") }
        print("Evaluating \(corpus.fixtures.count) fixtures × \(passes) pass(es) in \(home.path)")
        var rows: [Row] = []
        var summaries: [Summary] = []
        var homes: [String: Int64] = [:]
        for pass in 1...passes {
            var passRows: [Row] = []
            for fixture in corpus.fixtures {
                let source = dir.appendingPathComponent(fixture.file)
                let name = pass == 1 ? source.lastPathComponent
                    : "\((source.lastPathComponent as NSString).deletingPathExtension) pass\(pass).\(source.pathExtension)"
                let target = settings.incomingURL.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: settings.incomingURL, withIntermediateDirectories: true)
                var data = try Data(contentsOf: source)
                // Later passes need different bytes, otherwise they are (correctly) treated as duplicates.
                if pass > 1 { data.append(contentsOf: [UInt8](repeating: 0x0A, count: pass - 1)) }
                try data.write(to: target)
                let started = Date()
                await runtime.coordinator.enqueue(target)
                await runtime.coordinator.drain()
                let seconds = Date().timeIntervalSince(started)
                var row = try await score(fixture: fixture, pass: pass, filedFrom: target, seconds: seconds, runtime: runtime)
                if feedback, let note = try await simulateUser(fixture: fixture, filedFrom: target, homes: &homes, runtime: runtime) {
                    row.feedback = note
                }
                passRows.append(row)
                print(String(format: "%@ %-44@ %-24@ %-6@ %-8@ %5.1fs %@", "p\(pass)", fixture.file, row.folder ?? row.status,
                             row.band ?? "", row.decidedBy ?? "", seconds, row.feedback ?? ""))
            }
            let summary = await summarize(pass: pass, rows: passRows, runtime: runtime, settings: settings)
            summaries.append(summary)
            rows += passRows
            print(String(format: "pass %d: grouping F1 %.2f (P %.2f R %.2f) · type %.0f%% · date %.0f%% · correspondent %.0f%% · "
                                 + "model-free %d · median %.1fs · %d folders · depth %.1f · sender mix-ups %d · held %d",
                         pass, summary.groupingF1, summary.groupingPrecision, summary.groupingRecall, summary.docTypeAccuracy * 100,
                         summary.dateAccuracy * 100, summary.correspondentAccuracy * 100, summary.modelFree, summary.medianSeconds,
                         summary.folders, summary.meanDepth ?? 0, summary.senderMixups, summary.heldForReview))
        }
        let tree = try await runtime.taxonomy.snapshot(root: settings.archiveURL)
        print("\nFolder tree created:")
        for (folder, depth) in tree.outline(include: \.holdsUserDocuments) {
            print(String(repeating: "  ", count: depth) + "\(folder.name) (\(folder.documentCount))")
        }
        if let report {
            struct Report: Encodable { var rows: [Row]; var summaries: [Summary]; var tree: TaxonomySnapshot }
            try JSON.prettyEncoder.encode(Report(rows: rows, summaries: summaries, tree: tree))
                .write(to: URL(fileURLWithPath: report.expandingTilde))
        }
        await runtime.stop()
        if let minF1, let first = summaries.first, first.groupingF1 < minF1 { throw ExitCode(1) }
    }

    private func score(fixture: Fixture, pass: Int, filedFrom: URL, seconds: Double, runtime: ArrumatorRuntime) async throws -> Row {
        let docs = try await runtime.services.documents.list(DocumentFilter(), limit: 1)
        guard let doc = docs.first, doc.originalFilename == filedFrom.lastPathComponent else {
            return Row(pass: pass, file: fixture.file, expectedCategory: fixture.expected.category, status: "missing", folder: nil,
                       fileName: "", seconds: seconds)
        }
        let snapshot = try await runtime.taxonomy.snapshot(root: await runtime.settings.current.archiveURL)
        let folder = doc.folderId.flatMap { snapshot.folder(id: $0) }
        let d = doc.decision
        let e = fixture.expected
        func same(_ a: String?, _ b: String?) -> Bool? {
            guard let b else { return nil }
            return a.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .contains(b.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) } ?? false
        }
        let yearOK: Bool? = e.yearFolder.map { doc.path.contains("/\($0)/") }
        return Row(pass: pass, file: fixture.file, expectedCategory: e.category, status: doc.status.rawValue,
                   folder: folder.map { snapshot.path(of: $0) }, fileName: doc.filename, decidedBy: d?.decidedBy.rawValue,
                   band: d?.band.rawValue, docTypeOK: e.docType.map { $0 == doc.docType }, dateOK: e.date.map { $0 == doc.docDate },
                   correspondentOK: same(doc.correspondent, e.correspondent), yearFolderOK: yearOK, seconds: seconds,
                   depth: folder.flatMap { $0.holdsUserDocuments ? snapshot.depth(of: $0) : nil },
                   expectedCorrespondent: e.correspondent, inSenderFolder: folder?.kind == .sender)
    }

    /// The simulated user keeps one folder per expected category: the first folder a document of that category was
    /// accepted into. Placements there are confirmed; placements elsewhere are moved there (a correction); a first
    /// placement into a folder that already holds another category is left as is (the user has no better home).
    private func simulateUser(fixture: Fixture, filedFrom: URL, homes: inout [String: Int64],
                              runtime: ArrumatorRuntime) async throws -> String? {
        guard let category = fixture.expected.category, Self.systemCategories[category] == nil,
              let doc = try await runtime.services.documents.list(DocumentFilter(), limit: 1).first,
              doc.originalFilename == filedFrom.lastPathComponent, let docID = doc.id else { return nil }
        if let home = homes[category] {
            if doc.folderId == home {
                try await runtime.review.markCorrect(docID)
                return "confirmed"
            }
            try await runtime.review.move(docID, toFolder: home)
            return "moved by user"
        }
        if doc.status == .needsReview, doc.decision?.folderCode != nil || doc.decision?.proposedNewFolder != nil {
            try await runtime.review.approve(docID)
        }
        guard let filed = try await runtime.services.documents.document(id: docID), let folder = filed.folderId,
              filed.status == .filed else { return nil }
        if homes.values.contains(folder) { return "shares a folder" }
        homes[category] = folder
        try await runtime.review.markCorrect(docID)
        return "accepted"
    }

    /// System categories in the corpus (review, duplicates) are scored as routing, not grouping.
    /// Labels the corpus gives files the app must hold back, and the status that holds them.
    static let systemCategories: [String: DocumentStatus] = ["needs-review": .needsReview, "duplicates": .duplicate]

    private func summarize(pass: Int, rows: [Row], runtime: ArrumatorRuntime, settings: AppSettings) async -> Summary {
        let content = rows.filter { $0.expectedCategory.map { Self.systemCategories[$0] == nil } ?? false }
        var tp = 0, fp = 0, fn = 0
        for i in content.indices {
            for j in content.indices where j > i {
                let sameExpected = content[i].expectedCategory == content[j].expectedCategory
                let sameActual = content[i].folder != nil && content[i].folder == content[j].folder
                if sameExpected && sameActual { tp += 1 } else if sameActual { fp += 1 } else if sameExpected { fn += 1 }
            }
        }
        let precision = tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp)
        let recall = tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn)
        let system = rows.filter { $0.expectedCategory.map { Self.systemCategories[$0] != nil } ?? false }
        let routed = system.filter { r in r.expectedCategory.flatMap { Self.systemCategories[$0]?.rawValue } == r.status }
        func rate(_ values: [Bool?]) -> Double {
            let known = values.compactMap { $0 }
            return known.isEmpty ? 0 : Double(known.filter { $0 }.count) / Double(known.count)
        }
        let years = content.compactMap(\.yearFolderOK)
        let seconds = rows.map(\.seconds).sorted()
        let depths = rows.compactMap(\.depth)
        let bySenderFolder = Dictionary(grouping: rows.filter(\.inSenderFolder), by: { $0.folder ?? "" })
        let mixups = bySenderFolder.values.filter { Set($0.compactMap(\.expectedCorrespondent)).count > 1 }.count
        let held = content.filter { $0.status == DocumentStatus.needsReview.rawValue }.count
        // Folders documents were filed into, at whatever depth: the folders above them only group them.
        let folders = (try? await runtime.taxonomy.snapshot(root: settings.archiveURL).folders
            .filter { $0.holdsUserDocuments && $0.documentCount > 0 }.count) ?? 0
        return Summary(pass: pass, groupingPrecision: precision, groupingRecall: recall,
                       groupingF1: precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall),
                       systemRoutingAccuracy: system.isEmpty ? nil : Double(routed.count) / Double(system.count),
                       docTypeAccuracy: rate(content.map(\.docTypeOK)), dateAccuracy: rate(content.map(\.dateOK)),
                       correspondentAccuracy: rate(content.map(\.correspondentOK)),
                       yearFolderAccuracy: years.isEmpty ? nil : rate(years), modelFree: rows.filter { $0.decidedBy == "rule" || $0.decidedBy == "knnOnly" }.count,
                       medianSeconds: seconds.isEmpty ? 0 : seconds[seconds.count / 2], folders: folders,
                       meanDepth: depths.isEmpty ? nil : Double(depths.reduce(0, +)) / Double(depths.count),
                       senderMixups: mixups, heldForReview: held)
    }
}
