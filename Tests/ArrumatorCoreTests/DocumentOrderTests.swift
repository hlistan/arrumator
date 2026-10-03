@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The order documents are looked through in (`DocumentOrder.documentDate`): by their own date, the `date` label of the
/// day they were issued, the newest first and the undated last; one date by name, then by number. The documents the
/// sidebar's labels choose are listed in it, in the app a page at a time and by `labels browse`, and a search task keeps
/// and arranges its set by it (`SearchPlanMatcher`, `DocumentGrouping`). The logs keep the order things happened in.
@Suite struct DocumentOrderTests {
    static func label(_ kind: LabelKind, _ value: String) -> DocumentLabel { DocumentLabel(kind: kind, value: value) }

    static let invoice = label(.type, "invoice")
    static let march = label(.date, "2024-03-01")

    /// Invoices and two other documents, each by its number, where it is below the archive and its labels (nil: not
    /// labelled yet). They were processed in this order, a minute apart, which is not the order of their dates.
    static let corpus: [(id: Int64, path: String, labels: [DocumentLabel]?)] = [
        (1, "a/Report.pdf", [invoice, march]),
        (2, "b/Report.pdf", [invoice, march]),
        (3, "invoice 10.pdf", [invoice, march]),
        (4, "invoice 9.pdf", [invoice, march]),
        (5, "b.pdf", [invoice, label(.date, "2025-01-02")]),
        (6, "c.pdf", [invoice]),
        (7, "a.pdf", [label(.sender, "EDP"), invoice]),
        (8, "z.pdf", [invoice, label(.date, "2023-12-31")]),
        (9, "contract.pdf", [label(.type, "contract"), label(.date, "2026-01-01")]),
        (10, "unread.pdf", nil),
    ]

    /// The invoices by their own date: January 2025; the four of March 2024 by name, “invoice 9” before “invoice 10” and
    /// the two reports by number; December 2023; then the undated by name.
    static let invoicesByDate: [Int64] = [5, 4, 3, 1, 2, 8, 7, 6]

    /// The corpus in an index of its own, each document filed a minute after the one before.
    private func store() async throws -> DocumentStore {
        let store = DocumentStore(database: try AppDatabase.inMemory(), time: TestTime(.advances))
        for (offset, entry) in Self.corpus.enumerated() {
            var document = try SearchTaskTests.document(entry.id, entry.path, entry.labels ?? [])
            document.labelsJson = try entry.labels.map { try JSON.string($0) }
            document.status = .filed
            document.filedAt = TestTime.start.addingTimeInterval(Double(offset) * 60)
            try await store.save(document)
        }
        return store
    }

    private func ids(_ store: DocumentStore, _ filter: DocumentFilter, _ order: DocumentOrder, limit: Int) async throws -> [Int64] {
        try await store.list(filter, order: order, limit: limit).compactMap(\.id)
    }

    @Test func theDocumentsTheLabelsChooseComeByTheirOwnDateNewestFirstTheUndatedLast() async throws {
        let store = try await store()
        let chosen = DocumentFilter(labels: [Self.invoice])
        #expect(try await ids(store, chosen, .documentDate, limit: Self.corpus.count) == Self.invoicesByDate,
                "the newest date first, one date by name as Finder sorts names, one name by number, and the undated last")
        #expect(try await ids(store, chosen, .recentlyProcessed, limit: Self.corpus.count) == [8, 7, 6, 5, 4, 3, 2, 1],
                "while Processed, a log, still lists them by when they were processed, the latest first")
        #expect(try await ids(store, DocumentFilter(), .documentDate, limit: Self.corpus.count) == [9, 5, 4, 3, 1, 2, 8, 7, 6, 10],
                "with no label chosen every document is in the order, those not labelled yet among the undated")
    }

    @Test func aLongerPageStartsAsTheShorterDidSoShowMoreNeitherSkipsNorRepeats() async throws {
        let store = try await store()
        let chosen = DocumentFilter(labels: [Self.invoice])
        // The page loads `pages × interface.pageSize` documents and shows them all; here a page of every size.
        for limit in 1...Self.invoicesByDate.count {
            #expect(try await ids(store, chosen, .documentDate, limit: limit) == Array(Self.invoicesByDate.prefix(limit)),
                    "a page of \(limit) is the first \(limit) of the order: no document is skipped or shown twice when Show More loads more")
        }
    }

    @Test func documentsInMemoryFollowTheSameOrderAsTheIndexGivesThem() async throws {
        let store = try await store()
        let everything = try await store.list(DocumentFilter(), order: .documentDate, limit: Self.corpus.count)
        #expect(DocumentOrder.byDocumentDate(everything.reversed()).compactMap(\.id) == everything.compactMap(\.id),
                "a set arranged in memory, such as a task's, follows the order its SQL gives, however its documents came")
        #expect(everything.first?.documentDate == "2026-01-01" && everything.last?.documentDate == nil,
                "a document's own date is its date label, and one not labelled has none")
    }
}
