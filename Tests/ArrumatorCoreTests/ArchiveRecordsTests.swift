import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// The archive is the record and the database its index (docs/storage.md): everything the app knows reaches a file,
/// and an index that is lost or unreadable is rebuilt from the files alone.
@Suite struct ArchiveRecordsTests {
    private struct World {
        let h: Harness
        let records: ArchiveRecords
        let documents: [Int64]
    }

    /// Files two documents and writes the record files.
    private func world() async throws -> World {
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: ["edp_july.txt": StubAnalyzer.edpBill,
                                                                                        "edp_august.txt": StubAnalyzer.edpBill]))
        for (name, text) in [("edp_july.txt", "EDP electricity July"), ("edp_august.txt", "EDP electricity August")] {
            try await h.ingest(name, text: text)
        }
        let documents = try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 10).compactMap(\.id).sorted()
        let records = ArchiveRecords(database: h.env.database, settings: h.env.settings, config: h.env.config, registry: nil, time: TestTime(.advances))
        try await records.flush()
        return World(h: h, records: records, documents: documents)
    }

    /// A second index over the same archive, as after the database was lost.
    private func freshIndex(_ w: World) throws -> (AppDatabase, ArchiveRecords) {
        let database = try AppDatabase.inMemory()
        return (database, ArchiveRecords(database: database, settings: w.h.env.settings, config: w.h.env.config, registry: nil, time: TestTime(.advances)))
    }

    private func listing(_ w: World, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(w.h.env.config.records.documentsFileName), encoding: .utf8)
    }

    @Test func everythingTheAppKnowsIsWrittenIntoTheArchive() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let doc = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        let listing = try listing(w, in: w.h.env.archive)
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

    @Test func aLostIndexIsRebuiltFromTheArchiveAlone() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let before = try await w.h.services.documents.list(DocumentFilter(), limit: 100).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        let eventsBefore = try await w.h.services.history.events(limit: 1_000).count

        let (database, records) = try freshIndex(w)
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
        let w = try await world()
        defer { w.h.env.cleanup() }
        let paths = try await w.h.services.documents.list(DocumentFilter(), limit: 100).map(\.path).sorted()
        let (database, records) = try freshIndex(w)
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
        let search = SearchService(database: database, vectors: VectorIndex(), embedder: nil, config: services.config.search)
        #expect(Set(try await search.fullText(SearchQuery(text: "jurisdiction:portugal")).hits.map(\.id)) == Set(w.documents),
                "a document is found by its labels again, from its record")
    }

    @Test func aDocumentNotYetLabelledStaysSoThroughARebuild() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        let records = ArchiveRecords(database: h.env.database, settings: h.env.settings, config: h.env.config, registry: nil, time: TestTime(.advances))
        try await records.flush()
        let text = try String(contentsOf: h.env.archive.appendingPathComponent(h.env.config.records.documentsFileName), encoding: .utf8)
        #expect(!text.contains("labels:"), "an entry has no labels until the model has given some")

        let database = try AppDatabase.inMemory()
        try await ArchiveRecords(database: database, settings: h.env.settings, config: h.env.config, registry: nil, time: TestTime(.advances)).rebuild()
        let id = try #require(doc.id)
        let back = try #require(try await DocumentStore(database: database, time: TestTime(.advances)).document(id: id))
        #expect(back.labels == nil && back.status == .needsReview, "read back as not labelled, never as labelled with nothing")
    }

    @Test func anEntryWrittenByAnEarlierVersionIsReadWithItsDocumentUnlabelled() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let directory = env.archive.appendingPathComponent("Home/Utilities/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("2026-07-05 EDP - Fatura.pdf")
        try Data("pdf".utf8).write(to: file)
        // As versions that filed into folders wrote it: tags and a filing decision, no labels and no analysis.
        try """
        ---
        arrumator: 1
        entries:
        - id: 7
          uid: 5B7A8F4E-0000-0000-0000-000000000007
          file: 2026-07-05 EDP - Fatura.pdf
          original_name: fatura.pdf
          added: 2026-07-05T10:00:00Z
          filed: 2026-07-05T10:01:00Z
          status: filed
          sender: EDP Comercial
          document_type: invoice
          date: 2026-07-05
          title: Fatura eletricidade
          language: pt
          tags: [energy]
          decided_by: llm
          confidence: 0.93
          band: auto
          rationale: EDP electricity invoice
          content_type: com.adobe.pdf
          size: 3
          sha256: abc
          decision: {folderCode: F12, title: Fatura eletricidade, confidence: {final: 0.93}}
        ---
        """.write(to: directory.appendingPathComponent(env.config.records.documentsFileName), atomically: true, encoding: .utf8)
        let summary = try await ArchiveRecords(database: env.database, settings: env.settings, config: env.config, registry: nil, time: TestTime(.advances)).rebuild()
        #expect(summary.documents == 1, "the earlier version's entry is read")
        let doc = try #require(try await DocumentStore(database: env.database, time: TestTime(.advances)).document(id: 7))
        #expect(doc.path == file.standardizedFileURL.path && doc.status == .filed && doc.originalFilename == "fatura.pdf",
                "a document an earlier version filed into a folder stays where it is")
        let unlabelled = try await DocumentStore(database: env.database, time: TestTime(.advances)).unlabelled()
        #expect(doc.labels == nil && doc.analysis == nil && unlabelled.isEmpty,
                "it has no labels until it is read again; with no stored text yet, it waits for its text to be read first")
    }

    /// Changes a label of the first document in the top `_documents.md`, as someone editing it by hand would.
    private func editLabelByHand(_ w: World) throws -> URL {
        let url = w.h.env.archive.appendingPathComponent(w.h.env.config.records.documentsFileName)
        let text = try String(contentsOf: url, encoding: .utf8)
        let edited = try #require(text.range(of: "value: Maria Exemplo").map { text.replacingCharacters(in: $0, with: "value: Maria Silva") })
        try edited.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aRecordFileEditedByHandIsReadBack() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        _ = try editLabelByHand(w)
        #expect(try await w.records.reconcile() == 1, "the edited file, and only it, is read again")
        let parties = try await w.h.services.documents.list(DocumentFilter(), limit: 5).flatMap { $0.labels(.party) }
        #expect(parties.sorted() == ["Maria Exemplo", "Maria Silva"], "a label corrected in the file is the document's, and only that document's")
    }

    @Test func aRecordFileThatCannotBeReadIsNeitherOverwrittenNorTakenAsEmpty() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let url = w.h.env.archive.appendingPathComponent(w.h.env.config.records.documentsFileName)
        let broken = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "entries:", with: "entries: [unclosed")
        try broken.write(to: url, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self, "a file that is no longer valid YAML stops the read with the reason") {
            try await w.records.reconcile()
        }
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        await #expect(throws: RecordsError.self, "and a change to its directory is not written over it; it is tried again") {
            try await w.records.flush()
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == broken, "the user's file stays exactly as they left it")
        let documents = try await w.h.services.documents.list(DocumentFilter(), limit: 10)
        #expect(documents.count == w.documents.count + 1, "the index keeps every document, the new one too")
        #expect(documents.filter { $0.labels == StubAnalyzer.edpBill }.compactMap(\.id).sorted() == w.documents,
                "and the ones already there keep their labels")
    }

    @Test func aChangeNeverOverwritesAnEditMadeByHand() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let url = try editLabelByHand(w)
        // Before the app has read the edit, another document arrives in the same directory.
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        try await w.records.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("value: Maria Silva") && text.contains("file: edp_september.txt"),
                "the file keeps the edit and gains what the index added")
    }

    @Test func theUsersDecisionsAboutLabelsLiveInTheArchiveAndSurviveALostIndex() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let actions = w.h.labels
        try await actions.merge(DocumentLabel(kind: .sender, value: "EDP Comercial"), into: "EDP")
        try await actions.ignore(DocumentLabel(kind: .topic, value: "electricity"))
        try await w.records.flush()
        let url = w.h.env.layout.labelRules
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("action: merge") && text.contains("target: EDP") && text.contains("| topic | electricity | not wanted |"),
                "the rules are the user's, kept in the archive's system folder with a table for people")

        let (database, records) = try freshIndex(w)
        let summary = try await records.rebuild()
        #expect(summary.labelRules == 2, "both rules are read from the archive")
        let rebuilt = try await LabelStore(database: database, config: w.h.env.config.labels).rules()
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
        let w = try await world()
        defer { w.h.env.cleanup() }
        let url = w.h.env.archive.appendingPathComponent(w.h.env.config.records.documentsFileName)
        try FileManager.default.removeItem(at: url)
        try await w.records.reconcile()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("value: EDP Comercial"), "deleting a file does not delete what it records")
        #expect(try await w.h.services.documents.list(DocumentFilter(), limit: 5).count == 2, "no document is lost or doubled")
    }

    @Test func aDocumentsEntryFollowsItAndAnEmptiedDirectoryLosesItsFile() async throws {
        let w = try await world()
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
        #expect(try listing(w, in: moved.deletingLastPathComponent()).contains("uid: \(doc.uid)"), "the entry follows its document")
        #expect(!FileManager.default.fileExists(atPath: w.h.env.archive.appendingPathComponent(w.h.env.config.records.documentsFileName).path),
                "a directory with no documents keeps no listing")
    }

    @Test func aLostIndexFindsDocumentsWhereverTheyAreAndTakesInFilesPutThereByHand() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        try await w.h.env.settings.update { $0.incomingPath = w.h.env.archive.appendingPathComponent("Inbox").path }
        let byHand = [try w.h.env.put("loose.txt", text: "put there by hand"), try w.h.env.put("Old/2025/statement.txt", text: "by hand")]
        _ = try w.h.env.put("Inbox/waiting.txt", text: "not yet filed")
        _ = try w.h.env.put("\(w.h.env.config.records.systemFolderName)/stray.txt", text: "no document")
        let (database, records) = try freshIndex(w)
        let summary = try await records.rebuild()
        #expect(summary.documents == 2 && summary.missing == 0, "filed documents are found where their records say")
        let adoptions = try await JobStore(database: database, time: TestTime(.advances)).active(kinds: [.adopt])
        #expect(Set(adoptions.map(\.sourcePath)) == Set(byHand.map(\.path)),
                "files put in the archive by hand are taken in where they are, but not from Incoming or the system folder")
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

    @Test func anUnreadableIndexIsSetAsideOnlyWhenTheArchiveCanRebuildIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("arrumator.sqlite")
        try Data("not a database".utf8).write(to: url)
        #expect(throws: DatabaseOpeningError.self, "without records to rebuild from, the app stops instead of starting empty") {
            _ = try Self.open(url, canRebuild: false)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not a database", "and leaves the file alone")
        let (_, opening) = try Self.open(url, canRebuild: true)
        guard case let .setAside(aside) = opening else {
            Issue.record("expected the database to be set aside, got \(opening)")
            return
        }
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not a database", "the unreadable file is kept, never deleted")
        #expect(opening.needsRebuild, "and the index is rebuilt from the archive")
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
