@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What the command line does to the archive's labels as a whole, and to a document removed.
extension CommandLineTests {
    @Test func labelsAreAddedRenamedAndRemovedFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let (sender, tag) = ({ DocumentLabel(kind: .sender, value: $0) }, { DocumentLabel(kind: .tag, value: $0) })
        let ids = try file(home, [("a.txt", [sender("EDP Comercial"), tag("Home")]), ("b.txt", [sender("EDP Comercial")])])

        let added = try run(home, ["labels", "add", "--json", "tag=Taxes 2025"])
        let outcome = try JSON.decoder.decode(LabelActionOutcome.self, from: added.stdout)
        #expect(outcome.rule?.action == .add && outcome.rule?.value == "Taxes 2025" && outcome.documents.isEmpty,
                "a tag is added with no document: \(added.text) \(added.stderr)")
        let listed = try JSON.decoder.decode([LabelUsage].self, from: try run(home, ["labels", "list", "--json", "--kind", "tag"]).stdout)
        #expect(listed == [LabelUsage(label: tag("Home"), documents: 1), LabelUsage(label: tag("Taxes 2025"), documents: 0)],
                "and listed after the tags in use, with no document: \(listed)")
        let refused = try run(home, ["labels", "add", "sender=EDP"])
        #expect(refused.status != 0 && refused.stderr.contains("Only a tag"), "only a tag is added so: \(refused.stderr)")

        let renamed = try JSON.decoder.decode(LabelActionOutcome.self,
                                              from: try run(home, ["labels", "rename", "--json", "sender=EDP Comercial", "--to", "EDP"]).stdout)
        #expect(renamed.documents == ids && renamed.rule?.target == "EDP", "a rename relabels every document and is a rule: \(renamed)")
        let removed = try run(home, ["labels", "remove", "--json", "tag=home"])
        let taken = try JSON.decoder.decode(LabelActionOutcome.self, from: removed.stdout)
        #expect(taken.documents == [ids[0]] && taken.rule == nil, "a label removed is taken off with no rule: \(removed.text)")
        #expect(try run(home, ["labels", "remove", "tag=Home"]).text.contains("Nothing to change"), "and once more changes nothing")
        let addedRemoved = try run(home, ["labels", "remove", "tag=Taxes 2025"])
        #expect(addedRemoved.text.contains("Removed tag “Taxes 2025”") && !addedRemoved.text.contains("Nothing to change"),
                "a tag added that no document has is removed, saying so: \(addedRemoved.text)")

        let events = try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json"]).stdout)
        #expect(Set(events.map(\.kind)).isSuperset(of: [.labelAdded, .labelsMerged, .labelRemoved]), "each is in History: \(events.map(\.kind))")
    }

    @Test func aDocumentIsRemovedToTheTrashFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let ids = try file(home, [("a.txt", [DocumentLabel(kind: .type, value: "invoice")]), ("b.txt", [])])
        let result = try run(home, ["review", "remove", "--json", String(ids[0])])
        let removed = try JSON.decoder.decode(RemovedPayload.self, from: result.stdout)
        #expect(removed.document == ids[0] && removed.from.hasSuffix("/a.txt"), "the document named is removed: \(result.text) \(result.stderr)")
        let trashed = try #require(removed.trashed.map(URL.init(fileURLWithPath:)), "its file went to the Trash")
        #expect(FileManager.default.fileExists(atPath: trashed.path) && trashed.path.hasPrefix(home.root.appendingPathComponent("Trash").spelledOnDisk.path),
                "the Trash the command was given holds it: \(trashed.path)")
        #expect(!FileManager.default.fileExists(atPath: home.archive.appendingPathComponent("a.txt").path), "the archive no longer does")
        let config = try PipelineConfig.bundledDefaults()
        let listing = try String(contentsOf: home.archive.appendingPathComponent(config.records.documentsFileName), encoding: .utf8)
        #expect(!listing.contains("file: a.txt") && listing.contains("file: b.txt"), "and its record file lists only the other: \(listing)")
        let again = try run(home, ["review", "remove", String(ids[0])])
        #expect(again.status != 0, "a document removed is removed once: \(again.stderr)")
    }

    @Test func evalRefusesARunWhoseModelOllamaDoesNotHaveNamingIt() throws {
        let ollama = try LoopbackOllama()
        defer { ollama.stop() }
        let home = try Home.make(ollamaURL: ollama.address, pipeline: LoopbackOllama.patient)
        defer { home.cleanup() }
        let corpus = home.root.appendingPathComponent("Corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        try Data("A note".utf8).write(to: corpus.appendingPathComponent("note.txt"))
        try Data(#"{"fixtures": [{"file": "note.txt", "lang": "en", "expected": {"status": "filed", "title_contains": []}}], "label_pairs": []}"#.utf8)
            .write(to: corpus.appendingPathComponent("expected.json"))
        let chat = try AppSettings.bundledDefaults().modelProfile().chatModel
        for arguments in [["eval", corpus.path], ["eval", corpus.path, "--pairs"]] {
            let result = try run(home, arguments, environment: ["ARRUMATOR_OLLAMA_URL": ollama.address])
            #expect(result.status != 0 && result.stderr.contains("Ollama does not have \(chat)") && result.stderr.contains("--model"),
                    "\(arguments.last ?? ""): a server without the profile's model is refused, naming it, before anything is scored: \(result.stderr)")
            #expect(!result.text.contains("p1 "), "and nothing is scored unread: \(result.text)")
        }
        try Data(Self.corpusWithAPairOfTypes.utf8).write(to: corpus.appendingPathComponent("expected.json"))
        let badPair = try run(home, ["eval", corpus.path], environment: ["ARRUMATOR_OLLAMA_URL": ollama.address])
        #expect(badPair.status != 0 && badPair.stderr.contains("A pair of labels in") && badPair.stderr.contains("type is no kind the vocabulary keeps")
                    && !badPair.text.contains("Evaluating"), "a pair that could not be in an archive stops the run before anything runs: \(badPair.stderr)")
        let both = try run(home, ["eval", corpus.path, "--pairs", "--only", "pt/"])
        #expect(both.status == Self.usageError && both.stderr.contains("--pairs"), "--pairs reads no document, which --only chooses: \(both.stderr)")
    }

    /// A corpus of one note and one pair of labels of a kind no archive judges, types.
    static let corpusWithAPairOfTypes = """
        {"fixtures": [{"file": "note.txt", "lang": "en", "expected": {"status": "filed", "title_contains": []}}],
         "label_pairs": [{"kind": "type", "value": "invoice", "into": "receipt", "value_documents": 1, "value_names": [],
                          "into_documents": 1, "into_names": [], "same": false, "why": "a test", "held_out": false}]}
        """
}
