@testable import ArrumatorCore
import Foundation
import Testing

extension CommandLineTests {
    @Test func historyNamesTheDocumentOfEachEvent() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let ids = try file(home, [("bill.txt", [])])
        #expect(try run(home, ["review", "hold", "\(ids[0])"]).status == 0, "the document is left for later, an event about it")
        let objects = try JSON.decoder.decode([[String: JSONValue]].self, from: try run(home, ["history", "--json"]).stdout)
        let held = try #require(objects.first { $0["kind"]?.stringValue == EventKind.needsReview.rawValue })
        #expect(held["document"]?.stringValue == "bill.txt", "--json gives the document's name beside the event's own keys: \(held)")
        let table = try run(home, ["history"]).text
        #expect(table.contains("#\(ids[0]) bill.txt"), "and the table shows it beside the number: \(table)")
        #expect(try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json"]).stdout).isEmpty == false,
                "an `[EventRecord]` still decodes from it")
    }
}
