@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// The archive's labels are one vocabulary: labels written alike are one, the user's decisions about labels become
/// rules every reading follows, and what is merely alike waits for the user.
@Suite struct LabelVocabularyTests {
    static func label(_ kind: LabelKind, _ value: String) -> DocumentLabel { DocumentLabel(kind: kind, value: value) }

    static func vocabulary(_ labels: [(LabelKind, String, Int)]) -> [LabelKind: [LabelUsage]] {
        Dictionary(grouping: labels.map { LabelUsage(label: label($0.0, $0.1), documents: $0.2) }, by: \.label.kind)
            .mapValues { $0.sorted { $0.documents > $1.documents } }
    }

    static func consolidator(rules: [LabelRule] = [], vocabulary: [(LabelKind, String, Int)] = []) throws -> LabelConsolidator {
        LabelConsolidator(config: try PipelineConfig.bundledDefaults().labels.vocabulary, rules: rules,
                          vocabulary: Self.vocabulary(vocabulary))
    }

    static func rule(_ id: Int64, _ kind: LabelKind, _ value: String, _ action: LabelRuleAction, _ target: String? = nil) -> LabelRule {
        LabelRule(id: id, kind: kind, value: value, action: action, target: target)
    }

    // MARK: How alike labels are written

    @Test func labelsWrittenTheSameButForCaseAccentsPunctuationAndWordOrderAreOne() {
        #expect(LabelSimilarity.similarity("EDP-Comercial, S.A.", "edp comercial SA") == 1, "punctuation and case")
        #expect(LabelSimilarity.similarity("Silva, Maria", "Maria Silva") == 1, "word order")
        #expect(LabelSimilarity.similarity("Autoridade Tributária", "AUTORIDADE TRIBUTARIA") == 1, "accents")
        #expect(LabelSimilarity.sameWriting("Ｅｄｐ", "EDP"), "full-width letters")
        #expect(!LabelSimilarity.sameWriting("EDP", "EDP Comercial"), "a longer name is another writing")
    }

    @Test func labelsWhoseNumbersDifferAreNeverAlike() {
        #expect(LabelSimilarity.similarity("invoice FT 2026/926804564", "invoice FT 2026/926804565") == 0)
        #expect(LabelSimilarity.similarity("apartment Rua das Flores 12", "apartment Rua das Flores 14") == 0,
                "a number tells one address, account or invoice from the next")
    }

    @Test func otherwiseTheyAreComparedByJaroWinklerAsPublished() {
        // The examples in Winkler 1990, which defines the measure (docs/organizing-principles-sources.md).
        #expect(abs(LabelSimilarity.similarity("MARTHA", "MARHTA") - 0.961) < 0.001)
        #expect(abs(LabelSimilarity.similarity("DWAYNE", "DUANE") - 0.840) < 0.001)
        #expect(abs(LabelSimilarity.similarity("DIXON", "DICKSONX") - 0.813) < 0.001)
        #expect(LabelSimilarity.similarity("electricity", "electricty") >= 0.96, "a typo is nearly the same label")
        #expect(LabelSimilarity.similarity("income tax", "property tax") < 0.85, "a different subject is not")
    }

    @Test func theBoundFromLengthsIsNeverBelowTheSimilarity() {
        let words = ["EDP", "EDP Comercial", "electricity", "electricty", "Maria Silva", "Mario Silva", "a", "income tax",
                     "Autoridade Tributária", "tax"]
        for a in words {
            for b in words {
                let (x, y) = (LabelSimilarity.Key(a), LabelSimilarity.Key(b))
                #expect(LabelSimilarity.bound(x, y) >= LabelSimilarity.similarity(x, y) - 1e-9, "skipping \(a)/\(b) would lose a match")
            }
        }
    }

    // MARK: What a reading keeps

    @Test func theUsersMergesAreFollowedOneIntoTheNext() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .sender, "EDP Comercial", .merge, "EDP"),
                                              Self.rule(2, .sender, "EDP", .merge, "EDP Energia")])
        let kept = c.consolidate([Self.label(.sender, "edp comercial"), Self.label(.party, "Maria Exemplo")])
        #expect(kept.labels == [Self.label(.sender, "EDP Energia"), Self.label(.party, "Maria Exemplo")],
                "a merge applies however the model writes the label, and follows the merge of its target")
        #expect(kept.changes == [LabelChange(from: Self.label(.sender, "edp comercial"), to: Self.label(.sender, "EDP Energia"),
                                             reason: .rule(id: 2))])
    }

    @Test func aLabelTheUserDoesNotWantIsDroppedEvenAtTheEndOfAMerge() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .topic, "paperwork", .merge, "document"), Self.rule(2, .topic, "document", .ignore)])
        let kept = c.consolidate([Self.label(.topic, "Paperwork"), Self.label(.topic, "electricity")])
        #expect(kept.labels == [Self.label(.topic, "electricity")])
        #expect(kept.changes.map(\.to) == [nil] && kept.changes.map(\.reason) == [.rule(id: 2)], "the trace says which rule dropped it")
    }

    @Test func aMergeOfOneWritingIntoAnotherDoesNotLoop() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .sender, "edp", .merge, "EDP")])
        #expect(c.consolidate([Self.label(.sender, "Edp")]).labels == [Self.label(.sender, "EDP")])
        #expect(c.consolidate([Self.label(.sender, "EDP")]).changes.isEmpty, "the wanted writing is left as it is")
    }

    @Test func aLabelWrittenAsTheArchiveWritesItButOtherwiseBecomesTheArchivesLabel() throws {
        let c = try Self.consolidator(vocabulary: [(.sender, "EDP Comercial", 4), (.sender, "edp comercial", 1), (.topic, "electricity", 3)])
        let kept = c.consolidate([Self.label(.sender, "EDP-Comercial"), Self.label(.topic, "electricty")])
        #expect(kept.labels == [Self.label(.sender, "EDP Comercial"), Self.label(.topic, "electricity")],
                "the most used writing of the same label, and a typo of a topic in use")
        #expect(kept.changes.map(\.reason) == [.alike(similarity: 1), .alike(similarity: LabelSimilarity.similarity("electricty", "electricity"))])
        #expect(c.consolidate([Self.label(.sender, "edp comercial")]).labels == [Self.label(.sender, "EDP Comercial")],
                "a writing in use becomes the writing more documents have")
        #expect(c.consolidate([Self.label(.sender, "EDP Comercial")]).changes.isEmpty, "the most used writing stays")
    }

    @Test func namesThatDifferByALetterAreNotMergedWithoutAsking() throws {
        let c = try Self.consolidator(vocabulary: [(.party, "Maria Fernanda Exemplo", 5), (.topic, "tax", 5), (.reference, "invoice 2026/1", 2)])
        #expect(c.consolidate([Self.label(.party, "Mario Fernanda Exemplo")]).changes.isEmpty,
                "two people may differ by a letter: only the same writing merges parties")
        #expect(c.consolidate([Self.label(.topic, "taxes")]).changes.isEmpty, "a broader or narrower topic is another topic")
        #expect(c.consolidate([Self.label(.reference, "invoice 2026/2")]).changes.isEmpty)
        #expect(c.consolidate([Self.label(.date, "2026-07-05")]).changes.isEmpty, "a kind with one form needs no vocabulary")
    }

    @Test func labelsKeptApartAreNeverMerged() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .topic, "electricity", .keepApart, "electricty")],
                                      vocabulary: [(.topic, "electricity", 3)])
        #expect(c.consolidate([Self.label(.topic, "Electricty")]).changes.isEmpty)
    }

    @Test func labelsThatBecomeOneAreKeptOnce() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .sender, "EDP Comercial", .merge, "EDP")])
        #expect(c.consolidate([Self.label(.sender, "EDP"), Self.label(.sender, "EDP Comercial")]).labels == [Self.label(.sender, "EDP")])
    }

    // MARK: What waits for the user

    @Test func alikeLabelsAreOfferedToBeMergedIntoTheMoreUsedOne() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .topic, "income tax", .keepApart, "incomes tax")], vocabulary: [
            (.sender, "Autoridade Tributária", 6), (.sender, "Autoridade Tributaria Aduaneira", 1), (.sender, "autoridade tributaria", 2),
            (.party, "Maria Silva", 3), (.party, "Mario Silva", 1),
            (.topic, "income tax", 4), (.topic, "incomes tax", 1), (.topic, "electricity", 2), (.topic, "electricty", 1),
            (.topic, "property sale", 2), (.topic, "property tax", 1), (.topic, "plumbing", 2), (.topic, "plumbing repair", 1),
            (.reference, "invoice 1", 1), (.reference, "invoice 2", 1),
        ])
        let suggestions = c.suggestions()
        #expect(suggestions.first == LabelSuggestion(kind: .sender, value: "autoridade tributaria", into: "Autoridade Tributária", similarity: 1),
                "the same label written two ways first")
        #expect(suggestions.contains { $0.kind == .party && $0.value == "Mario Silva" && $0.into == "Maria Silva" },
                "names a letter apart are for the user to judge")
        #expect(!suggestions.contains { $0.value == "incomes tax" }, "not what the user kept apart")
        #expect(suggestions.contains { $0.value == "electricty" }, "a typo of a topic")
        #expect(!suggestions.contains { ["property tax", "plumbing repair"].contains($0.value) },
                "but not another subject sharing a word, nor a narrower topic, which the prompt asks for beside the broad one")
        #expect(!suggestions.contains { $0.kind == .reference }, "nor references, whose numbers differ")
        #expect(suggestions.map(\.similarity) == suggestions.map(\.similarity).sorted(by: >))
    }

    // MARK: The user's decisions

    /// Two documents from EDP, one written otherwise, and one from MEO.
    private func archive() async throws -> (Harness, [String: Int64]) {
        let edp = StubAnalyzer.edpBill
        let edpVariant = edp.map { $0.kind == .sender ? Self.label(.sender, "EDP-Comercial") : $0 }
        let h = try await Harness.make(analyzer: LabelingTests.PerFileAnalyzer(labels: [
            "edp_july.txt": edp, "edp_august.txt": edpVariant, "meo.txt": LabelingTests.meoContract,
        ]))
        var ids: [String: Int64] = [:]
        for name in ["edp_july.txt", "edp_august.txt", "meo.txt"] { ids[name] = try await h.ingest(name, text: "A bill: \(name)").id }
        return (h, ids)
    }

    private func search(_ h: Harness, _ query: String) async throws -> [Int64] {
        try await SearchService(database: h.env.database, vectors: VectorIndex(), embedder: nil, config: h.env.config.search)
            .fullText(SearchQuery(text: query)).hits.map(\.id).sorted()
    }

    @Test func aMergeRelabelsEveryDocumentAndIsRecorded() async throws {
        let (h, ids) = try await archive()
        defer { h.env.cleanup() }
        let edp = try [#require(ids["edp_july.txt"]), #require(ids["edp_august.txt"])].sorted()
        #expect(try await h.services.labels.usage()[.sender]?.map(\.label.value) == ["EDP Comercial", "MEO"],
                "the second writing was already made the first when the document was read")

        let outcome = try await LabelActions(database: h.env.database).merge(Self.label(.sender, "EDP Comercial"), into: "EDP")
        #expect(outcome.documents == edp && outcome.rule.action == .merge && outcome.rule.target == "EDP")
        for id in edp {
            let labels = try #require(try await h.services.documents.document(id: id)?.labels)
            #expect(labels.values(.sender) == ["EDP"] && labels.count == StubAnalyzer.edpBill.count, "only the merged label changes")
        }
        #expect(try await search(h, "sender:\"EDP Comercial\"").isEmpty, "the old writing is no longer found")
        #expect(try await search(h, "sender:edp") == edp, "the new one is, on every document")
        let event = try #require(try await h.services.history.events(limit: 5, kinds: [.labelsMerged]).first)
        #expect(event.actor == .user && event.summary == "Merged sender “EDP Comercial” into “EDP” on 2 documents")
        #expect(try await h.services.labels.rules().map(\.id) == [outcome.rule.id], "the decision is kept as a rule")
    }

    @Test func everyReadingFromThenOnFollowsTheDecisionsAndIsToldOfThem() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        let actions = LabelActions(database: h.env.database)
        try await actions.merge(Self.label(.sender, "EDP Comercial"), into: "EDP")
        try await actions.ignore(Self.label(.jurisdiction, "Portugal"))

        let analyzer = StubAnalyzer()
        var services = h.services
        services.analyzer = analyzer
        let later = Harness(env: h.env, services: services, coordinator: IngestCoordinator(services: services))
        let document = try await later.ingest("edp_september.txt", text: "EDP electricity September")
        let labels = try #require(document.labels)
        #expect(labels.values(.sender) == ["EDP"], "the model's EDP Comercial is written as the user wants it")
        #expect(labels.values(.jurisdiction).isEmpty, "a label the user does not want is not given again")

        let guidance = try #require(await analyzer.calls.guidance.last)
        #expect(guidance.preferred == [LabelPreference(from: Self.label(.sender, "EDP Comercial"), to: "EDP")],
                "the model is shown how the user wants labels written")
        #expect(guidance.unwanted == [Self.label(.jurisdiction, "Portugal")], "and what the user does not want")
        #expect(guidance.used[.sender] == ["EDP", "MEO"] && guidance.used[.reference] == nil,
                "and the labels in use, of the kinds the configuration shows")

        let docID = try #require(document.id)
        let trace = try #require(try await h.services.traces.traces(docID: docID).first?.id)
        let step = try #require(try await h.services.traces.trace(id: trace)?.1.first { $0.stage == TraceStage.consolidate.rawValue })
        let consolidation = try #require(JSON.decode(LabelConsolidation.self, from: step.outputJson))
        #expect(consolidation.changes.count == 2, "the trace says what the rules changed")
        let event = try #require(try await h.services.history.events(limit: 30, kinds: [.analysed], docID: docID).first)
        #expect(JSON.decode(AnalysedPayload.self, from: event.payloadJson)?.changes == consolidation.changes, "and so does the history")
        let insights = try await StatsService(database: h.env.database, config: h.env.config.stats).insights()
        #expect(insights.labelRules == ["merge": 1, "ignore": 1] && insights.labelsTidied == 3,
                "Statistics counts the rules and every label they and the vocabulary tidied, the earlier writing included")
    }

    @Test func ignoringALabelTakesItOffEveryDocument() async throws {
        let (h, ids) = try await archive()
        defer { h.env.cleanup() }
        let outcome = try await LabelActions(database: h.env.database).ignore(Self.label(.jurisdiction, "portugal"))
        #expect(outcome.documents.count == 2 && outcome.rule.value == "portugal")
        for id in ids.values {
            #expect(try await h.services.documents.document(id: id)?.labels?.values(.jurisdiction).contains("Portugal") == false)
        }
        #expect(try await search(h, "jurisdiction:portugal").isEmpty)
        #expect(try await h.services.history.events(limit: 5, kinds: [.labelIgnored]).first?.summary
                == "Ignored jurisdiction “portugal” and took it off 2 documents")
    }

    @Test func aNewDecisionReplacesTheOnesItContradicts() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        let actions = LabelActions(database: h.env.database)
        try await actions.merge(Self.label(.topic, "power"), into: "electricity")
        try await actions.merge(Self.label(.topic, "energy"), into: "power")
        #expect(try await h.services.labels.rules().map(\.target) == ["electricity", "power"])
        try await actions.merge(Self.label(.topic, "electricity"), into: "power")
        #expect(try await h.services.labels.rules().map(\.summary) == ["topic “energy” → “power”", "topic “electricity” → “power”"],
                "merging back undoes the merge the other way, which would loop")

        try await actions.ignore(Self.label(.topic, "energy"))
        #expect(try await h.services.labels.rules().filter { $0.value == "energy" }.map(\.action) == [.ignore], "one decision per label")
        try await actions.merge(Self.label(.topic, "fuel"), into: "energy")
        #expect(!(try await h.services.labels.rules()).contains { $0.action == .ignore }, "merging into a label means it is wanted again")

        try await actions.keepApart(Self.label(.topic, "fuel"), from: "energy")
        let rules = try await h.services.labels.rules()
        #expect(!rules.contains { $0.value == "fuel" && $0.action == .merge }, "keeping apart undoes a merge between the two")
        try await actions.keepApart(Self.label(.topic, "energy"), from: "Fuel")
        #expect(try await h.services.labels.rules().count(where: { $0.action == .keepApart }) == 1, "and is made once")
    }

    @Test func forgettingARuleStopsReadingsFollowingItAndLeavesDocumentsAsTheyAre() async throws {
        let (h, ids) = try await archive()
        defer { h.env.cleanup() }
        let actions = LabelActions(database: h.env.database)
        let merge = try await actions.merge(Self.label(.sender, "EDP Comercial"), into: "EDP")
        let forgotten = try await actions.forget(rule: try #require(merge.rule.id))
        #expect(forgotten.rule.id == merge.rule.id && forgotten.rule.summary == merge.rule.summary)
        #expect(try await h.services.labels.rules().isEmpty)
        #expect(try await h.services.documents.document(id: try #require(ids["edp_july.txt"]))?.labels?.values(.sender) == ["EDP"])
        #expect(try await h.services.history.events(limit: 5, kinds: [.labelRuleForgotten]).first?.summary
                == "Forgot: sender “EDP Comercial” → “EDP”")
        await #expect(throws: LabelError.self, "a rule that is not there") { try await actions.forget(rule: 999) }
    }

    @Test func aDecisionMustBeAboutLabelsOfTheirKind() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        let actions = LabelActions(database: h.env.database)
        await #expect(throws: LabelError.self, "no date") { try await actions.merge(Self.label(.date, "yesterday"), into: "2026-07-05") }
        await #expect(throws: LabelError.self, "nothing to merge") { try await actions.merge(Self.label(.sender, "EDP"), into: " EDP ") }
        await #expect(throws: LabelError.self, "one label") { try await actions.keepApart(Self.label(.sender, "EDP"), from: "edp") }
        await #expect(throws: LabelError.self, "no language") { try await actions.ignore(Self.label(.language, "Klingonese")) }
        #expect(try await h.services.labels.rules().isEmpty, "a refused decision makes no rule")
        #expect(try await h.services.history.events(limit: 50, kinds: [.labelsMerged, .labelIgnored, .labelsKeptApart]).isEmpty,
                "and leaves no trace")
        try await actions.merge(Self.label(.language, "Portuguese"), into: "es")
        #expect(try await h.services.labels.rules().first?.summary == "language “pt” → “es”", "values are kept as their kind keeps them")
    }

    @Test func theAppRefreshesOnEveryRecordedChange() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        var changes = h.env.database.activity().makeAsyncIterator()
        let first = try #require(await changes.next(), "the stream reports the history's state instead of ending")
        try await LabelActions(database: h.env.database).ignore(Self.label(.topic, "electricity"))
        let next = try #require(await changes.next(), "a decision about labels refreshes the app")
        #expect(next > first)
    }
}
