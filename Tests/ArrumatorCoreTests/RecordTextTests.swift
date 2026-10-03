@testable import ArrumatorCore
import Foundation
import Testing

/// What the record files show people browsing the archive is in the time zone the runtime gives, not the process's.
@Suite struct RecordTextTests {
    @Test("A history's moments are written in the time zone given, with its offset", arguments: ["Asia/Tokyo", "America/Los_Angeles"])
    func historyInTheZoneGiven(zone: String) throws {
        let timeZone = try #require(TimeZone(identifier: zone))
        let event = try JSON.decoder.decode(EventEntry.self, from: Data("""
            {"id": 1, "at": "2026-07-15T23:30:00Z", "kind": "filed", "actor": "system", "summary": "Fatura", "payload": "{}"}
            """.utf8))
        let text = RecordText.history([event], month: "2026-07", in: timeZone)
        let written = event.at.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day()
            .time(includingFractionalSeconds: false).timeZone(separator: .colon))
        #expect(text.contains("- \(written) · filed · Fatura"), "on a Mac in \(zone), the moment as its clock showed it: \(text)")
        #expect(written.hasPrefix(zone == "Asia/Tokyo" ? "2026-07-16T08:30:00+09:00" : "2026-07-15T16:30:00-07:00"), "\(written)")
    }
}
