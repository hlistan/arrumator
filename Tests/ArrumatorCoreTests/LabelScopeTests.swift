import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// Drilling down by labels: choosing labels narrows the documents to those that have every one, and narrows the labels
/// offered to those the narrowed documents have (`DocumentFilter.labels`, `LabelStore.usage(within:)`), listed as the
/// sidebar lists them: the most used first, in one list or kind by kind, and only those its search finds.
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
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: Self.corpus))
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
        #expect(usage[.sender]?.map(\.documents) == [1, 1], "each sender sent one of the invoices")
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
        #expect(try await documents(h, [Self.invoice], statuses: [.filed]) == ids(all, "edp_bill.txt", "meo_bill.txt"),
                "the invoices are both filed")
        #expect(try await documents(h, [Self.invoice], statuses: [.needsReview]).isEmpty, "both conditions hold at once")
        let search = h.search
        let hits = try await search.fullText(SearchQuery(text: "document", filter: DocumentFilter(labels: [Self.edp]))).hits.map(\.id).sorted()
        #expect(hits == (try ids(all, "edp_bill.txt", "edp_contract.txt")), "search can be kept within the chosen labels")
    }

    @Test func theScopeFollowsTheUsersDecisionsAboutLabels() async throws {
        let (h, all) = try await archive()
        defer { h.env.cleanup() }
        _ = try await h.labels.merge(Self.edp, into: "EDP")
        #expect(try await documents(h, [Self.edp]).isEmpty, "a merged-away label no longer chooses anything")
        #expect(try await documents(h, [Self.label(.sender, "EDP")]) == ids(all, "edp_bill.txt", "edp_contract.txt"),
                "the label it was merged into chooses its documents")
    }

    // MARK: Listing the labels offered, as the sidebar and `labels browse` do

    @Test func inOneListTheLabelsMostDocumentsHaveComeFirstWhateverTheirKind() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        let ranked = try await h.services.labels.usage().ranked()
        #expect(ranked.first == LabelUsage(label: Self.label(.jurisdiction, "Portugal"), documents: 4),
                "the one label every labelled document has leads, though its kind comes last of the four")
        #expect(Array(ranked.dropFirst().prefix(3)) == [LabelUsage(label: Self.edp, documents: 2), LabelUsage(label: Self.invoice, documents: 2),
                                                        LabelUsage(label: Self.label(.topic, "electricity"), documents: 2)],
                "labels two documents have come next, in the order of their kinds: sender, type, topic")
        #expect(zip(ranked, ranked.dropFirst()).allSatisfy { $0.documents >= $1.documents }, "no label comes before one more documents have")
        #expect(ranked.count == 10, "every label is listed once: 3 senders, 3 types, 3 topics and 1 jurisdiction")
    }

    @Test func groupedTheLabelsAreListedKindByKindEachKindsMostUsedFirst() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        let usage = try await h.services.labels.usage()
        let grouped = usage.listed(groupedByKind: true)
        #expect(grouped.map(\.label.kind) == [.sender, .sender, .sender, .type, .type, .type, .topic, .topic, .topic, .jurisdiction],
                "kinds follow one another in their order, each kind's labels together")
        #expect(grouped.first == LabelUsage(label: Self.edp, documents: 2), "within a kind, the most used label first")
        #expect(usage.listed(groupedByKind: false) == usage.ranked(), "not grouped is the one ranked list")
    }

    static let offered: [LabelKind: [LabelUsage]] = [
        .sender: [LabelUsage(label: label(.sender, "EDP-Comercial, S.A."), documents: 3), LabelUsage(label: label(.sender, "Autoridade Tributária"), documents: 1)],
        .type: [LabelUsage(label: label(.type, "tax-assessment"), documents: 1)],
        .language: [LabelUsage(label: label(.language, "pt"), documents: 4)],
    ]

    @Test func searchingListsOnlyTheLabelsWrittenWithTheTextInThem() {
        #expect(Self.offered.matching("edp") == [.sender: [LabelUsage(label: Self.label(.sender, "EDP-Comercial, S.A."), documents: 3)]],
                "the matching label, with its count, and no kind left without one")
        #expect(Self.offered.matching("edp comercial").keys.elementsEqual([.sender]), "punctuation does not matter")
        #expect(Self.offered.matching("TRIBUTARIA")[.sender]?.map(\.label.value) == ["Autoridade Tributária"],
                "nor case or accents")
        #expect(Self.offered.matching("tax assess")[.type]?.count == 1, "a type is found as it is shown, in words")
        #expect(Self.offered.matching("portug")[.language]?.count == 1, "a language is found by its English name, as search finds it")
    }

    @Test func blankSearchListsEveryLabelAndOneNoLabelHasListsNone() {
        #expect(Self.offered.matching("") == Self.offered, "nothing typed lists every label")
        #expect(Self.offered.matching("  \t") == Self.offered, "and so does only white space")
        #expect(Self.offered.matching("--") == Self.offered, "or only punctuation, which matching leaves out")
        #expect(Self.offered.matching("edf").isEmpty, "a text no label is written with lists nothing, so no kind heads an empty group")
    }
}
