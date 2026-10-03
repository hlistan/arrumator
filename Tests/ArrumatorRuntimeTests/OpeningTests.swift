@testable import ArrumatorCore
@testable import ArrumatorRuntime
import ArrumatorTesting
import Foundation
import Testing

/// Opening an archive whose index is to be rebuilt (docs/storage.md): the runtime works on no index that has not been
/// rebuilt from its archive, whoever starts it.
@Suite struct OpeningTests {
    @Test func anIndexWhoseRebuildWasRefusedStartsNothingUntilItIsRebuilt() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        // The archive's list of documents, broken by hand, read by a new index.
        let listing = try home.writeList(TestRecordFiles.brokenList, in: home.folder("First"))

        let refused = try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: home.environment, echoLogsToStderr: false, resolver: StubResolver(), trash: home.trash)
        await #expect(throws: RecordsError.self, "the index cannot be rebuilt without the list") { try await refused.openArchive() }
        #expect(await refused.start() == false, "and the app, which starts it all the same, starts nothing on it")
        #expect(try await refused.services.history.events(limit: 10).isEmpty, "not even to record that it started")

        // The user corrects the list, and rebuilds the index from Settings › Advanced.
        try TestRecordFiles.emptyList.write(to: listing, atomically: true, encoding: .utf8)
        try await refused.rebuildIndex()
        let kinds = try await refused.services.history.events(limit: 10).map(\.kind)
        #expect(kinds.contains(.rebuilt) && kinds.contains(.appStarted), "the index is rebuilt and the work on it starts, as History says: \(kinds)")
        try await refused.rebuildIndex()
        let started = try await refused.services.history.events(limit: 10, kinds: [.appStarted])
        #expect(started.count == 1, "and a rebuild while it runs does not start it twice")
        await refused.stop()
    }

    @Test func theAppIsToldWhetherTheWorkRunsNotThatItWasAskedToStart() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        let listing = try home.writeList(TestRecordFiles.brokenList, in: home.folder("First"))
        let runtime = try await home.bootstrap()
        let follower = WorkFollower()
        let updates = await runtime.workUpdates()
        let following = Task { for await work in updates { await follower.add(work) } }
        defer { following.cancel() }
        #expect(await Patience.until { await follower.received == [.idle] }, "before the archive is opened, nothing runs")

        await #expect(throws: RecordsError.self, "the archive cannot be read, so its index is not rebuilt") { try await runtime.openAndStart() }
        #expect(await Patience.until { await follower.received.last == .refused },
                "and a subscriber, as the app is one, is told the work was refused, not that it runs")
        try TestRecordFiles.emptyList.write(to: listing, atomically: true, encoding: .utf8)
        try await runtime.rebuildIndex()
        #expect(await Patience.until { await follower.received.last == .running }, "once the index is rebuilt, the work runs, and it is told so")
        await runtime.stop()
        #expect(await Patience.until { await follower.received.last == .idle }, "and that nothing runs once it stopped")
    }

    @Test func aRebuildStartsNothingTheAppHasNotStartedOrHasStopped() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        let runtime = try await ArrumatorRuntime.bootstrap(appVersion: "test", environment: home.environment, echoLogsToStderr: false, resolver: StubResolver(), trash: home.trash)
        try await runtime.openArchive()
        func started() async throws -> Int { try await runtime.services.history.events(limit: 10, kinds: [.appStarted]).count }
        // As before onboarding is done: the archive is open, and the app has started nothing on it.
        try await runtime.rebuildIndex()
        #expect(try await started() == 0, "a rebuild starts no work the app has not started")
        let began = await runtime.start()
        let afterStart = try await started()
        #expect(began && afterStart == 1, "the work starts when the app starts it")
        await runtime.stop()
        try await runtime.rebuildIndex()
        let again = await runtime.start()
        let afterStop = try await started()
        #expect(afterStop == 1 && !again, "and a rebuild after it stopped starts nothing again, nor does anything else")
    }

    @Test func aNewArchiveRecordsWhatTheUserChangesBeforeItIsOpenedOnceItIs() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        // As at onboarding: the index is made when the app starts, and the archive is opened once onboarding is done.
        let runtime = try await home.bootstrap()
        try await runtime.settingsActions.change(TestSettingChange.make)
        try await runtime.openArchive()
        let changes = try await runtime.services.history.events(limit: 10, kinds: [.settingsChanged])
        #expect(changes.count == 1, "an archive with no records has nothing to read, so its index takes the change's event once it is opened")
        #expect(try await runtime.services.history.events(limit: 10, kinds: [.rebuilt]).isEmpty, "with no rebuild from nothing")
    }

    /// A runtime open on an archive with one document filed and embedded by the embedding model of the profile in use,
    /// and the document.
    private func archiveWithAVector(_ home: RuntimeHome) async throws -> (ArrumatorRuntime, Int64) {
        let first = try await home.open()
        var bill = DocumentRecord.arrived(path: home.folder("First").appendingPathComponent("bill.pdf").path, sha256: "bill", size: 1,
                                          uttype: "com.adobe.pdf", inode: nil, modified: nil, now: first.time.now())
        bill.status = .filed
        let id = try #require(try await first.services.documents.save(bill).id)
        let model = try await first.settings.current.modelProfile().embedModel
        try await first.services.index.upsertEmbedding(docID: id, model: model, vector: [1, 0], sourceText: "bill")
        return (first, id)
    }

    @Test func anArchiveOpenedByACommandReadsItsVectorsOnlyToCompareByMeaning() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let (first, id) = try await archiveWithAVector(home)
        let model = try await first.settings.current.modelProfile().embedModel

        // What every command does first; one that asks a question, as `tasks ask` does, then compares by meaning.
        let command = try await home.open()
        #expect(await command.vectors.model == nil, "opening the archive reads no vectors")
        try await command.search.loadVectors()
        #expect(try await command.vectors.topK([1, 0], model: model, k: 5).map(\.docID) == [id],
                "a comparison by meaning reads those of the archive's documents, by the embedding model of the profile in use")
    }

    @Test func aRuntimeStartedWorksOutWhichLabelsLookAlikeBeforeTheAppAsks() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        let runtime = try await home.open()
        for (place, sender) in ["EDP Comercial", "EDP Comercail"].enumerated() {
            var bill = DocumentRecord.arrived(path: home.folder("First").appendingPathComponent("bill \(place).pdf").path, sha256: "bill \(place)",
                                              size: 1, uttype: "com.adobe.pdf", inode: nil, modified: nil, now: runtime.time.now())
            bill.status = .filed
            bill.labelsJson = try JSON.string([DocumentLabel(kind: .sender, value: sender)])
            _ = try await runtime.services.documents.save(bill)
        }
        await runtime.start()
        #expect(await Patience.until { runtime.services.lookAlikes.known(.sender)?.pairs.isEmpty == false },
                "once it has started, the runtime works out which labels look alike, so the app's first count finds it done")
        await runtime.stop()
    }

    @Test func aRuntimeStartedTellsTheAppHowManyLabelsLookAlikeAtEveryChangeWithoutBeingAsked() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        let runtime = try await home.open()
        var ids: [Int64] = []
        for (place, sender) in ["EDP Comercial", "EDP Comercail"].enumerated() {
            var bill = DocumentRecord.arrived(path: home.folder("First").appendingPathComponent("bill \(place).pdf").path, sha256: "bill \(place)",
                                              size: 1, uttype: "com.adobe.pdf", inode: nil, modified: nil, now: runtime.time.now())
            bill.status = .filed
            bill.labelsJson = try JSON.string([DocumentLabel(kind: .sender, value: sender)])
            ids.append(try #require(try await runtime.services.documents.save(bill).id))
        }
        let counts = SuggestionCounts()
        let stream = runtime.services.lookAlikes.suggestionCounts()
        let following = Task { for await count in stream { await counts.add(count) } }
        defer { following.cancel() }
        await runtime.start()
        #expect(await Patience.until { await counts.received.last == 1 }, "once started, it says how many pairs look alike, unasked")
        // The user gives a third sender written alike, which History records.
        try await runtime.review.edit(ids[0], fileName: nil, labels: LabelEdit(adding: [DocumentLabel(kind: .sender, value: "EDP Comerciall")]))
        #expect(await Patience.until { (await counts.received.last ?? 0) > 1 },
                "and at the change, says how many there are now, without the app asking")
        await runtime.stop()
    }

    @Test func anArchiveWhoseVectorsCannotBeReadIsOpenedAndSearchedByWords() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let (first, id) = try await archiveWithAVector(home)
        try await first.database.writer.write { try $0.execute(sql: "DROP TABLE embeddings") }

        let command = try await home.open()
        let ordered = try await command.search.relevance(of: "the electricity bill", among: [id])
        #expect(!ordered.semanticUsed && ordered.semanticUnavailableReason?.isEmpty == false,
                "every command opens the archive, and a question is ordered by its words, saying why")
    }

    @Test func recordsThatArriveBeforeTheArchiveIsOpenedAreRebuiltFrom() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        // The app makes the index when the archive shows no records yet, as on a new Mac whose archive still syncs.
        let runtime = try await home.bootstrap()
        try await runtime.settingsActions.change(TestSettingChange.make)
        // The archive's records arrive before onboarding opens it.
        try home.writeList(TestRecordFiles.emptyList, in: home.folder("First"))
        let scan = home.folder("First").appendingPathComponent(Self.note)
        try Data(Self.note.utf8).write(to: scan)
        try await runtime.openArchive()
        #expect(try await runtime.services.history.events(limit: 10, kinds: [.rebuilt]).count == 1, "the archive is rebuilt from when it is opened")
        let adopted = try await runtime.services.jobs.active(kinds: [.adopt]).map(\.sourcePath)
        #expect(adopted == [scan.path], "taking in the file its records do not list")
        let changes = try await runtime.services.history.events(limit: 10, kinds: [.settingsChanged]).map(\.summary)
        #expect(changes == [TestSettingChange.summary], "and the change made meanwhile is recorded, once")
    }

    @Test func aSwitchAwayWhileAnArchiveIsFirstRebuiltLetsItsRebuildRunWhenItIsOpenedAgain() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        let first = try await home.open()
        try await first.services.history.record(.paused, summary: Self.inTheFirst)
        try await first.records.flush()
        // The archive is moved, with a file put into it by hand: a folder its index has never read.
        try FileManager.default.copyItem(at: home.folder("First"), to: home.folder("Moved"))
        let note = home.folder("Moved").appendingPathComponent(Self.note)
        try Data(Self.note.utf8).write(to: note)
        let moved = try await first.switchArchive(to: home.folder("Moved").path).runtime
        let (reading, stopped, read) = (Signal(), Signal(), OneShot<Void>())
        // Its first reading is held, as macOS holds a folder behind its prompt for access, and the user switches away.
        let opening = Task {
            try await moved.openAndStart {
                reading.fire()
                await withTaskCancellationHandler { await read.wait() } onCancel: { stopped.fire() }
            }
        }
        try #require(await Patience.until { reading.fired }, "the app reads the moved archive")
        let switching = Task { try await moved.switchArchive(to: home.folder("Second").path) }
        try #require(await Patience.until { stopped.fired }, "the switch stops the reading")
        read.fire(())
        await #expect(throws: CancellationError.self, "the reading the switch stopped started nothing") { try await opening.value }
        let second = try await switching.value.runtime
        try await second.openArchive()

        let back = try await second.switchArchive(to: home.folder("Moved").path).runtime
        try await back.openArchive()
        let adopted = try await back.services.jobs.active(kinds: [.adopt]).map(\.sourcePath)
        #expect(adopted == [note.path], "its index is rebuilt when it is opened again, taking in the file put there by hand")
        #expect(try await back.services.history.events(limit: 50, kinds: [.rebuilt]).count == 1, "once")
        #expect(try await back.services.history.events(limit: 50, kinds: [.paused]).map(\.summary) == [Self.inTheFirst],
                "with the history its record files hold")
    }

    static let inTheFirst = "In the first archive"
    static let note = "note.txt"

    @Test func aSettingChangedBeforeAnArchiveWithRecordsIsOpenedIsMadeAndRecordedOnceItIs() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        // As at onboarding after the app was installed again: the archive holds records, its index is made when the app
        // starts, and the archive is opened once onboarding is done.
        try home.writeList(TestRecordFiles.emptyList, in: home.folder("First"))
        let runtime = try await home.bootstrap()
        var expected = await runtime.settings.current
        TestSettingChange.make(&expected)
        let changed = try await runtime.settingsActions.change(TestSettingChange.make)
        #expect(changed == expected, "the setting is changed, not refused as the index is not rebuilt yet")
        try await runtime.openArchive()
        let changes = try await runtime.services.history.events(limit: 10, kinds: [.settingsChanged]).map(\.summary)
        #expect(changes == [TestSettingChange.summary], "and recorded in History once the archive is opened, once")
    }

    @Test func anArchiveWhoseRebuildWasRefusedCanStillBeLeftAndRecordsItOnceItIsRebuilt() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let listing = try home.writeList(TestRecordFiles.brokenList, in: home.folder("First"))
        let refused = try await home.bootstrap()
        await #expect(throws: RecordsError.self) { try await refused.openArchive() }
        let next = try await refused.switchArchive(to: home.folder("Second").path).runtime
        try await next.openArchive()
        let chosen = await next.settings.current.archiveURL
        #expect(next.archive == home.folder("Second") && chosen == home.folder("Second"), "the user can switch to another archive")

        // The user corrects the list and goes back to the archive, whose index is then rebuilt.
        try TestRecordFiles.emptyList.write(to: listing, atomically: true, encoding: .utf8)
        let back = try await next.switchArchive(to: home.folder("First").path).runtime
        try await back.openArchive()
        let recorded = try await back.services.history.events(limit: 10, kinds: [.settingsChanged]).map(\.summary)
        #expect(recorded == ["Switched to the archive at \(home.folder("Second").path)"],
                "the switch away from it, held while it was not rebuilt, is in its history once it is")
    }
}
