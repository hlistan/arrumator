@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

@Suite struct FilingClassifierTests {
    @Test func emptyArchiveModelProposesFirstFolderAndFileName() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: nil))
        defer { h.env.cleanup() }
        let sink = MemoryTraceSink()
        let outcome = try await h.classify(Fixtures.content("scan_0001.pdf", text: Fixtures.edpText),
                                           trace: TraceContext(traceID: 1, sink: sink))
        let d = outcome.decision
        #expect(d.folderCode == nil)
        #expect(d.proposedNewFolder?.newAreaName == "Home" && d.proposedNewFolder?.name == "Utilities")
        #expect(d.proposedNewFolder?.description == "Electricity, gas and water bills.")
        #expect(d.proposedNewFolder?.yearSubfolders == true)
        #expect(d.fileName == "2026-07-05 EDP - Fatura eletricidade junho")
        #expect(d.decidedBy == .llm && d.documentType == .invoice && d.documentDate == "2026-07-05")
        let request = try #require(await h.mock.chatRequests.first)
        #expect(request.allText.contains("the archive is empty"))
        #expect(request.allText.contains("Findability first"))
        #expect(!request.allText.contains("{{"))
        let allowed = request.format?["properties"]?["folder_code"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(allowed == ["NEW"])
        #expect(Set(await sink.steps.map(\.stage)).isSuperset(of: [.correspondent, .embed, .rules, .candidates, .llm, .validate, .calibrate]))
    }

    @Test func modelSeesExistingFoldersWithTheirContext() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true, description: "Electricity, gas and water bills.")
        let outcome = try await h.classify(Fixtures.content("x.pdf", text: Fixtures.edpText))
        #expect(outcome.decision.folderCode == folder.code)
        let request = try #require(await h.mock.chatRequests.first)
        #expect(request.allText.contains("11 Utilities (in 10-19 Home)"))
        #expect(request.allText.contains("Split by year"))
    }

    @Test func invalidAnswersAreRepairedThenHeldForReview() async throws {
        let h = try await ClassifyHarness.make(handler: { _ in "not json" })
        defer { h.env.cleanup() }
        let outcome = try await h.classify(Fixtures.content("x.pdf", text: "Some unrelated text"))
        #expect(outcome.decision.folderCode == nil && outcome.decision.proposedNewFolder == nil)
        #expect(outcome.decision.band == .review)
        #expect(await h.mock.chatCount == (h.env.config.classification.repairAttempts + 1) * 2)
    }

    @Test func usageFormsARuleAndConfidentRulesSkipTheModel() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
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
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
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

    @Test func modelChoosingAnUnrelatedExistingFolderGetsTheIdealOneInstead() async throws {
        let h = try await ClassifyHarness.make(handler: { request in
            let allowed = request.format?["properties"]?["folder_code"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return Fixtures.answer(folder: allowed.first ?? "NEW", idealArea: "Money and Taxes", idealCategory: "Taxes Portugal",
                                   idealDescription: "IRS declarations and tax assessments from the Portuguese tax authority.",
                                   yearly: "yes")
        })
        defer { h.env.cleanup() }
        _ = try await h.env.folder("Utilities", area: "Home")
        let outcome = try await h.classify(Fixtures.content("irs.pdf", text: "Declaração Modelo 3 IRS rendimentos 2025"))
        #expect(outcome.decision.folderCode == nil)
        #expect(outcome.decision.proposedNewFolder?.name == "Taxes Portugal")
    }

    @Test func aTopicInTheWrongAreaMovesToTheIdealArea() async throws {
        let h = try await ClassifyHarness.make(handler: { request in
            let allowed = request.format?["properties"]?["folder_code"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return Fixtures.answer(folder: allowed.first ?? "NEW", idealArea: "Work", idealCategory: "Payslips",
                                   idealDescription: "Monthly salary statements.", yearly: "yes")
        })
        defer { h.env.cleanup() }
        let misplaced = try await h.env.folder("Payslips", area: "Home")
        let outcome = try await h.classify(Fixtures.content("payslip.pdf", text: "Acme Ltd payslip August 2026 net pay"))
        #expect(outcome.decision.folderCode == nil, "\(misplaced.code) Payslips is in the wrong part of the archive")
        #expect(outcome.decision.proposedNewFolder?.name == "Payslips" && outcome.decision.proposedNewFolder?.newAreaName == "Work")
    }

    @Test func sharedIdentifiersNeverIdentifyACorrespondent() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
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
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
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
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
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
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
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
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
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
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
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
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
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
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(code: "11"))
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true)
        let nif = StableKey(kind: .ptNIF, value: "503504564")
        for i in 0..<h.env.config.learning.ruleMinSupport {
            try await h.fileConfirmed(Fixtures.content("edp_\(i).pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        }
        let history = HistoryStore(database: h.env.database)
        let learned = try await history.events(limit: 100, kinds: [.learned])
        #expect(learned.count == h.env.config.learning.ruleMinSupport)
        #expect(learned.allSatisfy { $0.docId != nil && $0.summary.hasSuffix("\(folder.code) Utilities (you confirmed it)") })
        let rule = try #require(try await history.events(limit: 10, kinds: [.ruleInduced]).first)
        #expect(rule.docId == learned.first?.docId, "the filing that formed the rule is the one it is recorded against")

        let forgotten = try #require(learned.first?.docId)
        await h.learner.documentForgotten(documentID: forgotten)
        let latest = try await history.events(limit: 1, kinds: [.forgot], docID: forgotten)
        #expect(latest.first?.summary == "Forgot where this was filed", "forgetting is recorded as forgetting, not as a lesson")
    }
}
