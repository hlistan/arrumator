@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What `arrumatorcli show` says of a document: what the model read it as and its text as it was recognised, as its
/// sidecar holds them.
extension CommandLineTests {
    @Test func whatADocumentIsAndItsTextAsRecognisedAreShownFromTheCommandLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let said = "Fatura de eletricidade da EDP Comercial, referente a junho de 2026."
        let filed = try #require(try file(home, [("bill.txt", [DocumentLabel(kind: .sender, value: "EDP Comercial")])],
                                          analyses: ["bill.txt": DocumentAnalysis(interpretation: said, model: "m")]).first)
        let bill = try run(home, ["show", String(filed), "--json"])
        let read = try JSON.decoder.decode(DocumentText.self, from: bill.stdout)
        #expect(read.id == filed && read.file == "bill.txt" && read.interpretation == said && read.text.isEmpty && read.sidecar == nil,
                "what the model read it as comes back from its record; its text, and so its sidecar, once it is read again: \(bill.text) \(bill.stderr)")

        // No model answers here: the file's text is read, and it waits to be read by the model.
        let scan = home.root.appendingPathComponent("Incoming/scan.txt")
        try FileManager.default.createDirectory(at: scan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Tax assessment for 2024\tTotal 120 EUR".utf8).write(to: scan)
        let ingested = try run(home, ["ingest", "--json", scan.path])
        let id = try #require(try JSON.decoder.decode([DocumentRecord].self, from: ingested.stdout).first?.id, "\(ingested.text) \(ingested.stderr)")
        let shown = try JSON.decoder.decode(DocumentText.self, from: try run(home, ["show", scan.path, "--json"]).stdout)
        #expect(shown.id == id && shown.text == "Tax assessment for 2024\tTotal 120 EUR" && shown.interpretation == nil
                    && shown.textOrigin == .textLayer && !shown.truncated,
                "a document found by its path shows its text as it was read, and that the model has not said what it is: \(shown)")
        let text = try run(home, ["show", String(id)]).text
        #expect(text.contains("What it is\n—") && text.contains("Recognised text (read from textLayer)\nTax assessment for 2024"),
                "and so does the text: \(text)")
        // With a model that answers, the document is filed: its text is read, and the command writes its sidecar as it ends.
        let ollama = try LoopbackOllama()
        defer { ollama.stop() }
        let answered = try Home.make(ollamaURL: ollama.address, pipeline: LoopbackOllama.patient)
        defer { answered.cleanup() }
        let note = answered.root.appendingPathComponent("note.txt")
        try Data("A note to keep\twith its tab".utf8).write(to: note)
        let noted = try run(answered, ["ingest", "--json", note.path])
        let notedID = try #require(try JSON.decoder.decode([DocumentRecord].self, from: noted.stdout).first?.id, "\(noted.text) \(noted.stderr)")
        let beside = try JSON.decoder.decode(DocumentText.self, from: try run(answered, ["show", String(notedID), "--json"]).stdout)
        let sidecar = try #require(beside.sidecar, "a document filed into the archive by a command has its sidecar when the command ends: \(beside)")
        #expect(try String(contentsOf: URL(fileURLWithPath: sidecar), encoding: .utf8).contains("```text\nA note to keep\twith its tab\n```"),
                "beside it, with its text as it was read")
        let none = try run(home, ["show", "999"])
        #expect(none.status != 0 && none.stderr.contains("No document 999"), "a document the index does not have is named: \(none.stderr)")
    }
}
