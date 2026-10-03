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
        LabelRule(id: id, kind: kind, value: value, action: action, target: target, createdAt: TestTime.start)
    }

    // MARK: What a reading keeps

    @Test func theUsersMergesAreFollowedOneIntoTheNext() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .sender, "EDP Comercial", .merge, "EDP"),
                                              Self.rule(2, .sender, "EDP", .merge, "EDP Energia")])
        let kept = c.consolidate([Self.label(.sender, "edp comercial"), Self.label(.party, "Maria Exemplo")])
        #expect(kept.labels == [Self.label(.sender, "EDP Energia"), Self.label(.party, "Maria Exemplo")],
                "a merge applies however the model writes the label, and follows the merge of its target")
        #expect(kept.changes == [LabelChange(from: Self.label(.sender, "edp comercial"), to: Self.label(.sender, "EDP Energia"),
                                             reason: .rule(id: 2))],
                "the trace names the last rule that decided the writing")
    }

    @Test func aLabelTheUserDoesNotWantIsDroppedEvenAtTheEndOfAMerge() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .topic, "paperwork", .merge, "document"), Self.rule(2, .topic, "document", .ignore)])
        let kept = c.consolidate([Self.label(.topic, "Paperwork"), Self.label(.topic, "electricity")])
        #expect(kept.labels == [Self.label(.topic, "electricity")], "the unwanted label is dropped though a merge led to it")
        #expect(kept.changes.map(\.to) == [nil] && kept.changes.map(\.reason) == [.rule(id: 2)], "the trace says which rule dropped it")
    }

    @Test func aMergeOfOneWritingIntoAnotherDoesNotLoop() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .sender, "edp", .merge, "EDP")])
        #expect(c.consolidate([Self.label(.sender, "Edp")]).labels == [Self.label(.sender, "EDP")], "any writing of the label is merged")
        #expect(c.consolidate([Self.label(.sender, "EDP")]).changes.isEmpty, "the wanted writing is left as it is")
    }

    @Test func aLabelWrittenAsTheArchiveWritesItButOtherwiseBecomesTheArchivesLabel() throws {
        let c = try Self.consolidator(vocabulary: [(.sender, "EDP Comercial", 4), (.sender, "edp comercial", 1), (.topic, "electricity", 3)])
        let kept = c.consolidate([Self.label(.sender, "EDP-Comercial"), Self.label(.topic, "electricty")])
        #expect(kept.labels == [Self.label(.sender, "EDP Comercial"), Self.label(.topic, "electricity")],
                "the most used writing of the same label, and a typo of a topic in use")
        #expect(kept.changes.map(\.reason) == [.alike(similarity: 1), .alike(similarity: LabelSimilarity.similarity("electricty", "electricity"))],
                "the trace says how alike each was to the label in use")
        #expect(c.consolidate([Self.label(.sender, "edp comercial")]).labels == [Self.label(.sender, "EDP Comercial")],
                "a writing in use becomes the writing more documents have")
        #expect(c.consolidate([Self.label(.sender, "EDP Comercial")]).changes.isEmpty, "the most used writing stays")
    }

    @Test func namesThatDifferByALetterAreNotMergedWithoutAsking() throws {
        let c = try Self.consolidator(vocabulary: [(.party, "Maria Fernanda Exemplo", 5), (.topic, "tax", 5), (.reference, "invoice 2026/1", 2)])
        #expect(c.consolidate([Self.label(.party, "Mario Fernanda Exemplo")]).changes.isEmpty,
                "two people may differ by a letter: only the same writing merges parties")
        #expect(c.consolidate([Self.label(.topic, "taxes")]).changes.isEmpty, "a broader or narrower topic is another topic")
        #expect(c.consolidate([Self.label(.reference, "invoice 2026/2")]).changes.isEmpty, "another number is another invoice")
        #expect(c.consolidate([Self.label(.date, "2026-07-05")]).changes.isEmpty, "a kind with one form needs no vocabulary")
    }

    @Test func labelsKeptApartAreNeverMerged() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .topic, "electricity", .keepApart, "electricty")],
                                      vocabulary: [(.topic, "electricity", 3)])
        #expect(c.consolidate([Self.label(.topic, "Electricty")]).changes.isEmpty, "the user's decision outweighs the likeness")
    }

    @Test func labelsThatBecomeOneAreKeptOnce() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .sender, "EDP Comercial", .merge, "EDP")])
        #expect(c.consolidate([Self.label(.sender, "EDP"), Self.label(.sender, "EDP Comercial")]).labels == [Self.label(.sender, "EDP")],
                "a document does not show the same label twice")
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
        #expect(suggestions.first == LabelSuggestion(kind: .sender, value: "autoridade tributaria", into: "Autoridade Tributária", similarity: 1,
                                                       reason: .writtenAlike),
                "the same label written two ways first")
        #expect(suggestions.contains { $0.kind == .party && $0.value == "Mario Silva" && $0.into == "Maria Silva" },
                "names a letter apart are for the user to judge")
        #expect(!suggestions.contains { $0.value == "incomes tax" }, "not what the user kept apart")
        #expect(suggestions.contains { $0.value == "electricty" }, "a typo of a topic")
        #expect(!suggestions.contains { ["property tax", "plumbing repair"].contains($0.value) },
                "but not another subject sharing a word, nor a narrower topic, which the prompt asks for beside the broad one")
        #expect(!suggestions.contains { $0.kind == .reference }, "nor references, whose numbers differ")
        #expect(suggestions.map(\.similarity) == suggestions.map(\.similarity).sorted(by: >), "the surest suggestions come first")
    }

    /// Every pair of labels compared, as the suggestions were first worked out, each with its labels in sorted order as
    /// `AlikeLabels` compares them: what comparing only the pairs that can be alike enough must give, in the same order,
    /// of pairs as alike those written alike first (`sorted(by:)` is stable).
    static func everyPairCompared(_ c: LabelConsolidator) -> [LabelSuggestion] {
        var found: [LabelSuggestion] = []
        for kind in LabelKind.allCases {
            guard let policy = c.config.kinds[kind] else { continue }
            let usages = c.vocabulary[kind] ?? []
            for i in usages.indices {
                for j in usages.indices where j > i {
                    let (into, value) = (usages[i].label.value, usages[j].label.value)
                    guard let alike = LabelSimilarity.lookAlike(LabelSimilarity.Key(min(into, value)), LabelSimilarity.Key(max(into, value)),
                                                                atLeast: policy.suggestSimilarity),
                          !c.rules.contains(where: { $0.keepsApart(into, value, kind: kind) }) else { continue }
                    found.append(LabelSuggestion(kind: kind, value: value, into: into, similarity: alike.similarity, reason: alike.reason))
                }
            }
        }
        func order(_ s: LabelSuggestion) -> (Double, Int) { (s.similarity, s.reason == .writtenAlike ? 1 : 0) }
        return Array(found.sorted { order($0) > order($1) }.prefix(c.config.suggestionLimit))
    }

    /// Labels of every kind the vocabulary keeps, written alike in every way a label can be: the same writing far apart in
    /// length, the words in another order, a typo, a longer name, the same digits in other numbers, and the many labels
    /// that are alike to none.
    static let manyLabels: [(LabelKind, String, Int)] = {
        let senders = ["EDP Comercial SA", "E.D.P. Comercial, S.A.", "Comercial EDP", "EDP Comercail", "EDP Comercial Energia", "edp comercial",
                       "Autoridade Tributária", "Autoridade Tributaria e Aduaneira", "AUTORIDADE TRIBUTARIA", "Galp", "Galp Energia",
                       "Águas do Porto", "Aguas do Porto EM", "MEO", "M.E.O.", "Vodafone", "Vodafone Portugal"]
        let parties = ["Maria Silva", "Mario Silva", "Silva, Maria", "Maria Fernanda Silva", "João Exemplo", "Joao Exemplo", "Ana Costa"]
        let topics = ["electricity", "electricty", "income tax", "incomes tax", "property tax", "property sale", "water", "waters",
                      "telecommunications", "plumbing", "plumbing repair"]
        let references = (1...12).map { "invoice FT 2026/\($0)" } + ["FT 1/23", "FT 12/3", "ft 1-23", "invoice 2026/11", "invoice 20/2611",
                                                                   "Invoice 2026-11"]
        let objects = ["Rua das Flores 12, 3", "Rua das Flores 3, 12", "12, 3 Rua das Flores", "car AA-12-BB", "AA-12-BB car",
                       "car AB12CD", "car CD12AB", "account PT50 0002 0123 1234 5678 9015 4", "account PT50000201231234567890154",
                       "contract V/2026/532774", "contract V2026532774", "contract V2026/532774 annex"]
        let jurisdictions = ["Portugal", "Portgual", "Spain", "Espanha", "United Kingdom", "Kingdom, United"]
        func kind(_ kind: LabelKind, _ values: [String]) -> [(LabelKind, String, Int)] {
            values.enumerated().map { (kind, $1, 1 + ($0 * 7) % 5) }
        }
        return kind(.sender, senders) + kind(.party, parties) + kind(.topic, topics) + kind(.reference, references)
            + kind(.object, objects) + kind(.jurisdiction, jurisdictions)
    }()

    @Test func comparingOnlyThePairsThatCanBeAlikeFindsWhatComparingEveryPairDoes() throws {
        let rules = [Self.rule(1, .topic, "income tax", .keepApart, "incomes tax"), Self.rule(2, .sender, "Galp", .keepApart, "Galp Energia")]
        let bundled = try Self.consolidator(rules: rules, vocabulary: Self.manyLabels)
        func limited(to limit: Int) -> LabelConsolidator {
            var config = bundled.config
            config.suggestionLimit = limit
            return LabelConsolidator(config: config, rules: rules, vocabulary: bundled.vocabulary)
        }
        let all = limited(to: Self.manyLabels.count * Self.manyLabels.count)
        let found = all.suggestions()
        #expect(found == Self.everyPairCompared(all), "every pair alike enough is found, in the same order: \(found)")
        func offered(_ a: String, _ b: String) -> LabelSuggestion? {
            found.first { Set([$0.value, $0.into]) == [a, b] }
        }
        #expect(offered("EDP Comercial SA", "E.D.P. Comercial, S.A.")?.similarity == 1,
                "however far apart their lengths, labels written the same way are found")
        #expect(!found.contains { $0.kind == .reference && $0.similarity < 1 }, "references are offered only when written the same way")
        #expect(offered("Portugal", "Portgual") != nil, "and a typo, where a kind allows one")
        let few = limited(to: 5)
        #expect(found.count > 5 && few.suggestions() == Self.everyPairCompared(few), "and at most labels.vocabulary.suggestionLimit, the same ones")
    }

    @Test func theSuggestionsFollowEveryChangeToTheLabelsAndTheRules() async throws {
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: [
            "maria.txt": [Self.label(.party, "Maria Silva")], "mario.txt": [Self.label(.party, "Mario Silva")],
        ]))
        defer { h.env.cleanup() }
        let store = h.services.labels
        #expect(try await store.suggestions().isEmpty, "no labels, nothing alike")
        for name in ["maria.txt", "mario.txt"] { try await h.ingest(name, text: "A letter: \(name)") }
        #expect(try await h.services.labels.suggestions().map(\.value) == ["Mario Silva"], "two names a letter apart, once both are in use")
        try await h.labels.keepApart(Self.label(.party, "Maria Silva"), from: "Mario Silva")
        #expect(try await h.services.labels.suggestions().isEmpty, "and not once the user kept them apart")
    }

    // MARK: The user's decisions

    /// Two documents from EDP, one written otherwise, and one from MEO.
    private func archive() async throws -> (Harness, [String: Int64]) {
        let edp = StubAnalyzer.edpBill
        let edpVariant = edp.map { $0.kind == .sender ? Self.label(.sender, "EDP-Comercial") : $0 }
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: [
            "edp_july.txt": edp, "edp_august.txt": edpVariant, "meo.txt": LabelingTests.meoContract,
        ]))
        var ids: [String: Int64] = [:]
        for name in ["edp_july.txt", "edp_august.txt", "meo.txt"] { ids[name] = try await h.ingest(name, text: "A bill: \(name)").id }
        return (h, ids)
    }

    private func search(_ h: Harness, _ query: String) async throws -> [Int64] {
        try await h.search
            .fullText(SearchQuery(text: query)).hits.map(\.id).sorted()
    }

    @Test func aMergeRelabelsEveryDocumentAndIsRecorded() async throws {
        let (h, ids) = try await archive()
        defer { h.env.cleanup() }
        let edp = try [#require(ids["edp_july.txt"]), #require(ids["edp_august.txt"])].sorted()
        #expect(try await h.services.labels.usage()[.sender]?.map(\.label.value) == ["EDP Comercial", "MEO"],
                "the second writing was already made the first when the document was read")

        let outcome = try await h.labels.merge(Self.label(.sender, "EDP Comercial"), into: "EDP")
        #expect(outcome.documents == edp && outcome.rule.action == .merge && outcome.rule.target == "EDP",
                "both EDP documents are relabelled and the merge is kept as a rule")
        for id in edp {
            let labels = try #require(try await h.services.documents.document(id: id)?.labels)
            #expect(labels.values(.sender) == ["EDP"] && labels.count == StubAnalyzer.edpBill.count, "only the merged label changes")
        }
        #expect(try await search(h, "sender:\"EDP Comercial\"").isEmpty, "the old writing is no longer found")
        #expect(try await search(h, "sender:edp") == edp, "the new one is, on every document")
        let event = try #require(try await h.services.history.events(limit: 5, kinds: [.labelsMerged]).first)
        #expect(event.actor == .user && event.summary == "Merged sender “EDP Comercial” into “EDP” on 2 documents",
                "History says who merged what, on how many documents")
        #expect(try await h.services.labels.rules().map(\.id) == [outcome.rule.id], "the decision is kept as a rule")
    }

    @Test func everyReadingFromThenOnFollowsTheDecisionsAndIsToldOfThem() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        let actions = h.labels
        try await actions.merge(Self.label(.sender, "EDP Comercial"), into: "EDP")
        try await actions.ignore(Self.label(.jurisdiction, "Portugal"))

        let analyzer = StubAnalyzer()
        var services = h.services
        services.analyzer = analyzer
        let later = Harness(env: h.env, services: services)
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
        let insights = try await StatsService(database: h.env.database, config: h.env.config.stats, time: h.env.time).insights()
        #expect(insights.labelRules == ["merge": 1, "ignore": 1] && insights.labelsTidied == 3,
                "Statistics counts the rules and every label they and the vocabulary tidied, the earlier writing included")
    }

    /// The labels in use as the documents' own labels count them, each once per document that has it.
    private func counted(_ h: Harness) async throws -> [LabelKind: [LabelUsage]] {
        let documents = try await h.services.documents.list(DocumentFilter(), limit: 50)
        let labels = documents.flatMap { Set($0.labels ?? []) }
        return Dictionary(grouping: Dictionary(grouping: labels, by: { $0 }).map { LabelUsage(label: $0.key, documents: $0.value.count) },
                          by: \.label.kind).mapValues { $0.sorted { ($1.documents, $0.label.value) < ($0.documents, $1.label.value) } }
    }

    @Test func theLabelsInUseAreCountedFromAnIndexOfThemKeptInStepWithEveryChange() async throws {
        let (h, ids) = try await archive()
        defer { h.env.cleanup() }
        let indexed = { try await h.env.database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_labels") } }
        #expect(try await h.services.labels.usage() == counted(h), "the labels documents were read with are counted as they have them")
        _ = try await h.labels.merge(Self.label(.sender, "EDP Comercial"), into: "EDP")
        _ = try await h.labels.ignore(Self.label(.jurisdiction, "Portugal"))
        try await h.review.edit(try #require(ids["meo.txt"]), fileName: nil,
                                labels: LabelEdit(adding: [Self.label(.tag, "Home")], removing: [Self.label(.sender, "MEO")]))
        let usage = try await h.services.labels.usage()
        #expect(usage == (try await counted(h)), "and after a merge, a label ignored and one edited by hand, as they have them then")
        #expect(usage[.sender]?.map(\.label.value) == ["EDP"] && usage[.tag] == [LabelUsage(label: Self.label(.tag, "Home"), documents: 1)]
                    && usage[.jurisdiction]?.contains { $0.label.value == "Portugal" } == false,
                "the merged, the added and the ignored label each as the change left them: \(usage)")
        #expect(try await indexed() == usage.values.joined().reduce(0) { $0 + $1.documents },
                "the index of labels holds each label a document has once, and nothing else")
    }

    @Test func ignoringALabelTakesItOffEveryDocument() async throws {
        let (h, ids) = try await archive()
        defer { h.env.cleanup() }
        let outcome = try await h.labels.ignore(Self.label(.jurisdiction, "portugal"))
        let edp = try [#require(ids["edp_july.txt"]), #require(ids["edp_august.txt"])].sorted()
        #expect(outcome.documents == edp && outcome.rule.value == "portugal", "both EDP documents lose the label, however the user wrote it")
        for id in ids.values {
            #expect(try await h.services.documents.document(id: id)?.labels?.values(.jurisdiction).contains("Portugal") == false,
                    "no document keeps the ignored label")
        }
        #expect(try await search(h, "jurisdiction:portugal").isEmpty, "the ignored label is no longer found")
        #expect(try await h.services.history.events(limit: 5, kinds: [.labelIgnored]).first?.summary
                == "Ignored jurisdiction “portugal” and took it off 2 documents", "History says what was ignored and on how many documents")
    }

    @Test func aNewDecisionReplacesTheOnesItContradicts() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        let actions = h.labels
        try await actions.merge(Self.label(.topic, "power"), into: "electricity")
        try await actions.merge(Self.label(.topic, "energy"), into: "power")
        #expect(try await h.services.labels.rules().map(\.target) == ["electricity", "power"], "each merge is kept as a rule")
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

    @Test func aLabelWhoseWritingTheUserChoseCanBeMergedIntoAnother() async throws {
        let (h, ids) = try await archive()
        defer { h.env.cleanup() }
        let actions = h.labels
        // A rule both about the label merged and merged into it: one writing of it made another.
        try await actions.merge(Self.label(.sender, "EDP comercial"), into: "EDP Comercial")
        let outcome = try await actions.merge(Self.label(.sender, "EDP Comercial"), into: "EDP Energia")
        #expect(try await h.services.labels.rules().map(\.summary) == ["sender “EDP Comercial” → “EDP Energia”"],
                "the merge replaces the rule about the label it merges, which no longer has a writing of its own")
        let edp = try [#require(ids["edp_july.txt"]), #require(ids["edp_august.txt"])].sorted()
        #expect(outcome.documents == edp, "and relabels every document that had it")
    }

    @Test func forgettingARuleStopsReadingsFollowingItAndLeavesDocumentsAsTheyAre() async throws {
        let (h, ids) = try await archive()
        defer { h.env.cleanup() }
        let actions = h.labels
        let merge = try await actions.merge(Self.label(.sender, "EDP Comercial"), into: "EDP")
        let forgotten = try await actions.forget(rule: try #require(merge.rule.id))
        #expect(forgotten.rule.id == merge.rule.id && forgotten.rule.summary == merge.rule.summary, "the rule forgotten is the one asked for")
        #expect(try await h.services.labels.rules().isEmpty, "no rule is left for readings to follow")
        #expect(try await h.services.documents.document(id: try #require(ids["edp_july.txt"]))?.labels?.values(.sender) == ["EDP"],
                "documents keep the labels the rule gave them")
        #expect(try await h.services.history.events(limit: 5, kinds: [.labelRuleForgotten]).first?.summary
                == "Forgot: sender “EDP Comercial” → “EDP”", "History says which rule was forgotten")
        await #expect(throws: LabelError.ruleNotFound(999), "a rule that is not there") { try await actions.forget(rule: 999) }
    }

    @Test func aDecisionMustBeAboutLabelsOfTheirKind() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        let actions = h.labels
        await #expect(throws: LabelError.notALabel(.date, "yesterday"), "no date") {
            try await actions.merge(Self.label(.date, "yesterday"), into: "2026-07-05")
        }
        await #expect(throws: LabelError.sameLabel(.sender, "EDP"), "nothing to merge") {
            try await actions.merge(Self.label(.sender, "EDP"), into: " EDP ")
        }
        await #expect(throws: LabelError.sameLabel(.sender, "EDP"), "one label, however it is cased") {
            try await actions.keepApart(Self.label(.sender, "EDP"), from: "edp")
        }
        await #expect(throws: LabelError.notALabel(.language, "Klingonese"), "no language") {
            try await actions.ignore(Self.label(.language, "Klingonese"))
        }
        #expect(try await h.services.labels.rules().isEmpty, "a refused decision makes no rule")
        #expect(try await h.services.history.events(limit: 50, kinds: [.labelsMerged, .labelIgnored, .labelsKeptApart]).isEmpty,
                "and leaves no trace")
        try await actions.merge(Self.label(.language, "Portuguese"), into: "es")
        #expect(try await h.services.labels.rules().first?.summary == "language “pt” → “es”", "values are kept as their kind keeps them")
    }

    @Test func theAppRefreshesOnEveryRecordedChange() async throws {
        let (h, _) = try await archive()
        defer { h.env.cleanup() }
        let changes = await Collected.reading(h.env.database.activity())
        try #require(await Patience.until { await changes.all.count >= 1 }, "the stream reports the history's state instead of ending")
        try await h.labels.ignore(Self.label(.topic, "electricity"))
        try #require(await Patience.until { await changes.all.count >= 2 }, "a decision about labels refreshes the app")
        let (first, next) = (await changes.all[0], await changes.all[1])
        #expect(next > first, "the stream moves on to the history's new state")
        await changes.stop()
    }
}
