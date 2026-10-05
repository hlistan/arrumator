@testable import ArrumatorCore
import Foundation
import Testing

extension CommandLineTests {
    @Test func everyDocumentOfTheArchiveIsQueuedToBeReadAgainFromTheCommandLineOnce() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let ids = try file(home, [("bill.txt", [DocumentLabel(kind: .type, value: "invoice")]), ("letter.txt", [])])
        for arguments in [["review", "retry"], ["review", "retry", "1", "--all"]] {
            let refused = try run(home, arguments)
            #expect(refused.status == Self.usageError && refused.stderr.contains("--all"),
                    "\(arguments.joined(separator: " ")): one document or --all is named, never neither nor both: \(refused.stderr)")
        }

        // No model answers here: the command stops at the first document that waits for Ollama, and the rest stay queued
        // for the app, or `run`, to read.
        let queued = try run(home, ["review", "retry", "--all"])
        #expect(queued.status == 0 && queued.text.contains("#\(ids[0]) filed") && queued.text.contains("#\(ids[1]) filed")
                    && queued.text.contains("2 documents queued to be read again") && queued.text.contains("2 still to be read"),
                "every document of the archive is queued, as it is until it is read, and none is read without Ollama: \(queued.text) \(queued.stderr)")
        // A command that files a file takes none of them.
        let incoming = home.root.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("A new arrival".utf8).write(to: incoming.appendingPathComponent("new.txt"))
        _ = try run(home, ["ingest", incoming.appendingPathComponent("new.txt").path])
        let read = try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json", "--limit", "100"]).stdout)
            .filter { $0.kind == .extracted && $0.docId == ids[1] }
        #expect(read.isEmpty, "ingest left the archive's documents waiting to be read again to the app: \(read.map(\.summary))")
        let again = try run(home, ["review", "retry", "--all", "--queue-only", "--json"])
        let left = try JSON.decoder.decode([DocumentRecord].self, from: again.stdout)
        #expect(again.status == 0 && left.isEmpty,
                "asked again, none is left to queue, as an empty JSON list: \(again.text)")
        let events = try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json"]).stdout).filter { $0.kind == .retry && $0.docId == nil }
        #expect(events.count == 1 && events.first?.actor == .user
                    && events.first?.summary == "Read every document again with the profile “Standard”: 2 documents",
                "History records it once, in words: \(events.map(\.summary))")
    }
}
