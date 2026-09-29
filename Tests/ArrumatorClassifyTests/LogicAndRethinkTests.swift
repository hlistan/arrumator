import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

@Suite struct LogicAndRethinkTests {
    @Test func theModelFollowsTheArchivesLogic() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        _ = try await h.classify(Fixtures.content("a.pdf", text: Fixtures.edpText))
        var request = try #require(await h.mock.chatRequests.last(where: Fixtures.isDecision))
        #expect(request.allText.contains("## LOGIC") && request.allText.contains("Findability first"), "an archive starts with the built-in logic")

        try await h.logic.update(body: "Everything about the car goes under Vehicles, named in {{folder_language}}.")
        _ = try await h.classify(Fixtures.content("b.pdf", text: Fixtures.edpText))
        request = try #require(await h.mock.chatRequests.last(where: Fixtures.isDecision))
        #expect(!request.allText.contains("Findability first"))
        #expect(request.allText.contains("Everything about the car goes under Vehicles, named in \(h.settings.folderNamingLanguage)."))
    }

    @Test func rethinkingAsksTheModelAndLeavesTheDocumentsOwnFilingOut() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering(path: ["Home", "Energy"]))
        defer { h.env.cleanup() }
        let folder = try await h.env.folder("Utilities", area: "Home", yearly: true)
        let nif = StableKey(kind: .ptNIF, value: "503504564")
        for i in 0..<h.env.config.learning.ruleMinSupport {
            try await h.fileConfirmed(Fixtures.content("edp_\(i).pdf", text: Fixtures.edpText, keys: [nif]), into: folder)
        }
        let content = Fixtures.content("edp_0.pdf", text: Fixtures.edpText, keys: [nif])
        let before = await h.mock.chatCount
        let arrival = try await h.classify(content)
        let after = await h.mock.chatCount
        #expect(arrival.decision.decidedBy != .llm && after == before + 1,
                "a new arrival is still placed by what was learned; the model only names it")

        let memories = try await h.store.memories(model: "bge-m3")
        let own = try #require(memories.first { $0.summaryLine.hasPrefix("edp_0.pdf") })
        let sink = MemoryTraceSink()
        let rethought = try await h.classify(content, mode: .rethink(documentID: own.documentID), trace: TraceContext(traceID: 2, sink: sink))
        #expect(rethought.decision.decidedBy == .llm, "rethinking decides again by the logic, whatever the rules say")
        let request = try #require(await h.mock.chatRequests.last(where: Fixtures.isDecision))
        #expect(!request.allText.contains("edp_1.pdf") && !request.allText.contains("A learned rule"),
                "what was learned under the old arrangement never shapes the path the logic decides")
        #expect(request.allText.contains("KNOWN CORRESPONDENTS FOUND: EDP Comercial (by stableKey)")
                && request.allText.contains("If KNOWN CORRESPONDENTS FOUND names one that matches"), "who it is from is still known")
        let candidates = try #require(await sink.steps.first { $0.stage == .candidates }?.output)
        let voters = try #require(try JSONSerialization.jsonObject(with: Data(candidates.utf8)) as? [String: Any])["neighbors"] as? [[String: Any]]
        let ids = Set((voters ?? []).compactMap { $0["id"] as? Int64 })
        #expect(!ids.isEmpty && !ids.contains(own.id), "its own past filing would only repeat the old placement")
    }

    @Test func rulesFollowTheirDocumentsWhenPlacementIsRethought() async throws {
        let h = try await ClassifyHarness.make(handler: Fixtures.answering())
        defer { h.env.cleanup() }
        let utilities = try await h.env.folder("Utilities", area: "Home")
        let energy = try await h.env.folder("Energy", area: "Home")
        let misc = try await h.env.folder("Misc Bills", area: "Home")
        let edp = try await h.store.saveCorrespondent(Correspondent(canonicalName: "EDP", origin: .learned))
        let meo = try await h.store.saveCorrespondent(Correspondent(canonicalName: "MEO", origin: .learned))
        let follows = try await h.store.saveRule(FilingRule(
            name: "EDP → Home / Utilities", priority: 50, origin: .induced, predicates: [.correspondent(id: edp.id)],
            action: RuleAction(folderID: utilities.id, folderCode: utilities.code), support: 3))
        let scattered = try await h.store.saveRule(FilingRule(
            name: "MEO → Home / Misc Bills", priority: 50, origin: .induced, predicates: [.correspondent(id: meo.id)],
            action: RuleAction(folderID: misc.id, folderCode: misc.code), support: 3))
        let moves = (1...3).map {
            PlacementMove(documentID: Int64($0), fromFolderID: utilities.id, toFolderID: energy.id, correspondentID: edp.id,
                          documentType: .invoice)
        } + [PlacementMove(documentID: 4, fromFolderID: misc.id, toFolderID: utilities.id, correspondentID: meo.id, documentType: .invoice),
             PlacementMove(documentID: 5, fromFolderID: misc.id, toFolderID: energy.id, correspondentID: meo.id, documentType: .invoice)]

        await h.learner.placementsRearranged(moves, removedFolderIDs: [misc.id])

        let rules = try await h.store.rules()
        let followed = try #require(rules.first { $0.id == follows.id })
        #expect(followed.action.folderID == energy.id && followed.name == "EDP → Home / Energy", "a rule names its folder by path")
        #expect(rules.first { $0.id == scattered.id }?.enabled == false, "documents that scattered leave their rule without a home")
        let kinds = try await HistoryStore(database: h.env.database).events(limit: 10).map(\.kind)
        #expect(kinds.contains(.ruleChanged) && kinds.contains(.ruleDisabled))
    }
}
