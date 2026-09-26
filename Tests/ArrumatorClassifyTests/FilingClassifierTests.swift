@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

@Suite struct FilingClassifierTests {
    @Test func emptyArchiveModelProposesFirstFolderAndFileName() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let sink = MemoryTraceSink()
        let outcome = try await h.classify(Fixtures.content("scan_0001.pdf", text: Fixtures.edpText),
                                           trace: TraceContext(traceID: 1, sink: sink))
        let d = outcome.decision
        #expect(d.folderCode == nil)
        #expect(d.proposedNewFolder?.parentCode == nil && d.proposedNewFolder?.levels.map(\.name) == ["Home", "Utilities"])
        #expect(d.proposedNewFolder?.levels.last?.description == "Electricity, gas and water bills.")
        #expect(d.proposedNewFolder?.yearSubfolders == true && d.yearFolder == true)
        #expect(d.fileName == "2026-07-05 EDP - Fatura eletricidade junho")
        #expect(d.decidedBy == .llm && d.documentType == .invoice && d.documentDate == "2026-07-05")
        let request = try #require(await h.mock.chatRequests.first)
        #expect(Fixtures.isDecision(request) && request.allText.contains("Findability first"), "the logic decides the path")
        #expect(await h.mock.chatCount == 1, "one request decides the path and names the file")
        #expect(!request.allText.contains("{{"))
        #expect(request.format?["properties"]?["ideal_path"] != nil, "the model describes a path")
        #expect(request.format?["properties"]?["folder_code"] == nil, "and never picks a folder code: the app maps the path")
        #expect(Set(await sink.steps.map(\.stage)).isSuperset(of: [.correspondent, .embed, .rules, .candidates, .llm, .validate, .calibrate]))
    }

    @Test func theModelIsShownNoFolderToCopy() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(path: ["Home", "Utilities"]))
        defer { h.env.cleanup() }
        try await h.logic.update(body: "Areas of life, topics inside them.")
        let current = LogicStore.version(of: try await h.logic.current())
        _ = try await h.env.folder(path: ["Finances", "Energy Bills"], description: "Electricity and gas bills.", logic: current)
        _ = try await h.classify(Fixtures.content("x.pdf", text: Fixtures.edpText))
        let decision = try #require(await h.mock.chatRequests.first(where: Fixtures.isDecision))
        #expect(!decision.allText.contains("Finances") && !decision.allText.contains("Energy Bills"),
                "shown any folder, broad ones included, a model copies it whether it fits or not; the app resolves the path")
    }

    @Test func aRewordedTopicJoinsTheFolderOnlyWhenTheModelPicksIt() async throws {
        for (answer, joins) in [("1", true), ("none", false), ("unsure", false), ("2", false)] {
            let h = try await ClassifyHarness.make(handler: { request in
                Fixtures.isJudge(request) ? Fixtures.choice(answer) : Fixtures.answer(path: ["Home", "Household Utilities"])
            })
            defer { h.env.cleanup() }
            let folder = try await h.env.folder("Utilities", area: "Home", yearly: true, description: "Electricity, gas and water bills.")
            let sink = MemoryTraceSink()
            let outcome = try await h.classify(Fixtures.content("x.pdf", text: Fixtures.edpText), trace: TraceContext(traceID: 1, sink: sink))
            #expect((outcome.decision.folderCode == folder.code) == joins, "\(answer)")
            #expect(joins || outcome.decision.proposedNewFolder?.levels.map(\.name) == ["Household Utilities"],
                    "none of them, unsure, or a folder that was not offered keeps it apart: \(answer)")
            let requests = await h.mock.chatRequests
            let decision = try #require(requests.first(where: Fixtures.isDecision))
            #expect(!decision.allText.contains("Utilities —") && !decision.allText.contains(folder.code),
                    "the folders that exist cannot pull the decision away from the logic")
            let judge = try #require(requests.first(where: Fixtures.isJudge))
            #expect(judge.allText.contains("## PLACE\nHome") && judge.allText.contains("## DECIDED FOLDER\nHousehold Utilities — Electricity")
                    && judge.allText.contains("## EXISTING FOLDERS\n1. Utilities — Electricity, gas and water bills."),
                    "the model sees the decided folder and the folders it may be, what each is for, and where")
            #expect(judge.allText.contains("## DOCUMENT\nTitle: Fatura eletricidade junho\nType: invoice\nFrom: "),
                    "and the document itself, so it answers where this document is at home, not whether two names match")
            let asked = try #require(await sink.steps.first { $0.stage == .judge })
            #expect(asked.status == (answer == "2" ? .error : .ok), "each question and its answer are in the trace: \(answer)")
        }
    }

    @Test func aKnownSendersDocumentJoinsItsFolderHoweverTheModelWordsThePath() async throws {
        let reworded = ["Global - Cross-Border", "EDP Comercial – Comercialização de Energia"]
        let h = try await ClassifyHarness.make(handler: { _ in
            Fixtures.answer(path: reworded, correspondent: "EDP Comercial – Comercialização de Energia, S.A.")
        })
        defer { h.env.cleanup() }
        try await h.logic.update(body: "Jurisdiction / Institution.")
        let version = LogicStore.version(of: try await h.logic.current())
        let edp = try await h.store.saveCorrespondent(Correspondent(canonicalName: "EDP Comercial", stableKeys: [Self.edpNIF.token],
                                                                    origin: .learned))
        let home = try await h.env.folder(path: ["Portugal", "EDP Comercial"], kinds: [.topic, .sender], logic: version)
        try await h.filed("july.pdf", into: home, from: edp.id)

        let outcome = try await h.classify(Fixtures.content("august.pdf", text: Fixtures.edpText, keys: [Self.edpNIF]))
        #expect(outcome.decision.folderCode == home.code && outcome.decision.correspondentID == edp.id,
                "recognised by its tax number, the sender's document joins the folder its documents are in")
        let decision = try #require(await h.mock.chatRequests.first(where: Fixtures.isDecision))
        #expect(!decision.allText.contains("Portugal"), "the model decides from the logic and the document; it is shown no folder to copy")
    }

    @Test func aDocumentWhoseIdentifiersShowAnotherSenderWaitsForTheUser() async throws {
        let h = try await ClassifyHarness.make(handler: { _ in
            Fixtures.answer(path: ["Portugal", "MEO"], correspondent: "MEO", confidence: 0.99)
        })
        defer { h.env.cleanup() }
        let edp = try await h.store.saveCorrespondent(Correspondent(canonicalName: "EDP Comercial", stableKeys: [Self.edpNIF.token],
                                                                    origin: .learned))
        _ = try await h.store.saveCorrespondent(Correspondent(canonicalName: "MEO", origin: .learned))
        let disputed = try await h.classify(Fixtures.content("x.pdf", text: Fixtures.edpText, keys: [Self.edpNIF]))
        #expect(disputed.decision.band == .review && disputed.decision.correspondentID == nil)
        #expect(disputed.decision.reviewReasons.contains { $0.contains("EDP Comercial's") && $0.contains("reads as from MEO") })
        #expect(disputed.decision.reviewReasons.count == Set(disputed.decision.reviewReasons).count, "each reason is given once")

        let statement = try await h.classify(Fixtures.content("y.pdf", text: Fixtures.edpText + "\nDébito MEO 29,99", keys: [Self.edpNIF]))
        #expect(statement.decision.reviewReasons.allSatisfy { !$0.contains("reads as from") } && statement.decision.correspondent == "MEO",
                "a document showing the sender it names is from that sender, whatever other parties it lists")

        let h2 = try await ClassifyHarness.make(handler: { _ in
            Fixtures.answer(path: ["Portugal", "Millennium BCP"], correspondent: "Millennium BCP")
        })
        defer { h2.env.cleanup() }
        _ = try await h2.store.saveCorrespondent(Correspondent(id: edp.id, canonicalName: "EDP Comercial", stableKeys: [Self.edpNIF.token],
                                                               origin: .learned))
        let newcomer = try await h2.classify(Fixtures.content("z.pdf", text: Fixtures.edpText, keys: [Self.edpNIF]))
        #expect(newcomer.decision.correspondentID == nil && newcomer.decision.correspondent == "Millennium BCP",
                "a sender the app does not know is not taken for a known one whose identifier it merely carries")
    }

    @Test func aSenderWrittenOutInFullIsTheKnownSenderWhoseNameTheDocumentShows() async throws {
        let h = try await ClassifyHarness.make(handler: { _ in
            Fixtures.answer(path: ["Portugal", "EDP Comercial – Comercialização de Energia, S.A."],
                            correspondent: "EDP Comercial – Comercialização de Energia, S.A.")
        })
        defer { h.env.cleanup() }
        let edp = try await h.store.saveCorrespondent(Correspondent(canonicalName: "EDP Comercial", origin: .learned))
        let named = try await h.classify(Fixtures.content("x.pdf", text: Fixtures.edpText))
        #expect(named.decision.correspondentID == edp.id,
                "before any identifier is learned, a known sender named in the document and read alike is that sender")
        let absent = try await h.classify(Fixtures.content("y.pdf", text: "Fatura de eletricidade, sem nome do fornecedor"))
        #expect(absent.decision.correspondentID == nil, "a reading alike is not enough when the document does not show the name")
    }

    @Test func whatALevelStandsForComesFromWhoTheDocumentIsFromAndAbout() throws {
        let config = try PipelineConfig.bundledDefaults()
        let resolver = CorrespondentResolver(correspondents: [], config: config.classification, entities: config.entities, ambiguousKeys: [])
        let path = ["Portugal", "Hlistan", "Taxes", "Tax Authority"].map { FolderLevel(name: $0, description: "") }
        let threshold = config.classification.placementGuard.partyAbove
        let across = Float(threshold + (1 - threshold) / 2)
        let vectors: [String: [Float]] = ["Portugal": [1, 0, 0], "Hlistan": [0, 1, 0], "Taxes": VectorCodec.normalized([0.5, 0, 0.5]),
                                          "Tax Authority": [0, 0, 1],
                                          "Autoridade Tributária e Aduaneira": VectorCodec.normalized([0, (1 - across * across).squareRoot(), across])]
        let marked = FilingClassifier.marked(path, senderNames: ["Autoridade Tributária e Aduaneira"], subject: "Hlistan Zolerani, Lda.",
                                             resolver: resolver, vectors: vectors, partyAbove: threshold)
        #expect(marked.map(\.kind) == [.topic, .subject, .topic, .sender],
                "the subject is named alike, the sender in another language; everything else is a topic")
        let unlike = FilingClassifier.marked(path, senderNames: ["Autoridade Tributária e Aduaneira"], subject: nil, resolver: resolver,
                                             vectors: [:], partyAbove: threshold)
        #expect(unlike.allSatisfy { $0.kind == .topic }, "without a name alike, nothing is taken for the sender")
        let country = FilingClassifier.marked(["Portugal", "Maria Exemplo", "Health"].map { FolderLevel(name: $0, description: "") },
                                              senderNames: ["Unilabs Portugal, S.A."], subject: nil, resolver: resolver, vectors: [:],
                                              partyAbove: threshold)
        #expect(country.allSatisfy { $0.kind == .topic }, "a country in the sender's name does not make the country's folder the sender's")
        let written = FilingClassifier.marked(["Portugal", "EDP Comercial"].map { FolderLevel(name: $0, description: "") },
                                              senderNames: ["EDP Comercial – Comercialização de Energia, S.A."], subject: nil,
                                              resolver: resolver, vectors: [:], partyAbove: threshold)
        #expect(written.map(\.kind) == [.topic, .sender], "a sender's short name is its name")
        let same = FilingClassifier.marked([FolderLevel(name: "Maria Exemplo", description: "")], senderNames: ["Maria Exemplo"],
                                           subject: "Maria Exemplo", resolver: resolver, vectors: [:], partyAbove: threshold)
        #expect(same.map(\.kind) == [.sender], "one level stands for one party")
    }

    private static let edpNIF = StableKey(kind: .ptNIF, value: "503504564")

    @Test func invalidAnswersAreRepairedThenHeldForReview() async throws {
        let h = try await ClassifyHarness.make(handler: { _ in "not json" })
        defer { h.env.cleanup() }
        let outcome = try await h.classify(Fixtures.content("x.pdf", text: "Some unrelated text"))
        #expect(outcome.decision.folderCode == nil && outcome.decision.proposedNewFolder == nil)
        #expect(outcome.decision.band == .review)
        #expect(await h.mock.chatCount == (h.env.config.classification.repairAttempts + 1) * 2)
    }

    @Test func usageFormsARuleAndConfidentRulesSkipTheModel() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true)
        let nif = StableKey(kind: .ptNIF, value: "503504564")
        for i in 0..<h.env.config.learning.ruleMinSupport {
            try await h.fileConfirmed(Fixtures.content("edp_\(i).pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        }
        let rules = try await h.store.rules()
        let induced = try #require(rules.first { $0.origin == .induced && $0.predicates.contains(.documentType(.invoice)) })
        #expect(induced.action.folderCode == folder.code && induced.support == h.env.config.learning.ruleMinSupport)
        let known = try await h.store.correspondents()
        let edp = try #require(known.first { $0.canonicalName == "EDP Comercial" })
        #expect(edp.stableKeys.contains(nif.token))
        let about = try String(contentsOf: h.env.archive.appendingPathComponent(folder.relativePath)
            .appendingPathComponent(h.env.config.taxonomy.aboutFileName), encoding: .utf8)
        #expect(about.contains("Usual correspondents: EDP"))

        let before = await h.mock.chatCount
        let outcome = try await h.classify(Fixtures.content("fatura_edp_4.pdf", text: Fixtures.edpText, keys: [nif]))
        #expect(outcome.decision.decidedBy == .rule)
        #expect(outcome.decision.folderCode == folder.code && outcome.decision.band == .auto)
        #expect(await h.mock.chatCount == before + 1, "a confident rule places it without asking the model where it goes")
        let naming = try #require(await h.mock.chatRequests.last)
        #expect(naming.format?["properties"]?["folder_code"] == nil, "the model is only asked for the name")
        #expect(naming.allText.contains("## LOGIC") && naming.allText.contains("Findability first"), "named as the logic says")
        #expect(naming.allText.contains(folder.name), "with the folder it goes to, to follow its naming")
        #expect(outcome.decision.fileName == "2026-07-05 EDP - Fatura eletricidade junho")

        var settings = h.settings
        settings.renameFiles = false
        let unnamed = try await h.classifier.classify(Fixtures.content("fatura_edp_5.pdf", text: Fixtures.edpText, keys: [nif]),
                                                      taxonomy: try await h.env.taxonomy.snapshot(root: h.env.archive),
                                                      settings: settings, config: h.env.config, mode: .arrival, trace: .disabled)
        let calls = await h.mock.chatCount
        #expect(unnamed.decision.fileName == nil && calls == before + 1, "files that keep their names need no model")
    }

    @Test func nearIdenticalPastFilingsPlaceDirectly() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home")
        let text = "Monthly water bill for flat 5B, water consumption and sewage charges"
        for i in 0..<h.env.config.learning.directPlacement.knnMinNeighbors {
            try await h.fileConfirmed(Fixtures.content("water_\(i).pdf", text: text, date: nil), into: folder)
        }
        for var rule in try await h.store.rules() {
            rule.enabled = false
            try await h.store.saveRule(rule)
        }
        let before = await h.mock.chatCount
        let outcome = try await h.classify(Fixtures.content("water_next.pdf", text: text, date: nil))
        #expect(outcome.decision.decidedBy == .knnOnly && outcome.decision.folderCode == folder.code)
        #expect(await h.mock.chatCount == before + 1, "past filings place it; the model only names it")
    }

    @Test func aRecurringDocumentJoinsItsConfidentlyFiledPredecessorWithoutTheModelDeciding() async throws {
        let text = "EDP fatura eletricidade julho, consumo 215 kWh, total a pagar 48,20 EUR"
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(path: ["Household", "Power"]))
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home")
        try await h.fileConfirmed(Fixtures.content("july.pdf", text: text, date: nil), into: folder)
        for var rule in try await h.store.rules() {
            rule.enabled = false
            try await h.store.saveRule(rule)
        }
        let august = try await h.classify(Fixtures.content("august.pdf", text: text, date: nil))
        #expect(august.decision.decidedBy == .knnOnly && august.decision.folderCode == folder.code,
                "a small model names a recurring document differently each time; its predecessor's folder keeps it with the rest")

        let unsure = try await ClassifyHarness.make(handler: Fixtures.answering(path: ["Household", "Power"]))
        defer { unsure.env.cleanup() }
        let guessed = try await unsure.env.folder("Utilities", area: "Home")
        try await unsure.fileUnconfirmed(Fixtures.content("july.pdf", text: text, date: nil), into: guessed)
        let next = try await unsure.classify(Fixtures.content("august.pdf", text: text, date: nil))
        #expect(next.decision.decidedBy == .llm, "an uncertain filing is not repeated for its twin")

        let split = try await ClassifyHarness.make(handler: Fixtures.answering(path: ["Household", "Power"]))
        defer { split.env.cleanup() }
        try await split.fileConfirmed(Fixtures.content("july.pdf", text: text, date: nil), into: try await split.env.folder("Utilities", area: "Home"))
        try await split.fileConfirmed(Fixtures.content("june.pdf", text: text, date: nil), into: try await split.env.folder("Energy", area: "Money"))
        for var rule in try await split.store.rules() {
            rule.enabled = false
            try await split.store.saveRule(rule)
        }
        #expect(try await split.classify(Fixtures.content("august.pdf", text: text, date: nil)).decision.decidedBy == .llm,
                "twins filed in two places decide nothing")
    }

    @Test func aPathThatDoesNotExistIsCreatedWhateverFoldersDo() async throws {
        let h = try await ClassifyHarness.make(handler: { _ in
            Fixtures.answer(path: ["Money and Taxes", "Taxes Portugal"],
                            description: "IRS declarations and tax assessments from the Portuguese tax authority.")
        })
        defer { h.env.cleanup() }
        _ = try await h.env.folder("Utilities", area: "Home")
        let outcome = try await h.classify(Fixtures.content("irs.pdf", text: "Declaração Modelo 3 IRS rendimentos 2025"))
        #expect(outcome.decision.folderCode == nil)
        #expect(outcome.decision.proposedNewFolder?.levels.map(\.name) == ["Money and Taxes", "Taxes Portugal"])
    }

    @Test func aTopicTheLogicPutsElsewhereGetsItsFolderThere() async throws {
        let h = try await ClassifyHarness.make(handler: { _ in
            Fixtures.answer(path: ["Work", "Payslips"], description: "Monthly salary statements.")
        })
        defer { h.env.cleanup() }
        let misplaced = try await h.env.folder("Payslips", area: "Home")
        let outcome = try await h.classify(Fixtures.content("payslip.pdf", text: "Acme Ltd payslip August 2026 net pay"))
        #expect(outcome.decision.folderCode == nil, "\(misplaced.relativePath) is in the wrong part of the archive")
        #expect(outcome.decision.proposedNewFolder?.parentCode == nil && outcome.decision.proposedNewFolder?.levels.map(\.name) == ["Work", "Payslips"])
    }

    @Test func sharedIdentifiersNeverIdentifyACorrespondent() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home")
        let mine = StableKey(kind: .ptNIF, value: "999999990")
        let edp = try await h.store.saveCorrespondent(Correspondent(canonicalName: "EDP", origin: .learned))
        let meo = try await h.store.saveCorrespondent(Correspondent(canonicalName: "MEO", origin: .learned))
        for (i, c) in [edp, edp, meo, meo].enumerated() {
            let docID = try await h.document("d\(i).pdf", folderID: folder.id)
            try await h.store.insertMemory(FilingMemory(id: 0, documentID: docID, folderID: folder.id, folderCode: folder.code,
                                                        embedding: [1, 0], embeddingModel: "bge-m3", summaryLine: "x",
                                                        correspondentID: c.id, documentType: .invoice, language: "pt",
                                                        stableKeys: [mine.token], weight: 1, source: "approved", createdAt: Date()))
        }
        let owners = try await h.store.stableKeyOwners(minWeight: h.env.config.learning.trustedMemoryMinWeight)
        #expect(owners[mine.token] == [edp.id, meo.id])
        var claimed = edp
        claimed.stableKeys = [mine.token]
        try await h.store.saveCorrespondent(claimed)
        let content = Fixtures.content("new.pdf", text: "Fatura", keys: [mine])
        let resolver = CorrespondentResolver(correspondents: try await h.store.correspondents(), config: h.env.config.classification,
                                             entities: h.env.config.entities, ambiguousKeys: [mine.token])
        #expect(!resolver.resolve(content).contains { $0.matchedBy == .stableKey })
    }

    @Test func confirmingUncertainPlacementsMakesThemEvidence() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true, description: "Electricity, gas and water bills.")
        let nif = StableKey(kind: .ptNIF, value: "503504564")
        for i in 0..<h.env.config.learning.ruleMinSupport {
            let content = Fixtures.content("edp_\(i).pdf", text: Fixtures.edpText, keys: [nif])
            var outcome = try await h.classify(content)
            outcome.decision.folderCode = folder.code
            outcome.decision.confidence.band = .check
            let docID = try await h.document(content.source.originalFilename, folderID: folder.id, correspondent: "EDP")
            await h.learner.documentFiled(documentID: docID, folderID: folder.id, outcome: outcome, content: content,
                                          confirmedByUser: false, trace: .disabled)
            #expect(try await h.store.rules().isEmpty, "uncertain placements alone must not form rules")
            await h.learner.correctionRecorded(CorrectionEvent(documentID: docID, source: .markCorrect, fromFolderID: folder.id,
                                                               toFolderID: folder.id), trace: .disabled)
        }
        let rules = try await h.store.rules()
        #expect(rules.contains { $0.action.folderCode == folder.code && $0.origin == .induced })
    }

    @Test func contradictionsDisableRules() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home")
        let other = try await h.env.folder("Rent", area: "Home")
        let rule = try await h.store.saveRule(FilingRule(name: "EDP → Utilities", priority: 50, origin: .induced,
                                                         predicates: [.filenameGlob("*.pdf")],
                                                         action: RuleAction(folderID: folder.id, folderCode: folder.code), support: 3))
        let proposed = FilingDecision(folderCode: folder.code, title: "t",
                                      confidence: ConfidenceReport(ruleHit: rule.id, final: 1, band: .auto, thresholds: h.settings.thresholds),
                                      decidedBy: .rule, rationale: "rule")
        for i in 0..<h.env.config.learning.ruleDisableAfterContradictions {
            let docID = try await h.document("d\(i).pdf")
            await h.learner.correctionRecorded(CorrectionEvent(documentID: docID, source: .finderMove, fromFolderID: folder.id,
                                                               toFolderID: other.id, proposed: proposed), trace: .disabled)
        }
        let after = try await h.store.rules()
        let updated = try #require(after.first { $0.id == rule.id })
        #expect(!updated.enabled && updated.reliability < 1)
    }

    @Test func moreAgreeingFilingsStrengthenAnExistingRule() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true)
        let nif = StableKey(kind: .ptNIF, value: "503504564")
        let minimum = h.env.config.learning.ruleMinSupport
        for i in 0..<minimum {
            try await h.fileConfirmed(Fixtures.content("edp_\(i).pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        }
        let induced = try #require(try await h.store.rules().first { $0.predicates.contains(.documentType(.invoice)) })
        #expect(induced.support == minimum)

        for i in 0..<3 {
            try await h.fileConfirmed(Fixtures.content("edp_more_\(i).pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        }
        let strengthened = try #require(try await h.store.rules().first { $0.id == induced.id })
        #expect(strengthened.support == minimum + 3, "a rule must keep learning from filings that agree with it")
    }

    @Test func aDisabledRuleComesBackWhenTheEvidenceRecovers() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true)
        let other = try await h.env.folder("Rent", area: "Home")
        let nif = StableKey(kind: .ptNIF, value: "503504564")
        for i in 0..<h.env.config.learning.ruleMinSupport {
            try await h.fileConfirmed(Fixtures.content("edp_\(i).pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        }
        let induced = try #require(try await h.store.rules().first { $0.predicates.contains(.documentType(.invoice)) })
        let proposed = FilingDecision(folderCode: folder.code, correspondentID: induced.action.correspondentID, title: "t",
                                      confidence: ConfidenceReport(ruleHit: induced.id, final: 1, band: .auto,
                                                                   thresholds: h.settings.thresholds),
                                      decidedBy: .rule, rationale: "rule")
        for i in 0..<h.env.config.learning.ruleDisableAfterContradictions {
            let docID = try await h.document("wrong\(i).pdf")
            await h.learner.correctionRecorded(CorrectionEvent(documentID: docID, source: .finderMove, fromFolderID: folder.id,
                                                               toFolderID: other.id, proposed: proposed), trace: .disabled)
        }
        #expect(try await h.store.rules().first { $0.id == induced.id }?.enabled == false)

        for i in 0..<20 {
            try await h.fileConfirmed(Fixtures.content("edp_again_\(i).pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        }
        let revived = try #require(try await h.store.rules().first { $0.id == induced.id })
        #expect(revived.enabled, "consistent filings must be able to bring an automatically disabled rule back")
        #expect(revived.reliability >= h.env.config.learning.ruleReenableReliability)
    }

    @Test func approvingWhereARuleAlreadyPointedIsNotADisagreement() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home")
        let review = try await h.env.folder("Needs review", area: "System")
        let rule = try await h.store.saveRule(FilingRule(name: "EDP → Utilities", priority: 50, origin: .induced,
                                                         predicates: [.filenameGlob("*.pdf")],
                                                         action: RuleAction(folderID: folder.id, folderCode: folder.code), support: 3))
        let proposed = FilingDecision(folderCode: folder.code, title: "t",
                                      confidence: ConfidenceReport(ruleHit: rule.id, final: 1, band: .auto, thresholds: h.settings.thresholds),
                                      decidedBy: .rule, rationale: "rule")
        // Approving a held document moves it out of Needs review into the folder the rule already pointed at.
        for i in 0..<3 {
            let docID = try await h.document("approved\(i).pdf")
            await h.learner.correctionRecorded(CorrectionEvent(documentID: docID, source: .reviewApprove, fromFolderID: review.id,
                                                               toFolderID: folder.id, proposed: proposed), trace: .disabled)
        }
        let after = try #require(try await h.store.rules().first { $0.id == rule.id })
        #expect(after.contradictions == 0, "agreeing with a rule must not count against it")
        #expect(after.enabled)
    }

    @Test func filingsLeftUntouchedEventuallyTeachTheApp() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true)
        let nif = StableKey(kind: .ptNIF, value: "503504564")
        for i in 0..<h.env.config.learning.ruleMinSupport {
            try await h.fileUnconfirmed(Fixtures.content("edp_\(i).pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        }
        #expect(try await h.store.rules().isEmpty, "uncertain filings are not evidence on their own")

        try await h.ageMemories(byDays: h.env.config.learning.settleUnconfirmedAfterDays + 1)
        await h.learner.settleUntouchedFilings()

        let rules = try await h.store.rules()
        #expect(rules.contains { $0.origin == .induced && $0.action.folderCode == folder.code },
                "filings the user never moved must eventually form a rule")
    }

    @Test func whatWasLearnedIsRecordedAgainstTheDocumentItCameFrom() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true)
        let nif = StableKey(kind: .ptNIF, value: "503504564")
        for i in 0..<h.env.config.learning.ruleMinSupport {
            try await h.fileConfirmed(Fixtures.content("edp_\(i).pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        }
        let history = HistoryStore(database: h.env.database)
        let learned = try await history.events(limit: 100, kinds: [.learned])
        #expect(learned.count == h.env.config.learning.ruleMinSupport)
        #expect(learned.allSatisfy { $0.docId != nil && $0.summary.hasSuffix("Home / Utilities (you confirmed it)") })
        let rule = try #require(try await history.events(limit: 10, kinds: [.ruleInduced]).first)
        #expect(rule.docId == learned.first?.docId, "the filing that formed the rule is the one it is recorded against")

        let forgotten = try #require(learned.first?.docId)
        await h.learner.documentForgotten(documentID: forgotten)
        let latest = try await history.events(limit: 1, kinds: [.forgot], docID: forgotten)
        #expect(latest.first?.summary == "Forgot where this was filed", "forgetting is recorded as forgetting, not as a lesson")
    }
}
