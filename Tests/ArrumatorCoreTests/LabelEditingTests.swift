@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// The user edits the archive's labels as a whole: renames one everywhere, takes one off every document, and adds a tag
/// of their own that no document has yet.
@Suite struct LabelEditingTests {
    static func label(_ kind: LabelKind, _ value: String) -> DocumentLabel { DocumentLabel(kind: kind, value: value) }

    private func events(_ h: Harness, _ kinds: Set<EventKind>) async throws -> [EventRecord] {
        try await h.services.history.events(limit: 50, kinds: kinds)
    }

    /// Another EDP bill, read after the change by the stub that labels every document as one.
    static func readLater(_ h: Harness) async throws -> DocumentRecord {
        var services = h.services
        services.analyzer = StubAnalyzer()
        return try await Harness(env: h.env, services: services).ingest("edp_september.txt", text: "EDP electricity September")
    }

    // MARK: Renaming

    @Test func aRenameWritesTheLabelAnewOnEveryDocumentAndInEveryReading() async throws {
        let (h, ids) = try await LabelVocabularyTests.archive()
        defer { h.env.cleanup() }
        let edp = try [#require(ids["edp_july.txt"]), #require(ids["edp_august.txt"])].sorted()
        let outcome = try await h.labels.rename(Self.label(.sender, "EDP Comercial"), to: "EDP Comercial SA")
        #expect(outcome.documents == edp && outcome.rule?.summary == "sender “EDP Comercial” → “EDP Comercial SA”",
                "both documents are relabelled, and the new writing is a rule readings follow")
        for id in edp {
            #expect(try await h.services.documents.document(id: id)?.labels?.values(.sender) == ["EDP Comercial SA"], "renamed on \(id)")
        }
        #expect(try await events(h, [.labelsMerged]).map(\.summary) == ["Renamed sender “EDP Comercial” to “EDP Comercial SA” on 2 documents"],
                "History says it was renamed, by the user")
        let later = try await Self.readLater(h)
        #expect(later.labels?.values(.sender) == ["EDP Comercial SA"], "a document read later is given the new writing")
    }

    @Test func aRenameMayChangeOnlyTheCase() async throws {
        let (h, _) = try await LabelVocabularyTests.archive()
        defer { h.env.cleanup() }
        let outcome = try await h.labels.rename(Self.label(.sender, "EDP Comercial"), to: "EDP COMERCIAL")
        #expect(outcome.documents.count == 2 && outcome.rule?.target == "EDP COMERCIAL", "a name written in capitals is a new writing")
        let later = try await Self.readLater(h)
        #expect(later.labels?.values(.sender) == ["EDP COMERCIAL"], "and readings follow it without looping")
    }

    @Test func aRenameIsRefusedAsAMergeIs() async throws {
        let (h, _) = try await LabelVocabularyTests.archive()
        defer { h.env.cleanup() }
        await #expect(throws: LabelError.sameLabel(.sender, "EDP Comercial"), "the same writing is no new name") {
            try await h.labels.rename(Self.label(.sender, "EDP Comercial"), to: " EDP  Comercial ")
        }
        await #expect(throws: LabelError.notALabel(.date, "soon"), "a new name is a label of the kind") {
            try await h.labels.rename(Self.label(.date, "2026-07-05"), to: "soon")
        }
        let (rules, merged) = (try await h.services.labels.rules(), try await events(h, [.labelsMerged]))
        #expect(rules.isEmpty && merged.isEmpty, "nothing refused is made or recorded")
    }

    // MARK: Taking a label off every document

    @Test func removingALabelTakesItOffEveryDocumentWithoutARule() async throws {
        let (h, ids) = try await LabelVocabularyTests.archive()
        defer { h.env.cleanup() }
        let edp = try [#require(ids["edp_july.txt"]), #require(ids["edp_august.txt"])].sorted()
        let outcome = try await h.labels.remove(Self.label(.jurisdiction, "portugal"))
        #expect(outcome.documents == edp && outcome.rule == nil, "both documents lose it, however it is written, and no rule is made")
        for id in edp {
            #expect(try await h.services.documents.document(id: id)?.labels?.values(.jurisdiction) == [], "taken off \(id)")
        }
        #expect(try await h.services.labels.rules().isEmpty, "the user's rules are as they were")
        #expect(try await events(h, [.labelRemoved]).map(\.summary) == ["Removed jurisdiction “portugal” from 2 documents"],
                "History says what was taken off, as the user wrote it, as Ignore says it")
        let later = try await Self.readLater(h)
        #expect(later.labels?.values(.jurisdiction) == ["Portugal"], "a reading may give it again, as only Remove for Good stops it")
    }

    @Test func removingALabelNoDocumentHasChangesNothingAndRecordsNothing() async throws {
        let (h, _) = try await LabelVocabularyTests.archive()
        defer { h.env.cleanup() }
        let outcome = try await h.labels.remove(Self.label(.topic, "gardening"))
        #expect(outcome == LabelActionOutcome(rule: nil, documents: []), "nothing to take off")
        #expect(try await events(h, [.labelRemoved]).isEmpty, "and nothing recorded")
        await #expect(throws: LabelError.notALabel(.date, "someday"), "a label of no kind's form that no document has is refused") {
            try await h.labels.remove(Self.label(.date, "someday"))
        }
    }

    @Test func aMergeOrKeepingApartMadeAlreadyChangesNothingAndRecordsNothing() async throws {
        let (h, _) = try await LabelVocabularyTests.archive()
        defer { h.env.cleanup() }
        let merged = try await h.labels.merge(Self.label(.sender, "EDP-Comercial"), into: "EDP Comercial")
        let again = try await h.labels.merge(Self.label(.sender, "EDP-Comercial"), into: "EDP Comercial")
        #expect(again == LabelActionOutcome(rule: merged.rule, documents: []), "merged again, the rule there is the outcome: \(again)")
        let apart = try await h.labels.keepApart(Self.label(.sender, "MEO"), from: "EDP Comercial")
        let apartAgain = try await h.labels.keepApart(Self.label(.sender, "EDP Comercial"), from: "MEO")
        #expect(apartAgain == apart, "kept apart again, either way round, the rule there is the outcome")
        #expect(try await h.services.labels.rules() == [merged.rule, apart.rule].compactMap { $0 }, "no rule is made anew")
        #expect(try await events(h, [.labelsMerged, .labelsKeptApart]).count == 2, "and History records each decision once")
    }

    // MARK: Adding a tag

    @Test func anAddedTagIsListedWithoutDocumentsAndCountsNowhereElse() async throws {
        let (h, _) = try await LabelVocabularyTests.archive()
        defer { h.env.cleanup() }
        let outcome = try await h.labels.add(Self.label(.tag, " Taxes  2025 "))
        #expect(outcome.rule?.action == .add && outcome.rule?.value == "Taxes 2025" && outcome.documents.isEmpty,
                "the tag is kept as tags are kept, as a decision of the user's")
        #expect(try await h.services.labels.listing()[.tag] == [LabelUsage(label: Self.label(.tag, "Taxes 2025"), documents: 0)],
                "the Labels page lists it, with no document")
        #expect(try await h.services.labels.usage()[.tag] == nil, "the sidebar counts documents in view, and none has it")
        let (unadded, _) = try await LabelVocabularyTests.archive()
        defer { unadded.env.cleanup() }
        let (guidance, without) = (try await h.services.labels.guidance(), try await unadded.services.labels.guidance())
        #expect(guidance == without, "the model is told nothing of it, as of any tag")
        #expect(try await events(h, [.labelAdded]).map(\.summary) == ["Added tag “Taxes 2025”"], "History says the user added it")

        let tagged = try #require(try await h.services.documents.list(DocumentFilter(), limit: 1).first?.id)
        try await h.review.edit(tagged, fileName: nil, labels: LabelEdit(adding: [Self.label(.tag, "Taxes 2025")]))
        #expect(try await h.services.labels.listing()[.tag] == [LabelUsage(label: Self.label(.tag, "Taxes 2025"), documents: 1)],
                "given to a document, it is listed once, with it")
    }

    @Test func onlyANewTagIsAdded() async throws {
        let (h, ids) = try await LabelVocabularyTests.archive()
        defer { h.env.cleanup() }
        try await h.review.edit(try #require(ids["meo.txt"]), fileName: nil, labels: LabelEdit(adding: [Self.label(.tag, "Home")]))
        try await h.labels.add(Self.label(.tag, "Taxes 2025"))
        await #expect(throws: LabelError.notAddable(.sender), "the model gives senders") { try await h.labels.add(Self.label(.sender, "EDP")) }
        await #expect(throws: LabelError.notALabel(.tag, ""), "a tag is not blank") { try await h.labels.add(Self.label(.tag, "  ")) }
        await #expect(throws: LabelError.alreadyThere(.tag, "home"), "one a document has, however written") {
            try await h.labels.add(Self.label(.tag, "home"))
        }
        await #expect(throws: LabelError.alreadyThere(.tag, "Taxes-2025"), "one added before, however written") {
            try await h.labels.add(Self.label(.tag, "Taxes-2025"))
        }
        let (rules, added) = (try await h.services.labels.rules(), try await events(h, [.labelAdded]))
        #expect(rules.map(\.summary) == ["tag “Taxes 2025” added"] && added.count == 1, "nothing refused is added or recorded")
    }

    @Test func theAppSaysWhyALabelCannotBeRenamedByTheRuleRenamingApplies() {
        let sender = Self.label(.sender, "EDP Comercial")
        #expect(LabelError.refusal(ofMerging: sender, into: "EDP") == nil, "a new writing")
        #expect(LabelError.refusal(ofMerging: sender, into: "EDP COMERCIAL") == nil, "a new case is a new writing")
        #expect(LabelError.refusal(ofMerging: sender, into: " EDP  Comercial ") == .sameLabel(.sender, "EDP Comercial"), "the same writing")
        #expect(LabelError.refusal(ofMerging: sender, into: "12") == .notALabel(.sender, "12"), "no label of the kind")
        #expect(LabelError.refusal(ofMerging: Self.label(.amount, "5.00% GBP"), into: "5.00 GBP") == nil,
                "one an earlier reading gave in a form its kind no longer keeps can be written anew")
    }

    @Test func theAppSaysWhyATagCannotBeAddedByTheRuleAddingApplies() {
        let tag = { (value: String) in Self.label(.tag, value) }
        #expect(LabelError.refusal(ofAdding: tag("Taxes 2025"), among: ["Home"]) == nil, "a new tag")
        #expect(LabelError.refusal(ofAdding: Self.label(.topic, "taxes"), among: []) == .notAddable(.topic), "of the model's kinds")
        #expect(LabelError.refusal(ofAdding: tag(" "), among: []) == .notALabel(.tag, ""), "blank")
        #expect(LabelError.refusal(ofAdding: tag("HOME"), among: ["Home"]) == .alreadyThere(.tag, "HOME"), "in use, however written")
    }

    @Test func aTagTheUserDidNotWantIsWantedAgainOnceAdded() async throws {
        let (h, _) = try await LabelVocabularyTests.archive()
        defer { h.env.cleanup() }
        try await h.labels.ignore(Self.label(.tag, "Old"))
        try await h.labels.add(Self.label(.tag, "Old"))
        #expect(try await h.services.labels.rules().map(\.action) == [.add], "adding it ends the rule against it")
    }

    @Test func anAddedTagFollowsItsRenameAndGoesWithItsRemoval() async throws {
        let (h, _) = try await LabelVocabularyTests.archive()
        defer { h.env.cleanup() }
        let listed = { try await h.services.labels.listing()[.tag]?.map(\.label.value) ?? [] }
        try await h.labels.add(Self.label(.tag, "Taxes"))
        try await h.labels.rename(Self.label(.tag, "Taxes"), to: "Taxes 2025")
        #expect(try await listed() == ["Taxes 2025"], "renamed, it is listed under its new name, still without documents")
        #expect(try await h.services.labels.rules().map(\.summary).sorted() == ["tag “Taxes 2025” added", "tag “Taxes” → “Taxes 2025”"],
                "the rename is a rule, and the tag added is the new one")
        try await h.labels.add(Self.label(.tag, "Home"))
        try await h.labels.merge(Self.label(.tag, "Home"), into: "Taxes 2025")
        #expect(try await h.services.labels.rules().count(where: { $0.action == .add }) == 1, "merged into one added, it is added once")

        let removed = try await h.labels.remove(Self.label(.tag, "Taxes 2025"))
        let left = try await listed()
        #expect(removed.documents.isEmpty && left.isEmpty, "removed, it is listed no more")
        #expect(removed.rule?.action == .add && removed.rule?.value == "Taxes 2025", "and the outcome says which tag added was forgotten")
        #expect(try await events(h, [.labelRemoved]).map(\.summary) == ["Removed tag “Taxes 2025”"], "and History says so")

        try await h.labels.add(Self.label(.tag, "Car"))
        try await h.labels.ignore(Self.label(.tag, "Car"))
        #expect(try await listed().isEmpty, "removed for good, it goes too")
        try await h.labels.add(Self.label(.tag, "Garden"))
        try await h.labels.forget(rule: try #require(try await h.services.labels.rules().first { $0.action == .add }?.id))
        #expect(try await listed().isEmpty, "and forgotten")
    }
}
