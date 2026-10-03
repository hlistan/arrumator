@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// Whether a new index holds all its archive has to give is decided once, when the archive is opened, by walking it
/// whole (`ArchiveRecords.rebuildIfPending`), never when the index is made, when the archive may not show its records
/// yet: a sync still under way on a new Mac, a folder macOS has not let the app read. An index whose rebuild was refused
/// is never taken for complete but by a rebuild (docs/storage.md, Rebuilding).
@Suite struct IndexCompletenessTests {
    /// The index of the archive at `url`, opened as the app opens it when the archive looks as `holdsRecords` says.
    private func open(_ url: URL, _ env: TestEnvironment, holdsRecords: Bool) throws -> AppDatabase {
        try AppDatabase.open(at: url, config: env.config.database, setAsideSuffix: env.config.records.setAsideSuffix, time: env.time) {
            holdsRecords
        }.0
    }

    @Test func recordsTheArchiveShowsOnlyOnceItsIndexIsMadeAreRebuiltFromWithWhatWasChangedMeanwhile() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let archived = try await HistoryStore(database: w.h.env.database, time: w.h.env.time).events(limit: 100).map(\.summary)
        // The app makes the index when the archive shows no records yet, and the user changes a setting during onboarding.
        let database = try open(w.h.env.root.appendingPathComponent("Indexes/late.sqlite"), w.h.env, holdsRecords: false)
        try await HistoryStore(database: database, time: w.h.env.time).record(.settingsChanged, actor: .user, summary: TestSettingChange.summary)

        let summary = try #require(try await w.h.env.records(index: database).rebuildIfPending(),
                                   "the archive, which shows its records when it is opened, is rebuilt from")
        let queued = try await JobStore(database: database, time: w.h.env.time).active(kinds: [.reindex]).compactMap(\.docId).sorted()
        #expect(summary.documents == w.documents.count && queued == w.documents, "with every document, each queued to be read again")
        let events = try await HistoryStore(database: database, time: w.h.env.time).events(limit: 100).map(\.summary)
        #expect(Set(archived).isSubset(of: Set(events)), "the archive's history comes whole, none of it taken for the index's own")
        #expect(events.filter { $0 == TestSettingChange.summary }.count == 1, "and the change made meanwhile is recorded beside it, once")
    }

    @Test func anIndexAnotherProcessFoundCompleteMeanwhileIsNotRebuiltAgain() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        let url = env.root.appendingPathComponent("Indexes/shared.sqlite")
        let (app, command) = (try open(url, env, holdsRecords: false), try open(url, env, holdsRecords: false))
        // The app has walked the archive and found nothing to read; a command completes the index before the app does.
        #expect(try await env.records(index: command).rebuildIfPending() == nil, "the command finds the archive without records")
        #expect(try await env.records(index: app).completeAsEmpty(), "the app finds its index complete, as the command left it")
        #expect(try await HistoryStore(database: app, time: env.time).events(limit: 10, kinds: [.rebuilt]).isEmpty,
                "and rebuilds it no second time")
    }

    @Test func anIndexWhoseRebuildWasRefusedStaysToBeRebuiltHoweverTheArchiveLooksWhenItIsOpenedAgain() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        try TestRecordFiles.broken(try String(contentsOf: w.topListing, encoding: .utf8)).write(to: w.topListing, atomically: true, encoding: .utf8)
        let url = w.h.env.root.appendingPathComponent("Indexes/refused.sqlite")
        let refused = try open(url, w.h.env, holdsRecords: true)
        await #expect(throws: RecordsError.self, "the list cannot be read, so the index is not rebuilt") {
            try await w.h.env.records(index: refused).rebuildIfPending()
        }
        // The app opens it again, as the next time it starts, while the archive shows nothing of its records.
        let again = try open(url, w.h.env, holdsRecords: false)
        #expect(try await again.pendingRebuild() == .unread, "it is still to be rebuilt, not taken for an index of an archive without records")
        await #expect(throws: RecordsError.self, "and is rebuilt from nothing but the whole archive") {
            try await w.h.env.records(index: again).rebuildIfPending()
        }
    }

    @Test func anIndexWhoseRebuildWasRefusedIsRebuiltOnceTheFileIsMovedOutTakingInWhatItListed() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let scan = try env.put(Self.scan, text: Self.scan)
        let listing = try env.put(env.config.records.documentsFileName, text: TestRecordFiles.brokenList)
        let database = try open(env.root.appendingPathComponent("Indexes/refused.sqlite"), env, holdsRecords: true)
        let records = env.records(index: database)
        await #expect(throws: RecordsError.self, "the list cannot be read") { try await records.rebuildIfPending() }

        // As the error says to: the user moves the list out of the archive, which then holds no record file.
        try FileManager.default.moveItem(at: listing, to: env.root.appendingPathComponent(env.config.records.documentsFileName))
        let summary = try #require(try await records.rebuildIfPending(), "the index is rebuilt, not taken for complete as an empty archive's")
        let adopted = try await JobStore(database: database, time: env.time).active(kinds: [.adopt]).map(\.sourcePath)
        #expect(summary.adopted == 1 && adopted == [scan.path], "taking in the file the list described, to be read again")
    }

    static let scan = "scan.txt"

    /// Moves the archive of `w` out of its place, as a disk that is not mounted or a cloud folder not connected takes
    /// it away; where it went, to put it back.
    private func takeAway(_ w: RecordsWorld) throws -> URL {
        let away = w.h.env.root.appendingPathComponent("Away", isDirectory: true)
        try FileManager.default.moveItem(at: w.h.env.archive, to: away)
        return away
    }

    /// Expects `rebuild` to be refused naming the archive's folder, as one that is not there.
    private func expectRefusedAsNotThere(_ w: RecordsWorld, _ comment: Comment, _ rebuild: () async throws -> RebuildSummary?) async {
        await #expect(comment) {
            _ = try await rebuild()
        } throws: { error in
            guard case let RecordsError.archiveNotThere(path) = error else { return false }
            return path == w.h.env.archive.standardizedFileURL.path
        }
    }

    @Test func anArchiveNotThereWhenItsNewIndexIsReadIsNotTakenForOneWithoutRecords() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let (database, records) = try w.newIndex()
        let away = try takeAway(w)
        await expectRefusedAsNotThere(w, "the folder that is not there is named, as what it holds is not known") {
            try await records.rebuildIfPending()
        }
        #expect(try await database.pendingRebuild() == .unread, "the index stays to be rebuilt")
        try await records.reconcile()
        try await records.flush()
        #expect(!FileManager.default.fileExists(atPath: w.h.env.archive.path), "and nothing is made where the archive was")

        try FileManager.default.moveItem(at: away, to: w.h.env.archive)
        let summary = try #require(try await records.rebuildIfPending(), "once it is back, the index is rebuilt from it")
        let queued = try await JobStore(database: database, time: w.h.env.time).active(kinds: [.reindex]).compactMap(\.docId).sorted()
        #expect(summary.documents == w.documents.count && queued == w.documents, "with every document, each queued to be read again")
    }

    @Test func anIndexRefusedBeforeIsNotRebuiltFromNothingWhileItsArchiveIsNotThere() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let good = try String(contentsOf: w.topListing, encoding: .utf8)
        try TestRecordFiles.broken(good).write(to: w.topListing, atomically: true, encoding: .utf8)
        let (database, records) = try w.newIndex()
        await #expect(throws: RecordsError.self, "the list cannot be read") { try await records.rebuildIfPending() }
        let away = try takeAway(w)
        await expectRefusedAsNotThere(w, "opened again while its archive is not there, it is refused again, naming the folder") {
            try await records.rebuildIfPending()
        }
        #expect(try await database.pendingRebuild() == .unread, "not rebuilt from nothing")
        #expect(!FileManager.default.fileExists(atPath: w.h.env.archive.path), "and nothing is made where the archive was")

        try FileManager.default.moveItem(at: away, to: w.h.env.archive)
        try good.write(to: w.topListing, atomically: true, encoding: .utf8)
        let summary = try #require(try await records.rebuildIfPending(), "once it is back and corrected, the index is rebuilt")
        #expect(summary.documents == w.documents.count, "with every document")
    }
}
