@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// History lists each event with its document's name as the index has it now (the QA run of 15 October 2026, C10-1): the
/// summary stays as it was recorded, so the name is joined at read time, from the index, never from the payload.
@Suite struct HistoryListingTests {
    @Test func anEventAboutADocumentListsItsNameAsItIsNow() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        try await h.review.edit(id, fileName: "Renamed", labels: nil)
        let filed = try #require(try await h.services.history.listed(limit: 20, kinds: [.filed], docID: id).first)
        #expect(filed.document == "Renamed.txt", "the event recorded under the first name lists the name the document has now: \(String(describing: filed.document))")
        #expect(filed.event.summary.contains("→"), "while its summary stays as it was recorded: \(filed.event.summary)")
    }

    @Test func aRemovedDocumentsEventsListNoName() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        try await h.review.remove(id)
        let events = try await h.services.history.listed(limit: 50, kinds: [.filed, .documentRemoved])
        #expect(events.count == 2 && events.allSatisfy { $0.document == nil },
                "the events of a document removed list no name, and no number: \(events.map { ($0.event.kind, $0.document) })")
    }

    @Test func anEventAboutNoDocumentListsNone() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        try await h.services.history.record(.settingsChanged, actor: .user, summary: "Filing paused")
        let event = try #require(try await h.services.history.listed(limit: 5, kinds: [.settingsChanged]).first)
        #expect(event.document == nil, "an event about no document has no name")
    }

    @Test func aPayloadNamingAnotherDocumentIsNotRead() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        _ = try await h.ingest("other.txt", text: "Another document")
        try await h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE events SET payload_json = ? WHERE doc_id = ?",
                           arguments: [#"{"document": 2, "path": "/elsewhere/other.txt", "from": "/elsewhere/other.txt"}"#, id])
        }
        let listed = try await h.services.history.listed(limit: 20, docID: id)
        let name = try #require(try await h.services.documents.document(id: id)?.filename)
        #expect(!listed.isEmpty && listed.allSatisfy { $0.document == name },
                "the name is the one of the event's own document, whatever a hand-edited payload says: \(listed.map(\.document))")
    }

    @Test func theListingEncodesTheEventsKeysAndTheDocument() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: IngestTests.bill).id)
        let listed = try await h.services.history.listed(limit: 20, docID: id)
        let data = try JSON.encoder.encode(listed)
        #expect(try JSON.decoder.decode([EventRecord].self, from: data) == listed.map(\.event), "what decodes the events still does")
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.allSatisfy { $0["document"] is String }, "and each carries its document's name")
    }
}
