@testable import ArrumatorCore
import Foundation
import Testing

/// What the search command says of what it found and why it did not compare by meaning.
extension CommandLineTests {
    /// A file taken in as the command line does, and so found by its name: no model answers here.
    private func takenIn(_ home: Home, _ name: String) throws -> Int64 {
        let scan = home.root.appendingPathComponent("Incoming/\(name)")
        try FileManager.default.createDirectory(at: scan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("A document".utf8).write(to: scan)
        let ingested = try run(home, ["ingest", "--json", scan.path])
        return try #require(try JSON.decoder.decode([DocumentRecord].self, from: ingested.stdout).first?.id, "\(ingested.text) \(ingested.stderr)")
    }

    @Test func aSearchSaysWhyItDidNotCompareByMeaning() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let id = try takenIn(home, "electricity.txt")
        let words = try run(home, ["search", "--no-semantic", "electricity"])
        let last = try #require(words.text.split(separator: "\n").last, "a line is printed: \(words.text) \(words.stderr)")
        #expect(last.hasPrefix("1 results in ") && last.hasSuffix("(full text: disabled)"), "the count is followed by why: \(words.text)")
        #expect(try documentIDs(try run(home, ["search", "--json", "--no-semantic", "electricity"]).stdout) == [id], "and the JSON is unchanged")
    }

    @Test func aMatchOutsideTheTextPrintsNoBlankSnippetLine() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let id = try takenIn(home, "electricity.txt")
        let text = try run(home, ["search", "--no-semantic", "electricity"])
        let lines = text.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let path = try #require(lines.firstIndex { $0.hasSuffix("electricity.txt") }, "the document is listed: \(text.text) \(text.stderr)")
        let count = try #require(lines.firstIndex { $0.hasPrefix("1 results in ") }, "and counted: \(text.text)")
        let between = lines[(path + 1)..<count]
        #expect(between.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "no line between the path and the count is blank: \(between) for \(id)")
        #expect(try documentIDs(try run(home, ["search", "--json", "--no-semantic", "electricity"]).stdout) == [id], "and the JSON is unchanged")
    }

    @Test func aQueryWithNothingToLookForListsNothing() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        _ = try takenIn(home, "electricity.txt")
        let json = try run(home, ["search", "--json", "--no-semantic", "%%%"])
        #expect(try documentIDs(json.stdout) == [], "no document is listed, not the latest ones: \(json.text)")
        let text = try run(home, ["search", "--no-semantic", "%%%"])
        let last = try #require(text.text.split(separator: "\n").last, "a line is printed: \(text.text) \(text.stderr)")
        #expect(last.hasPrefix("0 results in ") && last.hasSuffix("(full text: nothing to look for)"), "and the text says why: \(text.text)")
    }
}
