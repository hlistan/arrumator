import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What is recorded in History while the index holds nothing of its archive yet (`AppDatabase.PendingRebuild.unread`),
/// as when a setting is changed during onboarding before the archive is opened: the change is made, and its event is
/// held, apart from what the rebuild replaces, until the index holds the archive; then it is recorded once
/// (docs/storage.md, Rebuilding).
@Suite struct HeldEventsTests {
    /// The summaries of the events of `kind` in `database`, oldest first.
    private func summaries(_ kind: EventKind, in database: AppDatabase) async throws -> [String] {
        try await HistoryStore(database: database, time: TestTime(.advances)).events(limit: 100, kinds: [kind]).map(\.summary).reversed()
    }

    @Test func aSettingChangedBeforeTheIndexHoldsItsArchiveIsRecordedOnceItDoes() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let archived = try await summaries(.analysed, in: w.h.env.database)
        let (database, records) = try w.newIndex()
        let history = HistoryStore(database: database, time: w.h.env.time)
        try await history.record(.settingsChanged, actor: .user, summary: TestSettingChange.summary)
        #expect(try await summaries(.settingsChanged, in: database).isEmpty, "the event is held, not in the history the rebuild replaces")

        try #require(try await records.rebuildIfPending() != nil, "the index is rebuilt from the archive")
        #expect(try await summaries(.settingsChanged, in: database) == [TestSettingChange.summary], "and the event held is recorded once it holds it")
        #expect(try await summaries(.analysed, in: database) == archived, "beside the history the archive holds, which it takes nothing from")
        try await records.flush()
        let month = w.h.env.layout.historyFile(month: RecordKind.month(of: w.h.env.time.now()))
        #expect(try String(contentsOf: month, encoding: .utf8).contains(TestSettingChange.summary), "and written into the archive's history")
        try await records.rebuild()
        #expect(try await summaries(.settingsChanged, in: database) == [TestSettingChange.summary], "a later rebuild reads it back, and records it no second time")
    }

    @Test func anIndexWhoseArchiveHoldsNoRecordsRecordsWhatWasHeldWhenItIsFoundComplete() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        let config = env.config
        let (database, _) = try AppDatabase.open(at: env.root.appendingPathComponent("Indexes/archive.sqlite"), config: config.database,
                                                 setAsideSuffix: config.records.setAsideSuffix, time: env.time) { false }
        try await HistoryStore(database: database, time: env.time).record(.settingsChanged, actor: .user, summary: TestSettingChange.summary)
        #expect(try await summaries(.settingsChanged, in: database).isEmpty, "the event is held until the archive is opened")
        #expect(try await env.records(index: database).rebuildIfPending() == nil, "where nothing is found to rebuild from")
        #expect(try await summaries(.settingsChanged, in: database) == [TestSettingChange.summary], "so the index is complete, and records it")
    }

    @Test func anEventAboutWhatTheIndexHoldsIsRefusedUntilItHoldsItsArchive() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let (database, _) = try w.newIndex()
        let job = try #require(try await JobStore(database: database, time: w.h.env.time).enqueue(path: w.topListing.path, kind: .ingest))
        do {
            try await HistoryStore(database: database, time: w.h.env.time).record(.arrived, job: job, summary: "arrived")
            Issue.record("an event about a job was recorded in an index that holds nothing of its archive")
        } catch {
            let explained = await database.explained(error)
            #expect(explained is RecordsError, "it is refused as the index is not rebuilt, as a change to what the record files hold is: \(explained)")
        }
    }
}
