import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// Files by what the text says. On arrival, EDP bills go to "Old Bills" and everything else to "Utilities". When
/// rethinking, EDP bills belong in a new "Energy" folder, water bills stay in "Utilities", anything "unclear" is an
/// unsure decision with no suggestion, and a "maybe energy" bill is an unsure decision that suggests "Energy"; the
/// model also words every file name differently.
struct ScriptedClassifier: DocumentClassifier {
    func classify(_ content: ExtractedContent, taxonomy: TaxonomySnapshot, settings: AppSettings, config: PipelineConfig,
                  mode: ClassificationMode, trace: TraceContext) async throws -> ClassificationOutcome {
        let text = content.text
        let home = taxonomy.areas.first { $0.name == "Home" }
        func folder(_ name: String) -> (String?, FolderSpec?) {
            if let code = taxonomy.folders.first(where: { $0.kind == .category && $0.name == name })?.code { return (code, nil) }
            return (nil, FolderSpec(areaCode: home?.code, newAreaName: home == nil ? "Home" : nil, newAreaDescription: "Home documents.",
                                    name: name, description: "\(name) documents.", yearSubfolders: false, yearRule: nil))
        }
        var band = Band.auto
        let target: (String?, FolderSpec?)
        switch mode {
        case .arrival:
            target = folder(text.contains("EDP") ? "Old Bills" : "Utilities")
        case .rethink:
            if text.contains("unclear") {
                band = .review
                target = (nil, nil)
            } else if text.contains("maybe energy") {
                band = .review
                target = folder("Energy")
            } else {
                target = folder(text.contains("EDP") ? "Energy" : "Utilities")
            }
        }
        let final = band == .auto ? 0.95 : 0.2
        return ClassificationOutcome(decision: FilingDecision(
            folderCode: target.0, proposedNewFolder: target.1, correspondent: "EDP", documentType: .invoice, documentDate: "2026-07-05",
            dateSource: .label, title: "Bill", fileName: mode == .arrival ? content.source.stem : "Reworded \(content.source.stem)", language: "pt",
            confidence: ConfidenceReport(llm: final, final: final, band: band, thresholds: settings.thresholds),
            decidedBy: .llm, rationale: "scripted"), embedding: nil, embeddingModel: nil)
    }

    func embedding(for content: ExtractedContent, sender: String?, settings: AppSettings, config: PipelineConfig,
                   trace: TraceContext) async throws -> (vector: [Float], model: String)? { nil }
}

/// Answers as `ScriptedClassifier` does, except that rethinking a "slow" document keeps the model thinking for a long
/// time, as a real one can: long enough for the user to stop planning meanwhile.
struct HesitantClassifier: DocumentClassifier {
    static let thinking: Duration = .seconds(30)

    func classify(_ content: ExtractedContent, taxonomy: TaxonomySnapshot, settings: AppSettings, config: PipelineConfig,
                  mode: ClassificationMode, trace: TraceContext) async throws -> ClassificationOutcome {
        if case .rethink = mode, content.text.contains("slow") { try await Task.sleep(for: Self.thinking) }
        return try await ScriptedClassifier().classify(content, taxonomy: taxonomy, settings: settings, config: config, mode: mode,
                                                       trace: trace)
    }

    func embedding(for content: ExtractedContent, sender: String?, settings: AppSettings, config: PipelineConfig,
                   trace: TraceContext) async throws -> (vector: [Float], model: String)? { nil }
}

@Suite struct RethinkTests {
    /// Files each text as a new arrival and returns the document ids in order.
    private func arrive(_ h: Harness, _ files: [(String, String)]) async throws -> [Int64] {
        for (name, text) in files { await h.coordinator.enqueue(try h.env.drop(name, text: text)) }
        await h.coordinator.drain()
        var ids: [Int64] = []
        for (name, _) in files {
            let filed = try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 100)
            ids.append(try #require(filed.first { $0.originalFilename == name }?.id))
        }
        return ids
    }

    private func folder(_ h: Harness, _ name: String) async throws -> TaxonomyFolder? {
        try await h.env.taxonomy.snapshot(root: h.env.archive).folders.first { $0.name == name }
    }

    /// Waits, briefly, until planning in the background has decided `count` documents.
    private func waitUntilDecided(_ count: Int, store: RethinkStore, runID: Int64) async throws {
        let deadline = Date().addingTimeInterval(10)
        while try await store.items(runID: runID).filter({ $0.status != .pending }).count < count {
            guard Date() < deadline else {
                Issue.record("planning never decided \(count) documents")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func planningCanBeStoppedAtAnyPointAndKeepsWhatWasDecided() async throws {
        let h = try await Harness.make(classifier: HesitantClassifier())
        defer { h.env.cleanup() }
        let ids = try await arrive(h, [("edp1.txt", "EDP one"), ("water.txt", "water bill"), ("slow.txt", "slow water bill"),
                                       ("edp2.txt", "EDP two")])
        let rethink = RethinkCoordinator(services: h.services, ingest: h.coordinator)
        let runID = try #require(try await rethink.begin(.all, includeUserPlaced: false).id)
        let store = RethinkStore(database: h.env.database)
        await rethink.start()
        try await waitUntilDecided(2, store: store, runID: runID)
        let decided = try await store.items(runID: runID).filter { $0.status != .pending }
        #expect(decided.map(\.docId) == [ids[0], ids[1]], "each decision is recorded as it is made, for the page to show")

        let started = Date()
        let stopped = try await rethink.stopPlanning()
        #expect(Date().timeIntervalSince(started) < 5, "the document the model is thinking about is interrupted, not waited for")
        #expect(stopped.status == .ready)
        #expect(stopped.summary?.hasPrefix("Stopped after deciding 2 of 4 documents") == true)
        let items = try await store.items(runID: runID)
        #expect(items.map(\.status) == [.move, .unchanged, .notDecided, .notDecided])
        var late = try #require(items.last)
        late.status = .move
        try await store.decide(late)
        #expect(try await store.item(id: try #require(late.id))?.status == .notDecided, "a decision arriving late changes nothing")

        #expect(try await rethink.apply().status == .applied)
        #expect(try await h.services.documents.document(id: ids[0])?.folderId == (try await folder(h, "Energy"))?.id)
        #expect(try await h.services.documents.document(id: ids[3])?.folderId == (try await folder(h, "Old Bills"))?.id,
                "documents not decided stay where they are")
        let events = try await HistoryStore(database: h.env.database).events(limit: 10, kinds: [.rethink])
        #expect(events.contains { $0.actor == .user && $0.summary.hasPrefix("Stopped after deciding") })
        await rethink.stop()
    }

    @Test func stoppingWithNothingThatWouldMoveFreesTheLogic() async throws {
        let h = try await Harness.make(classifier: HesitantClassifier())
        defer { h.env.cleanup() }
        _ = try await arrive(h, [("water.txt", "water bill"), ("slow.txt", "slow water bill"), ("edp.txt", "EDP one")])
        let rethink = RethinkCoordinator(services: h.services, ingest: h.coordinator)
        let runID = try #require(try await rethink.begin(.all, includeUserPlaced: false).id)
        let store = RethinkStore(database: h.env.database)
        await rethink.start()
        try await waitUntilDecided(1, store: store, runID: runID)
        let stopped = try await rethink.stopPlanning()
        let open = try await store.activeRun()
        #expect(stopped.status == .settled && open == nil, "nothing is left for the user to decide")
        let logic = LogicStore(database: h.env.database, maxChars: h.env.config.classification.logicMaxChars)
        try await logic.update(body: "Another way.")
        await #expect(throws: RethinkError.self, "only a plan still being made can be stopped") { try await rethink.stopPlanning() }
        await rethink.stop()
    }

    @Test func rethinkMovesDocumentsCreatesFoldersAndRemovesEmptyOnes() async throws {
        let h = try await Harness.make(classifier: ScriptedClassifier())
        defer { h.env.cleanup() }
        let ids = try await arrive(h, [("edp1.txt", "EDP electricity July"), ("edp2.txt", "EDP electricity August"),
                                       ("water.txt", "water bill"), ("odd.txt", "unclear letter")])
        let oldBills = try #require(try await folder(h, "Old Bills"))
        let oldBillsURL = try await h.env.taxonomy.snapshot(root: h.env.archive).url(for: oldBills)

        let rethink = RethinkCoordinator(services: h.services, ingest: h.coordinator)
        try await rethink.begin(.all, includeUserPlaced: false)
        try await rethink.planAll()
        let store = RethinkStore(database: h.env.database)
        let planned = try #require(try await store.activeRun())
        #expect(planned.status == .ready)
        #expect(planned.plannedFolders.map(\.name) == ["Energy"], "the second EDP bill reuses the folder planned for the first")
        let counts = try await store.counts(runID: try #require(planned.id))
        #expect(counts[.move] == 2 && counts[.unchanged] == 1 && counts[.unsure] == 1,
                "a document whose folder stays the same is unchanged, however the model words its name")
        #expect(try await folder(h, "Energy") == nil, "planning creates nothing on disk")

        let applied = try await rethink.apply()
        #expect(applied.status == .applied)
        let energy = try #require(try await folder(h, "Energy"))
        for (id, name) in zip(ids.prefix(2), ["edp1.txt", "edp2.txt"]) {
            let doc = try #require(try await h.services.documents.document(id: id))
            #expect(doc.folderId == energy.id && FileManager.default.fileExists(atPath: doc.path))
            #expect(doc.filename == name, "a moved document keeps its name")
        }
        let odd = try #require(try await h.services.documents.document(id: ids[3]))
        #expect(odd.folderId == (try await folder(h, "Utilities"))?.id, "an unsure decision leaves the document where it was")
        #expect(!FileManager.default.fileExists(atPath: oldBillsURL.path), "the emptied folder is removed")
        #expect(try await folder(h, "Old Bills") == nil)
        let kinds = try await h.services.history.events(limit: 100).map(\.kind)
        #expect(kinds.filter { $0 == .rethought }.count == 2 && kinds.contains(.folderRemoved))
        #expect(await h.learner.rearranged.map(\.documentID).sorted() == Array(ids.prefix(2)).sorted())
        #expect(await h.learner.removedFolders.contains(oldBills.id))
        #expect(try await store.activeRun() == nil)
    }

    @Test func rethinkLeavesConfirmedAndDeselectedDocumentsAlone() async throws {
        let h = try await Harness.make(classifier: ScriptedClassifier())
        defer { h.env.cleanup() }
        let ids = try await arrive(h, [("edp1.txt", "EDP one"), ("edp2.txt", "EDP two"), ("edp3.txt", "EDP three")])
        try await ReviewActions(services: h.services, coordinator: h.coordinator).markCorrect(ids[0])

        let rethink = RethinkCoordinator(services: h.services, ingest: h.coordinator)
        let run = try await rethink.begin(.all, includeUserPlaced: false)
        try await rethink.planAll()
        let store = RethinkStore(database: h.env.database)
        let items = try await store.items(runID: try #require(run.id))
        #expect(Set(items.map(\.docId)) == Set(ids.suffix(2)), "a document the user confirmed is not rethought")
        try await rethink.select(itemID: try #require(items.first { $0.docId == ids[2] }?.id), false)
        try await rethink.apply()

        let oldBills = try #require(try await folder(h, "Old Bills"), "still holds the documents that stayed")
        let energy = try #require(try await folder(h, "Energy"))
        #expect(try await h.services.documents.document(id: ids[0])?.folderId == oldBills.id)
        #expect(try await h.services.documents.document(id: ids[1])?.folderId == energy.id)
        #expect(try await h.services.documents.document(id: ids[2])?.folderId == oldBills.id)
        #expect(try await store.items(runID: try #require(run.id), statuses: [.skipped]).map(\.docId) == [ids[2]])
    }

    @Test func aTrialTakesAFewDocumentsFromEachFolder() async throws {
        let h = try await Harness.make(classifier: ScriptedClassifier())
        defer { h.env.cleanup() }
        let ids = try await arrive(h, [("edp1.txt", "EDP one"), ("edp2.txt", "EDP two"), ("edp3.txt", "EDP three"),
                                       ("water1.txt", "water one"), ("water2.txt", "water two")])
        var services = h.services
        services.config.rethink.trialSize = 3
        let rethink = RethinkCoordinator(services: services, ingest: h.coordinator)
        let run = try await rethink.begin(.trial, includeUserPlaced: false)
        #expect(run.scope == .trial)
        let picked = try await RethinkStore(database: h.env.database).items(runID: try #require(run.id)).map(\.docId)
        #expect(picked == [ids[2], ids[4], ids[1]], "the newest from each folder in turn")
    }

    @Test func anUnsureSuggestionIsOfferedUntickedAndMovesOnlyWhenPicked() async throws {
        let h = try await Harness.make(classifier: ScriptedClassifier())
        defer { h.env.cleanup() }
        let ids = try await arrive(h, [("water.txt", "water bill"), ("maybe.txt", "maybe energy bill")])
        let rethink = RethinkCoordinator(services: h.services, ingest: h.coordinator)
        let run = try await rethink.begin(.all, includeUserPlaced: false)
        try await rethink.planAll()
        let store = RethinkStore(database: h.env.database)
        #expect(try await store.activeRun()?.status == .ready, "a suggestion the user can take keeps the plan open")
        let items = try await store.items(runID: try #require(run.id))
        let maybe = try #require(items.first { $0.docId == ids[1] })
        #expect(maybe.status == .unsure && maybe.canMove && maybe.isUserChoice)
        #expect(!maybe.selected, "an unsure suggestion waits for the user to tick it")
        let planned = await rethink.progress
        #expect(planned.choices == 1 && planned.moves == 0)

        try await rethink.select(itemID: try #require(maybe.id), true)
        #expect(await rethink.progress.moves == 1)
        try await rethink.apply()
        let energy = try #require(try await folder(h, "Energy"))
        let moved = try #require(try await h.services.documents.document(id: ids[1]))
        #expect(moved.folderId == energy.id)
        #expect(moved.decision?.decidedBy == .user, "the user picked the place, so the decision is theirs")
        #expect(try await h.services.documents.document(id: ids[0])?.folderId == (try await folder(h, "Utilities"))?.id)
    }

    @Test func anUntickedSuggestionLeavesTheDocumentAndCreatesNoFolder() async throws {
        let h = try await Harness.make(classifier: ScriptedClassifier())
        defer { h.env.cleanup() }
        let ids = try await arrive(h, [("maybe.txt", "maybe energy bill")])
        let rethink = RethinkCoordinator(services: h.services, ingest: h.coordinator)
        try await rethink.begin(.all, includeUserPlaced: false)
        try await rethink.planAll()
        let applied = try await rethink.apply()
        #expect(applied.status == .applied)
        #expect(try await folder(h, "Energy") == nil, "a folder only an unticked suggestion needed is never created")
        #expect(try await h.services.documents.document(id: ids[0])?.folderId == (try await folder(h, "Utilities"))?.id)
    }

    @Test func aPlanWithNothingToChangeSettlesAndFreesTheLogic() async throws {
        let h = try await Harness.make(classifier: ScriptedClassifier())
        defer { h.env.cleanup() }
        _ = try await arrive(h, [("water.txt", "water bill"), ("odd.txt", "unclear letter")])
        let rethink = RethinkCoordinator(services: h.services, ingest: h.coordinator)
        let run = try await rethink.begin(.trial, includeUserPlaced: false)
        try await rethink.planAll()
        let store = RethinkStore(database: h.env.database)
        #expect(try await store.activeRun() == nil, "nothing to decide, so nothing waits for the user")
        let latest = try #require(try await store.latestRun())
        #expect(latest.id == run.id && latest.status == .settled)
        let logic = LogicStore(database: h.env.database, maxChars: h.env.config.classification.logicMaxChars)
        try await logic.update(body: "Another way.")
    }

    @Test func onlyDocumentsThatCanMoveCanBeTicked() async throws {
        let h = try await Harness.make(classifier: ScriptedClassifier())
        defer { h.env.cleanup() }
        let ids = try await arrive(h, [("water.txt", "water bill"), ("edp.txt", "EDP one"), ("odd.txt", "unclear letter")])
        let rethink = RethinkCoordinator(services: h.services, ingest: h.coordinator)
        let run = try await rethink.begin(.all, includeUserPlaced: false)
        try await rethink.planAll()
        let items = try await RethinkStore(database: h.env.database).items(runID: try #require(run.id))
        for id in [ids[0], ids[2]] {
            let item = try #require(items.first { $0.docId == id })
            await #expect(throws: RethinkError.self, "\(item.status) cannot be ticked") {
                try await rethink.select(itemID: try #require(item.id), true)
            }
        }
    }

    @Test func discardingMovesNothingAndAllowsANewRethink() async throws {
        let h = try await Harness.make(classifier: ScriptedClassifier())
        defer { h.env.cleanup() }
        let ids = try await arrive(h, [("edp1.txt", "EDP one")])
        let rethink = RethinkCoordinator(services: h.services, ingest: h.coordinator)
        try await rethink.begin(.all, includeUserPlaced: false)
        await #expect(throws: RethinkError.self) { try await rethink.begin(.all, includeUserPlaced: false) }
        let logic = LogicStore(database: h.env.database, maxChars: h.env.config.classification.logicMaxChars)
        await #expect(throws: LogicError.self, "a plan never mixes two kinds of logic") { try await logic.update(body: "Another way.") }
        try await rethink.planAll()
        try await rethink.discard()
        let oldBills = try #require(try await folder(h, "Old Bills"))
        #expect(try await h.services.documents.document(id: ids[0])?.folderId == oldBills.id)
        try await rethink.begin(.all, includeUserPlaced: true)
    }
}

@Suite struct EmptyFolderTests {
    @Test func onlyFoldersWithoutDocumentsAreRemoved() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let kept = try await env.folder("Utilities", area: "Home", yearly: true)
        let empty = try await env.folder("Old Bills", area: "Home", yearly: true)
        let lonely = try await env.folder("Passports", area: "Identity")
        _ = try await env.taxonomy.ensureSystemFolder(.needsReview, root: env.archive)
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        let keptURL = snapshot.url(for: kept)
        let emptyURL = snapshot.url(for: empty)
        let identityURL = emptyURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(snapshot.url(for: lonely).deletingLastPathComponent().lastPathComponent)
        let userFile = keptURL.appendingPathComponent("2026").appendingPathComponent("bill.pdf")
        try FileManager.default.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bill".utf8).write(to: userFile)
        try FileManager.default.createDirectory(at: keptURL.appendingPathComponent("2025"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyURL.appendingPathComponent("2024"), withIntermediateDirectories: true)
        try Data().write(to: emptyURL.appendingPathComponent(".DS_Store"))

        let removed = try await env.taxonomy.pruneEmpty(root: env.archive)

        #expect(Set(removed.map(\.name)) == ["Old Bills", "Passports", "Identity"])
        #expect(FileManager.default.fileExists(atPath: userFile.path), "a folder holding a file is never touched")
        #expect(!FileManager.default.fileExists(atPath: keptURL.appendingPathComponent("2025").path), "an empty year folder goes")
        #expect(!FileManager.default.fileExists(atPath: emptyURL.path))
        #expect(!FileManager.default.fileExists(atPath: identityURL.path), "an area left without folders goes too")
        let after = try await env.taxonomy.snapshot(root: env.archive)
        #expect(after.folder(role: .needsReview) != nil, "system folders stay")
        #expect(after.folder(id: kept.id) != nil && after.folder(id: empty.id) == nil)
        let archived = try await env.database.reader.read { db in try FolderRecord.fetchOne(db, key: empty.id) }
        #expect(archived?.isArchived == true && archived?.description == "Old Bills documents.", "its description is kept")
    }
}

@Suite struct LogicStoreTests {
    private let original = "Folders in {{folder_language}}."

    @Test func anArchiveStartsWithTheBuiltInLogicAndFollowsTheAppUntilEdited() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let store = LogicStore(database: env.database, maxChars: env.config.classification.logicMaxChars)
        #expect(try await store.current() == nil)
        try await store.sync(builtin: original + "\n")
        let builtin = try #require(try await store.current())
        #expect(builtin.followsBuiltin && builtin.body == original, "surrounding space is not part of the prompt")

        let newer = "Folders in {{folder_language}}, two levels."
        try await store.sync(builtin: newer)
        #expect(try await store.current()?.body == newer, "logic nobody changed follows the app")

        try await store.update(body: "My own rules.")
        try await store.sync(builtin: original)
        let edited = try #require(try await store.current())
        #expect(!edited.followsBuiltin && edited.body == "My own rules.", "edited logic keeps the user's prompt")

        try await store.update(body: newer)
        #expect(try await store.current()?.followsBuiltin == true, "edited back to the text it came from, it follows the app again")

        try await store.update(body: "Mine again.")
        let reset = try await store.reset(to: original)
        #expect(reset.followsBuiltin && reset.body == original)
        let rows = try await env.database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM logic") }
        #expect(rows == 1, "an archive has one logic")
        let events = try await HistoryStore(database: env.database).events(limit: 10, kinds: [.logicChanged])
        #expect(events.map(\.summary) == ["Logic reset to the original", "Logic edited", "Logic edited", "Logic edited",
                                           "Logic updated with this version of Arrumator"])
    }

    @Test func logicIsCheckedBeforeItIsSaved() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let store = LogicStore(database: env.database, maxChars: 60)
        try await store.sync(builtin: original)
        await #expect(throws: LogicError.self) { try await store.update(body: "Use {{folder_langauge}}.") }
        await #expect(throws: LogicError.self) { try await store.update(body: String(repeating: "x", count: 61)) }
        #expect(try await store.current()?.body == original, "logic that fails the check is not saved")
        let before = LogicStore.version(of: try await store.current())
        try await store.update(body: "Car papers go under Vehicles.")
        #expect(LogicStore.version(of: try await store.current()) != before, "every decision records which logic made it")
    }
}
