import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// The archive is the record and the database its index (docs/storage.md): everything the app knows reaches a file,
/// and an index that is lost or unreadable is rebuilt from the files alone.
@Suite struct ArchiveRecordsTests {
    @Test func everythingTheAppKnowsIsWrittenIntoTheArchive() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let doc = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        let listing = try w.listing(in: w.h.env.archive)
        #expect(listing.contains("uid: \(doc.uid)") && listing.contains("file: \(doc.filename)"), "a document's entry sits next to it")
        #expect(listing.contains("kind: jurisdiction") && listing.contains("value: Portugal"), "with its labels")
        #expect(listing.contains("analysis:") && !listing.contains("decision:"), "and what the model read it as")
        #expect(listing.contains("| edp_july.txt | 2026-07-05 | EDP Comercial | invoice |"), "and, for people, a table of them")
        let layout = w.h.env.layout
        #expect(try String(contentsOf: layout.historyFile(month: RecordKind.month(of: w.h.env.time.now())), encoding: .utf8).contains("filed"),
                "the filing is in the month's history file")
        let system = try FileManager.default.contentsOfDirectory(atPath: layout.system.path)
        #expect(system == [w.h.env.config.records.historyFolderName], "the system folder holds the history, nothing else")
        let pending = try await w.h.env.database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty") }
        #expect(pending == 0, "every change has reached a file")
    }

    @Test func theTimesWrittenForPeopleAreTheMacsOwnWithItsZone() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let history = try String(contentsOf: w.h.env.layout.historyFile(month: RecordKind.month(of: w.h.env.time.now())), encoding: .utf8)
        let event = try #require(try await w.h.services.history.events(limit: 1).first)
        let zone = TimeZone.current
        let parts = Calendar.current.dateComponents(in: zone, from: event.at)
        let local = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let line = try #require(history.components(separatedBy: "\n").first { $0.hasPrefix("- ") && $0.hasSuffix(" · " + event.summary) })
        #expect(line.hasPrefix("- \(local)") && line.range(of: #"^- \S+([+-]\d{2}:\d{2}|Z) · "#, options: .regularExpression) != nil,
                "the hour the Mac showed when it happened, with its offset, so nobody reads a UTC hour as their own: \(line)")
    }

    @Test func aLostIndexIsRebuiltFromTheArchiveAlone() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let before = try await w.h.services.documents.list(DocumentFilter(), limit: 100).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        let eventsBefore = try await w.h.services.history.events(limit: 1_000).count

        let (database, records) = try w.freshIndex()
        let summary = try await records.rebuild()
        #expect(summary.documents == before.count && summary.missing == 0 && summary.adopted == 0,
                "every document is found in its record, none missing and none new")

        let after = try await DocumentStore(database: database, time: TestTime(.advances)).list(DocumentFilter(), limit: 100).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        #expect(after.map(\.id) == before.map(\.id), "documents keep their numbers")
        for (a, b) in zip(after, before) {
            #expect(a.uid == b.uid && a.path == b.path && a.status == b.status, "each document keeps its identity, place and status")
            #expect(a.analysis == b.analysis, "what the model read it as comes back")
            #expect(a.labels == StubAnalyzer.edpBill && a.labels == b.labels, "labels come back from the record files")
        }
        #expect(try await HistoryStore(database: database, time: TestTime(.advances)).events(limit: 1_000).count == eventsBefore + 1, "plus the rebuild itself")
        let queued = try await JobStore(database: database, time: TestTime(.advances)).active(kinds: [.reindex])
        #expect(Set(queued.compactMap(\.docId)) == Set(w.documents), "every document is read again for search")
    }

    @Test func afterARebuildDocumentsAreSearchableAgainWithoutAskingTheModel() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let paths = try await w.h.services.documents.list(DocumentFilter(), limit: 100).map(\.path).sorted()
        let (database, records) = try w.freshIndex()
        try await records.rebuild()
        let analyzer = StubAnalyzer()
        var services = Harness.services(w.h.env, analyzer: analyzer, config: w.h.env.config)
        services.database = database
        services.filer = DocumentFiler(database: database, placer: services.filer.placer, index: IndexStore(database: database, time: w.h.env.time),
                                       registry: services.filer.registry, time: w.h.env.time)
        services.traces = TraceRecorder(database: database, appVersion: "test", time: w.h.env.time)
        await IngestCoordinator(services: services).drain()

        let index = IndexStore(database: database, time: TestTime(.advances))
        var bodies: [String?] = []
        for id in w.documents {
            bodies.append(try await index.body(docID: id))
            #expect(try await index.embedding(docID: id, model: StubAnalyzer.embeddingModel) == [1, 0, 0], "and it is found by meaning again")
        }
        #expect(bodies == ["EDP electricity July", "EDP electricity August"], "the text is searchable again")
        #expect(try await DocumentStore(database: database, time: TestTime(.advances)).list(DocumentFilter(), limit: 100).map(\.path).sorted() == paths,
                "reading again moves nothing")
        #expect(await analyzer.calls.files.isEmpty, "and asks the model nothing")
        let search = SearchService(database: database, vectors: VectorIndex(), embedder: nil, config: services.config.search, time: services.time)
        #expect(Set(try await search.fullText(SearchQuery(text: "jurisdiction:portugal")).hits.map(\.id)) == Set(w.documents),
                "a document is found by its labels again, from its record")
    }

    @Test func readingADocumentAgainAfterARebuildAsksTheModelRatherThanOnlyReadingItsText() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let (database, records) = try w.freshIndex()
        try await records.rebuild()
        let analyzer = StubAnalyzer()
        var services = Harness.services(w.h.env, analyzer: analyzer, config: w.h.env.config)
        services.database = database
        services.filer = DocumentFiler(database: database, placer: services.filer.placer, index: IndexStore(database: database, time: w.h.env.time),
                                       registry: services.filer.registry, time: w.h.env.time)
        services.traces = TraceRecorder(database: database, appVersion: "test", time: w.h.env.time)
        let coordinator = IngestCoordinator(services: services)
        let id = w.documents[0]
        let filename = try #require(try await services.documents.document(id: id)).filename
        let queued = try await services.jobs.active()
        try await ReviewActions(services: services, coordinator: coordinator).retry(id)
        let active = try await services.jobs.active()
        #expect(queued.map(\.kind) == [.reindex, .reindex] && active.map(\.kind) == [.reindex, .reanalyse] && active.last?.docId == id,
                "reading it again takes the place of having its text read, which reading with the model does too")
        await coordinator.drain()
        #expect(await analyzer.calls.files == [filename], "so the model reads it, rather than the request waiting unread behind its text")
    }

    @Test func aDocumentNotYetLabelledStaysSoThroughARebuild() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        let records = h.env.records()
        try await records.flush()
        let text = try String(contentsOf: h.env.archive.appendingPathComponent(h.env.config.records.documentsFileName), encoding: .utf8)
        #expect(!text.contains("labels:"), "an entry has no labels until the model has given some")

        let database = try AppDatabase.inMemory()
        try await h.env.records(index: database).rebuild()
        let id = try #require(doc.id)
        let back = try #require(try await DocumentStore(database: database, time: TestTime(.advances)).document(id: id))
        #expect(back.labels == nil && back.status == .needsReview, "read back as not labelled, never as labelled with nothing")
    }

    @Test func aRecordFileEditedByHandIsReadBack() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        _ = try w.editLabelByHand()
        #expect(try await w.records.reconcile() == 1, "the edited file, and only it, is read again")
        let parties = try await w.h.services.documents.list(DocumentFilter(), limit: 5).flatMap { $0.labels(.party) }
        #expect(parties.sorted() == ["Maria Exemplo", "Maria Silva"], "a label corrected in the file is the document's, and only that document's")
    }

    @Test func aChangeNeverOverwritesAnEditMadeByHand() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let url = try w.editLabelByHand()
        // Before the app has read the edit, another document arrives in the same directory.
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        try await w.records.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("value: Maria Silva") && text.contains("file: edp_september.txt"),
                "the file keeps the edit and gains what the index added")
    }

    @Test func theUsersDecisionsAboutLabelsLiveInTheArchiveAndSurviveALostIndex() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let actions = w.h.labels
        try await actions.merge(DocumentLabel(kind: .sender, value: "EDP Comercial"), into: "EDP")
        try await actions.ignore(DocumentLabel(kind: .topic, value: "electricity"))
        try await w.records.flush()
        let url = w.h.env.layout.labelRules
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("action: merge") && text.contains("target: EDP") && text.contains("| topic | electricity | not wanted |"),
                "the rules are the user's, kept in the archive's system folder with a table for people")

        let (database, records) = try w.freshIndex()
        let summary = try await records.rebuild()
        #expect(summary.labelRules == 2, "both rules are read from the archive")
        let rebuilt = try await LabelStore(database: database, config: w.h.env.config.labels, lookAlikes: LookAlikeMemo()).rules()
        #expect(rebuilt.map(\.summary) == ["sender “EDP Comercial” → “EDP”", "topic “electricity” ignored"], "they come back with a lost index")
        #expect(try await DocumentStore(database: database, time: TestTime(.advances)).list(DocumentFilter(), limit: 5).allSatisfy { $0.labels(.sender) == ["EDP"] },
                "as do the labels they changed")

        try text.replacingOccurrences(of: "target: EDP\n", with: "target: EDP Energia\n").write(to: url, atomically: true, encoding: .utf8)
        try await w.records.reconcile()
        #expect(try await w.h.services.labels.rules().first?.target == "EDP Energia", "a rule changed by hand is read back")

        for rule in try await w.h.services.labels.rules() { try await actions.forget(rule: try #require(rule.id)) }
        try await w.records.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path), "without rules there is no file")
    }

    @Test func aDeletedRecordFileIsWrittenAgain() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let url = w.h.env.archive.appendingPathComponent(w.h.env.config.records.documentsFileName)
        try FileManager.default.removeItem(at: url)
        try await w.records.reconcile()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("value: EDP Comercial"), "deleting a file does not delete what it records")
        #expect(try await w.h.services.documents.list(DocumentFilter(), limit: 5).count == 2, "no document is lost or doubled")
    }

    @Test func aDocumentsEntryFollowsItAndAnEmptiedDirectoryLosesItsFile() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let doc = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        let moved = w.h.env.archive.appendingPathComponent("Kept/\(doc.filename)").standardizedFileURL
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        for id in w.documents {
            let d = try #require(try await w.h.services.documents.document(id: id))
            let target = moved.deletingLastPathComponent().appendingPathComponent(d.filename)
            try FileManager.default.moveItem(at: d.url, to: target)
            await ArchiveReconciler(services: w.h.services, coordinator: w.h.coordinator)
                .apply([.documentMoved(uid: d.uid, newPath: target.path)])
        }
        try await w.records.flush()
        #expect(try w.listing(in: moved.deletingLastPathComponent()).contains("uid: \(doc.uid)"), "the entry follows its document")
        #expect(!FileManager.default.fileExists(atPath: w.h.env.archive.appendingPathComponent(w.h.env.config.records.documentsFileName).path),
                "a directory with no documents keeps no listing")
    }

    @Test func aLostIndexFindsDocumentsWhereverTheyAreAndTakesInFilesPutThereByHand() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let byHand = [try w.h.env.put("loose.txt", text: "put there by hand"), try w.h.env.put("Old/2025/statement.txt", text: "by hand")]
        _ = try w.h.env.put("\(w.h.env.config.records.systemFolderName)/stray.txt", text: "no document")
        // While the index was lost, one document was moved in Finder, keeping the identifier on it, and the other deleted.
        let moved = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        let gone = try #require(try await w.h.services.documents.document(id: w.documents[1]))
        let elsewhere = w.h.env.archive.appendingPathComponent("Elsewhere/\(moved.filename)").standardizedFileURL
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: moved.url, to: elsewhere)
        try FileManager.default.removeItem(at: gone.url)
        let (database, records) = try w.freshIndex()
        let summary = try await records.rebuild()
        #expect(summary.documents == 2 && summary.relocated == 1 && summary.missing == 1,
                "documents are found by the identifier on their file, wherever it is, and one that is nowhere is missing: \(summary)")
        let store = DocumentStore(database: database, time: TestTime(.advances))
        let found = try #require(try await store.document(id: w.documents[0]))
        #expect(found.path == elsewhere.path && found.status == moved.status, "the moved document is where its file is now")
        #expect(try await store.document(id: w.documents[1])?.status == .missing, "the deleted one is marked missing")
        let adoptions = try await JobStore(database: database, time: TestTime(.advances)).active(kinds: [.adopt])
        #expect(Set(adoptions.map(\.sourcePath)) == Set(byHand.map(\.path)),
                "files put in the archive by hand are taken in where they are, but not from the system folder, nor a document moved")
    }

    @Test func aRebuildTakesBackADocumentMarkedMissingWhoseFileIsFound() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let doc = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        // Taken out of the archive, and marked missing as the app saw it go.
        let away = w.h.env.root.appendingPathComponent("Away/\(doc.filename)")
        try FileManager.default.createDirectory(at: away.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: doc.url, to: away)
        await ArchiveReconciler(services: w.h.services, coordinator: w.h.coordinator).apply([.documentMissing(path: doc.path)])
        try await w.records.flush()
        #expect(try w.listing(in: w.h.env.archive).contains("status: missing"), "its entry says it is missing")
        // Put back into another folder of the archive while the index was lost.
        let back = w.h.env.archive.appendingPathComponent("Back/\(doc.filename)").standardizedFileURL
        try FileManager.default.createDirectory(at: back.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: away, to: back)
        let (database, records) = try w.freshIndex()
        let summary = try await records.rebuild()
        let found = try #require(try await DocumentStore(database: database, time: TestTime(.advances)).document(id: w.documents[0]))
        #expect(found.status == .filed && found.path == back.path && summary.relocated == 1 && summary.missing == 0,
                "a document found by the identifier on its file is filed again where it is, as when the app sees it come back: \(summary)")
        let queued = try await JobStore(database: database, time: TestTime(.advances)).active(kinds: [.reindex])
        #expect(queued.contains { $0.docId == w.documents[0] }, "and its text is read again with the others")
    }

    @Test func anArchiveWithRecordsIsRecognisedWithoutWalkingIt() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        #expect(!ArchiveRecords.mayHoldRecords(archive: env.archive, config: env.config), "an archive that does not exist yet")
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        #expect(!ArchiveRecords.mayHoldRecords(archive: env.archive, config: env.config), "an empty archive")
        try FileManager.default.createDirectory(at: env.layout.history, withIntermediateDirectories: true)
        #expect(ArchiveRecords.mayHoldRecords(archive: env.archive, config: env.config), "one with the system folder")
    }

    private static func open(_ url: URL, busyTimeout: Double = 1, canRebuild: Bool) throws -> (AppDatabase, AppDatabase.Opening) {
        var config = try PipelineConfig.bundledDefaults()
        config.database.busyTimeout = busyTimeout
        return try AppDatabase.open(at: url, config: config.database, setAsideSuffix: config.records.setAsideSuffix,
                                    time: TestTime(.advances)) { canRebuild }
    }

    @Test func anUnreadableIndexIsSetAsideOnlyWhenTheArchiveCanRebuildIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("arrumator.sqlite")
        try Data("not a database".utf8).write(to: url)
        #expect(throws: DatabaseOpeningError.self, "without records to rebuild from, the app stops instead of starting empty") {
            _ = try Self.open(url, canRebuild: false)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not a database", "and leaves the file alone")
        let (database, opening) = try Self.open(url, canRebuild: true)
        guard case let .setAside(aside) = opening else {
            Issue.record("expected the database to be set aside, got \(opening)")
            return
        }
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not a database", "the unreadable file is kept, never deleted")
        #expect(try await database.pendingRebuild() == .unread, "and the new index says it is to be rebuilt from the archive")
    }

    @Test func anIndexNotYetRebuiltFromItsArchiveIsRebuiltAtTheNextOpeningAndOnlyThen() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let url = w.h.env.root.appendingPathComponent("Indexes/archive.sqlite")
        func open() throws -> (AppDatabase, AppDatabase.Opening, ArchiveRecords) {
            let (database, opening) = try Self.open(url, canRebuild: true)
            return (database, opening, w.h.env.records(index: database))
        }
        // The app makes the archive's index when it starts, and reads the archive into it once onboarding is done: it quits between.
        #expect(try open().1 == .created, "the first opening makes the index")
        let (database, opening, records) = try open()
        #expect(opening == .existing, "the next one finds it")
        let summary = try #require(try await records.rebuildIfPending(), "and rebuilds it from the archive all the same, as it never was")
        #expect(summary.documents == w.documents.count, "with every document in it")
        let reindexing = { try await JobStore(database: database, time: TestTime(.advances)).active(kinds: [.reindex]).compactMap(\.docId).sorted() }
        #expect(try await reindexing() == w.documents, "each queued to have its text read again")
        // A rebuild cut short before its last step is done again at the next opening.
        try await database.setMeta(AppDatabase.rebuildPendingKey, AppDatabase.PendingRebuild.unfinished.rawValue)
        #expect(try await open().2.rebuildIfPending() != nil, "it is done again")
        #expect(try await reindexing() == w.documents, "queueing no document twice")
        #expect(try await open().2.rebuildIfPending() == nil, "and once done, an opening only reads back what changed")
    }

    @Test func anIndexOfAnArchiveWithoutRecordsIsCompleteOnceItIsOpened() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        let (database, _) = try Self.open(env.root.appendingPathComponent("Indexes/archive.sqlite"), canRebuild: true)
        let records = env.records(index: database)
        #expect(try await database.pendingRebuild() == .unread, "a new index holds nothing of its archive until the archive is opened")
        #expect(try await records.rebuildIfPending() == nil, "an empty archive has nothing to rebuild from")
        try await HistoryStore(database: database, time: env.time).record(.paused, summary: "Paused")
        try await records.flush()
        #expect(try await records.rebuildIfPending() == nil, "so its new index is complete, and the files it writes later are never read as a lost index's")
    }

    @Test func anIndexAnotherProcessHoldsIsNeverSetAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("index.sqlite")
        _ = try Self.open(url, canRebuild: true)
        // Another process, the app or arrumatorcli, writing to the index while this one opens it.
        try DatabaseQueue(path: url.path).inDatabase { db in
            try db.execute(sql: "BEGIN EXCLUSIVE")
            #expect(throws: DatabaseOpeningError.self, "a lock is the moment's, so the app stops and says so") {
                _ = try Self.open(url, busyTimeout: 0, canRebuild: true)
            }
            try db.execute(sql: "ROLLBACK")
        }
        let asides = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("unreadable") }
        #expect(asides.isEmpty, "a sound index is never moved aside and rebuilt, losing its traces and queue, for a lock")
    }
}
