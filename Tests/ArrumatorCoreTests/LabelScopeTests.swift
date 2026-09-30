import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// Drilling down by labels: choosing labels narrows the documents to those that have every one, and narrows the labels
/// offered to those the narrowed documents have (`DocumentFilter.labels`, `LabelStore.usage(within:)`).
@Suite struct LabelScopeTests {
    static func label(_ kind: LabelKind, _ value: String) -> DocumentLabel { DocumentLabel(kind: kind, value: value) }

    static let invoice = label(.type, "invoice")
    static let edp = label(.sender, "EDP Comercial")

    /// Four documents that share some labels and not others, and one the model found nothing in.
    static let corpus: [String: [DocumentLabel]] = [
        "edp_bill.txt": [edp, invoice, label(.topic, "electricity"), label(.jurisdiction, "Portugal")],
        "edp_contract.txt": [edp, label(.type, "contract"), label(.topic, "electricity"), label(.jurisdiction, "Portugal")],
        "meo_bill.txt": [label(.sender, "MEO"), invoice, label(.topic, "telecommunications"), label(.jurisdiction, "Portugal")],
        "tax.txt": [label(.sender, "Autoridade Tributária"), label(.type, "tax-assessment"), label(.topic, "taxes"),
                    label(.jurisdiction, "Portugal")],
        "blank.txt": [],
    ]

    private func archive() async throws -> (Harness, [String: Int64]) {
        let h = try await Harness.make(analyzer: LabelingTests.PerFileAnalyzer(labels: Self.corpus))
        var ids: [String: Int64] = [:]
        for name in Self.corpus.keys.sorted() { ids[name] = try await h.ingest(name, text: "A document: \(name)").id }
        return (h, ids)
    }

    private func documents(_ h: Harness, _ selection: [DocumentLabel], statuses: Set<DocumentStatus>? = nil) async throws -> [Int64] {
        try await h.services.documents.list(DocumentFilter(statuses: statuses, labels: selection), limit: 50).compactMap(\.id).sorted()
    }

    private func ids(_ all: [String: Int64], _ names: String...) throws -> [Int64] {
        try names.map { try #require(all[$0]) }.sorted()
    }

    private func values(_ usage: [LabelKind: [LabelUsage]], _ kind: LabelKind) -> [String] {
        (usage[kind] ?? []).map(\.label.value)
    }

    @Test func withNothingChosenEveryDocumentAndEveryLabelIsOffered() async throws {
        let (h, all) = try await archive()
        defer { h.env.cleanup() }
        #expect(try await documents(h, []) == all.values.sorted(), "an empty selection is no filter")
        #expect(try await h.services.labels.usage(within: []) == h.services.labels.usage(), "and offers the whole vocabulary")
    }

    @Test func choosingALabelShowsOnlyTheDocumentsThatHaveIt() async throws {
        let (h, all) = try await archive()
        defer { h.env.cleanup() }
        #expect(try await documents(h, [Self.invoice]) == ids(all, "edp_bill.txt", "meo_bill.txt"),
                "the two invoices, not the contract, the tax assessment or the document without labels")
    }

    @Test func theLabelsLeftAreOnlyThoseTheChosenDocumentsHave() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        let usage = try await h.services.labels.usage(within: [Self.invoice])
        #expect(values(usage, .sender) == ["EDP Comercial", "MEO"], "not the tax authority, who sent no invoice")
        #expect(values(usage, .topic) == ["electricity", "telecommunications"], "not taxes")
        #expect(values(usage, .type) == ["invoice"], "the chosen label stays, as every document left has it; contract goes")
        #expect(usage[.jurisdiction]?.first?.documents == 2, "a label is counted over the chosen documents only, not all four")
        #expect(usage[.sender]?.map(\.documents) == [1, 1])
    }

    @Test func eachFurtherLabelNarrowsTheDocumentsAndTheLabelsAgain() async throws {
        let (h, all) = try await archive()
        defer { h.env.cleanup() }
        let selection = [Self.invoice, Self.edp]
        #expect(try await documents(h, selection) == ids(all, "edp_bill.txt"), "documents must have every chosen label, not any")
        let usage = try await h.services.labels.usage(within: selection)
        #expect(values(usage, .sender) == ["EDP Comercial"] && values(usage, .topic) == ["electricity"],
                "only what the one document left has")
        #expect(Set(usage.keys) == [.sender, .type, .topic, .jurisdiction], "kinds none of them has are gone")
    }

    @Test func aChosenLabelIsMatchedHoweverItIsWritten() async throws {
        let (h, all) = try await archive()
        defer { h.env.cleanup() }
        let written = [Self.label(.sender, "edp-comercial")]
        #expect(try await documents(h, written) == ids(all, "edp_bill.txt", "edp_contract.txt"),
                "as the user types it in a terminal: case and punctuation do not matter")
        #expect(values(try await h.services.labels.usage(within: written), .sender) == ["EDP Comercial"],
                "and the labels left are written as the archive writes them")
    }

    @Test func aLabelNoDocumentHasLeavesNothingToShow() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        for selection in [[Self.label(.sender, "EDF")], [Self.invoice, Self.label(.sender, "EDF")], [Self.label(.party, "EDP Comercial")]] {
            #expect(try await documents(h, selection).isEmpty, "\(selection): unknown, or of another kind, matches nothing")
            #expect(try await h.services.labels.usage(within: selection).isEmpty, "\(selection): and leaves no labels to offer")
        }
    }

    @Test func labelsNarrowTogetherWithStatusesAndSearch() async throws {
        let (h, all) = try await archive()
        defer { h.env.cleanup() }
        #expect(try await documents(h, [Self.invoice], statuses: [.filed]) == ids(all, "edp_bill.txt", "meo_bill.txt"))
        #expect(try await documents(h, [Self.invoice], statuses: [.needsReview]).isEmpty, "both conditions hold at once")
        let search = SearchService(database: h.env.database, vectors: VectorIndex(), embedder: nil, config: h.env.config.search)
        let hits = try await search.fullText(SearchQuery(text: "document", filter: DocumentFilter(labels: [Self.edp]))).hits.map(\.id).sorted()
        #expect(hits == (try ids(all, "edp_bill.txt", "edp_contract.txt")), "search can be kept within the chosen labels")
    }

    @Test func theScopeFollowsTheUsersDecisionsAboutLabels() async throws {
        let (h, all) = try await archive()
        defer { h.env.cleanup() }
        _ = try await LabelActions(database: h.env.database).merge(Self.edp, into: "EDP")
        #expect(try await documents(h, [Self.edp]).isEmpty, "a merged-away label no longer chooses anything")
        #expect(try await documents(h, [Self.label(.sender, "EDP")]) == ids(all, "edp_bill.txt", "edp_contract.txt"),
                "the label it was merged into chooses its documents")
    }
}
