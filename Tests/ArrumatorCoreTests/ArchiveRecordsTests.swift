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
        let sender: Correspondent
    }

    /// Files two documents, teaches a sender, and writes the record files.
    private func world() async throws -> World {
        let h = try await Harness.make(analyzer: LabelingTests.PerFileAnalyzer(labels: ["edp_july.txt": StubAnalyzer.edpBill,
                                                                                        "edp_august.txt": StubAnalyzer.edpBill]))
        for (name, text) in [("edp_july.txt", "EDP electricity July"), ("edp_august.txt", "EDP electricity August")] {
            try await h.ingest(name, text: text)
        }
        let documents = try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 10).compactMap(\.id).sorted()
        let sender = try await h.services.senders.saveCorrespondent(Correspondent(
            canonicalName: "EDP Comercial", country: "PT", aliases: ["EDP"], stableKeys: ["ptNIF:503504564"], webDomains: ["edp.pt"],
            filedCount: 2, origin: .learned))
        let records = ArchiveRecords(database: h.env.database, settings: h.env.settings, config: h.env.config, registry: nil)
        try await records.flush()
        return World(h: h, records: records, documents: documents, sender: sender)
    }

    /// A second index over the same archive, as after the database was lost.
    private func freshIndex(_ w: World) throws -> (AppDatabase, ArchiveRecords) {
        let database = try AppDatabase.inMemory()
        return (database, ArchiveRecords(database: database, settings: w.h.env.settings, config: w.h.env.config, registry: nil))
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
        let layout = w.h.env.layout
        #expect(try String(contentsOf: layout.senders, encoding: .utf8).contains("EDP Comercial"))
        #expect(try String(contentsOf: layout.historyFile(month: RecordKind.month(of: Date())), encoding: .utf8).contains("filed"))
        let system = try FileManager.default.contentsOfDirectory(atPath: layout.system.path).sorted()
        #expect(system == [w.h.env.config.records.historyFolderName, w.h.env.config.records.learnedFolderName].sorted(),
                "the system folder holds the senders and the history, nothing else")
        let pending = try await w.h.env.database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty") }
        #expect(pending == 0)
    }

    @Test func aLostIndexIsRebuiltFromTheArchiveAlone() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let before = try await w.h.services.documents.list(DocumentFilter(), limit: 100).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        let eventsBefore = try await w.h.services.history.events(limit: 1_000).count

        let (database, records) = try freshIndex(w)
        let summary = try await records.rebuild()
        #expect(summary.documents == before.count && summary.missing == 0 && summary.adopted == 0)

        let after = try await DocumentStore(database: database).list(DocumentFilter(), limit: 100).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        #expect(after.map(\.id) == before.map(\.id), "documents keep their numbers")
        for (a, b) in zip(after, before) {
            #expect(a.uid == b.uid && a.path == b.path && a.status == b.status && a.title == b.title && a.docType == b.docType)
            #expect(a.analysis == b.analysis, "what the model read it as comes back")
            #expect(a.labels == StubAnalyzer.edpBill && a.labels == b.labels, "labels come back from the record files")
        }
        let senders = try await SenderStore(database: database).correspondents()
        #expect(senders.map(\.canonicalName) == ["EDP Comercial"] && senders.first?.id == w.sender.id)
        #expect(senders.first?.stableKeys == ["ptNIF:503504564"] && senders.first?.aliases == ["EDP"])
        #expect(try await HistoryStore(database: database).events(limit: 1_000).count == eventsBefore + 1, "plus the rebuild itself")
        let queued = try await JobStore(database: database).active(kinds: [.reindex])
        #expect(Set(queued.compactMap(\.docId)) == Set(w.documents), "every document is read again for search")
    }

    @Test func afterARebuildDocumentsAreSearchableAgainWithoutAskingTheModel() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let paths = try await w.h.services.documents.list(DocumentFilter(), limit: 100).map(\.path).sorted()
        let (database, records) = try freshIndex(w)
        try await records.rebuild()
        let analyzer = StubAnalyzer()
        let learner = RecordingLearner()
        var services = w.h.services
        services = PipelineServices(
            database: database, config: services.config, settings: services.settings, extractor: services.extractor, analyzer: analyzer,
            learner: learner,
            filer: DocumentFiler(database: database, placer: services.filer.placer, index: IndexStore(database: database),
                                 registry: SelfChangeRegistry(ttl: services.config.watcher.selfChangeTTLSeconds)),
            traces: TraceRecorder(database: database, appVersion: "test"), vectors: VectorIndex())
        await IngestCoordinator(services: services).drain()

        let index = IndexStore(database: database)
        for id in w.documents {
            #expect(try await index.body(docID: id)?.contains("EDP electricity") == true, "the text is searchable again")
            #expect(try await index.embedding(docID: id, model: StubAnalyzer.embeddingModel) != nil)
        }
        #expect(try await DocumentStore(database: database).list(DocumentFilter(), limit: 100).map(\.path).sorted() == paths,
                "reading again moves nothing")
        let read = await analyzer.calls.files
        let learned = await learner.filed
        #expect(read.isEmpty && learned.isEmpty, "and asks the model nothing")
        let search = SearchService(database: database, vectors: VectorIndex(), embedder: nil, config: services.config.search)
        #expect(Set(try await search.fullText(SearchQuery(text: "jurisdiction:portugal")).hits.map(\.id)) == Set(w.documents),
                "a document is found by its labels again, from its record")
    }

    @Test func aDocumentNotYetLabelledStaysSoThroughARebuild() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("bill.txt", text: "EDP electricity July")
        let records = ArchiveRecords(database: h.env.database, settings: h.env.settings, config: h.env.config, registry: nil)
        try await records.flush()
        let text = try String(contentsOf: h.env.archive.appendingPathComponent(h.env.config.records.documentsFileName), encoding: .utf8)
        #expect(!text.contains("labels:"), "an entry has no labels until the model has given some")

        let database = try AppDatabase.inMemory()
        try await ArchiveRecords(database: database, settings: h.env.settings, config: h.env.config, registry: nil).rebuild()
        let id = try #require(doc.id)
        let back = try #require(try await DocumentStore(database: database).document(id: id))
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
        let summary = try await ArchiveRecords(database: env.database, settings: env.settings, config: env.config, registry: nil).rebuild()
        #expect(summary.documents == 1)
        let doc = try #require(try await DocumentStore(database: env.database).document(id: 7))
        #expect(doc.path == file.standardizedFileURL.path && doc.status == .filed && doc.title == "Fatura eletricidade",
                "a document an earlier version filed into a folder stays where it is, with what it was known as")
        let unlabelled = try await DocumentStore(database: env.database).unlabelled()
        #expect(doc.labels == nil && doc.analysis == nil && unlabelled.isEmpty,
                "it has no labels until it is read again; with no stored text yet, it waits for its text to be read first")
    }

    @Test func aRecordFileEditedByHandIsReadBack() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let url = w.h.env.layout.senders
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "canonicalName: EDP Comercial", with: "canonicalName: EDP Energia")
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(try await w.records.reconcile() == 1)
        #expect(try await w.h.services.senders.correspondents().map(\.canonicalName) == ["EDP Energia"])
    }

    @Test func aChangeNeverOverwritesAnEditMadeByHand() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let url = w.h.env.layout.senders
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "canonicalName: EDP Comercial", with: "canonicalName: EDP Energia")
            .write(to: url, atomically: true, encoding: .utf8)
        // Before the app has read the edit, something else changes the senders.
        _ = try await w.h.services.senders.saveCorrespondent(Correspondent(canonicalName: "MEO", country: "PT", filedCount: 1, origin: .learned))
        try await w.records.flush()
        #expect(try await w.h.services.senders.correspondents().map(\.canonicalName).sorted() == ["EDP Energia", "MEO"])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("EDP Energia"))
    }

    @Test func aDeletedRecordFileIsWrittenAgain() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let url = w.h.env.layout.senders
        try FileManager.default.removeItem(at: url)
        try await w.records.reconcile()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("EDP Comercial"), "deleting a file does not delete what it records")
        #expect(try await w.h.services.senders.correspondents().count == 1)
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
        #expect(summary.documents == 2 && summary.missing == 0)
        let adoptions = try await JobStore(database: database).active(kinds: [.adopt])
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

    @Test func anUnreadableIndexIsSetAsideOnlyWhenTheArchiveCanRebuildIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("arrumator.sqlite")
        try Data("not a database".utf8).write(to: url)
        #expect(throws: DatabaseOpeningError.self, "without records to rebuild from, the app stops instead of starting empty") {
            _ = try AppDatabase.open(at: url, setAsideSuffix: "unreadable") { false }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not a database", "and leaves the file alone")
        let (_, opening) = try AppDatabase.open(at: url, setAsideSuffix: "unreadable") { true }
        guard case let .setAside(aside) = opening else {
            Issue.record("expected the database to be set aside, got \(opening)")
            return
        }
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not a database", "the unreadable file is kept, never deleted")
        #expect(opening.needsRebuild)
    }
}
