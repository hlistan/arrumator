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
        let rule: FilingRule
        let folder: TaxonomyFolder
    }

    /// Files two documents, then teaches a sender, a rule and a correction, gives the archive its own logic, and
    /// writes the record files.
    private func world() async throws -> World {
        let h = try await Harness.make(classifier: StubClassifier(newFolder: StubClassifier.utilities, band: .auto))
        for (name, text) in [("edp_july.txt", "EDP electricity July"), ("edp_august.txt", "EDP electricity August")] {
            await h.coordinator.enqueue(try h.env.drop(name, text: text))
        }
        await h.coordinator.drain()
        let filed = try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 10)
        let documents = filed.compactMap(\.id).sorted()
        let folder = try #require(try await h.env.taxonomy.snapshot(root: h.env.archive).folders.first { $0.name == "Utilities" })
        let store = GRDBLearningStore(database: h.env.database)
        let sender = try await store.saveCorrespondent(Correspondent(
            id: 0, canonicalName: "EDP Comercial", country: "PT", aliases: ["EDP"], stableKeys: ["ptNIF:503504564"], emailDomains: [],
            webDomains: ["edp.pt"], defaultFolderCode: folder.code, filedCount: 2, origin: .learned))
        let rule = try await store.saveRule(FilingRule(
            name: "EDP · invoice → Home / Utilities", priority: 50, origin: .induced,
            predicates: [.correspondent(id: sender.id), .documentType(.invoice)],
            action: RuleAction(folderID: folder.id, folderCode: folder.code, documentType: .invoice), support: 3))
        _ = try await store.insertCorrection(CorrectionEvent(documentID: documents[0], source: .markCorrect, fromFolderID: folder.id,
                                                             toFolderID: folder.id))
        let logic = LogicStore(database: h.env.database, maxChars: h.env.config.classification.logicMaxChars)
        try await logic.sync(builtin: Self.builtin)
        try await logic.update(body: "Bills by year, one folder per supplier.")
        let records = ArchiveRecords(database: h.env.database, settings: h.env.settings, taxonomy: h.env.taxonomy,
                                     config: h.env.config, registry: nil)
        try await records.flush()
        return World(h: h, records: records, documents: documents, sender: sender, rule: rule, folder: folder)
    }

    private static let builtin = "The logic that ships with the app."

    private func learned(_ w: World, _ name: String) async throws -> URL {
        let snapshot = try await w.h.env.taxonomy.snapshot(root: w.h.env.archive)
        let folder = try #require(snapshot.folder(role: .learned))
        return snapshot.url(for: folder).appendingPathComponent(name)
    }

    /// A second index over the same archive, as after the database was lost.
    private func freshIndex(_ w: World) throws -> (AppDatabase, TaxonomyStore, ArchiveRecords) {
        let database = try AppDatabase.inMemory()
        let taxonomy = TaxonomyStore(database: database, config: w.h.env.config.taxonomy, registry: nil)
        return (database, taxonomy, ArchiveRecords(database: database, settings: w.h.env.settings, taxonomy: taxonomy,
                                                   config: w.h.env.config, registry: nil))
    }

    @Test func everythingTheAppKnowsIsWrittenIntoTheArchive() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let doc = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        let listing = try String(contentsOf: doc.url.deletingLastPathComponent()
            .appendingPathComponent(w.h.env.config.taxonomy.documentsFileName), encoding: .utf8)
        #expect(listing.contains("uid: \(doc.uid)") && listing.contains("file: \(doc.filename)"),
                "a document's entry sits next to it")
        #expect(try String(contentsOf: try await learned(w, w.h.env.config.records.sendersFileName), encoding: .utf8).contains("EDP Comercial"))
        #expect(try String(contentsOf: try await learned(w, w.h.env.config.records.rulesFileName), encoding: .utf8).contains(w.rule.name))
        #expect(FileManager.default.fileExists(atPath: try await learned(w, w.h.env.config.records.correctionsFileName).path))
        let snapshot = try await w.h.env.taxonomy.snapshot(root: w.h.env.archive)
        let logicFile = snapshot.url(for: try #require(snapshot.folder(role: .logic)))
            .appendingPathComponent(w.h.env.config.records.logicFileName)
        #expect(try String(contentsOf: logicFile, encoding: .utf8).hasSuffix("\nBills by year, one folder per supplier.\n"),
                "the prompt is the logic file's text")
        #expect(try await w.records.logicFileURL() == logicFile)
        let historyDir = snapshot.url(for: try #require(snapshot.folder(role: .history)))
        let month = RecordKind.month(of: Date())
        #expect(try String(contentsOf: historyDir.appendingPathComponent("_\(month).md"), encoding: .utf8).contains("filed"))
        let pending = try await w.h.env.database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty") }
        #expect(pending == 0)
    }

    @Test func aLostIndexIsRebuiltFromTheArchiveAlone() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let before = try await w.h.services.documents.list(DocumentFilter(), limit: 100).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        let eventsBefore = try await w.h.services.history.events(limit: 1_000).count

        let (database, taxonomy, records) = try freshIndex(w)
        let summary = try await records.rebuild()
        #expect(summary.documents == before.count && summary.missing == 0 && summary.adopted == 0)

        let after = try await DocumentStore(database: database).list(DocumentFilter(), limit: 100).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        #expect(after.map(\.id) == before.map(\.id), "documents keep their numbers")
        let rebuilt = try await taxonomy.snapshot(root: w.h.env.archive)
        for (a, b) in zip(after, before) {
            #expect(a.uid == b.uid && a.path == b.path && a.status == b.status && a.title == b.title && a.docType == b.docType)
            #expect(a.decision?.decidedBy == b.decision?.decidedBy && a.confidence == b.confidence)
            let folder = try #require(a.folderId.flatMap { rebuilt.folder(id: $0) })
            #expect(folder.code == w.folder.code, "the folder comes from where the entry sits")
        }
        let store = GRDBLearningStore(database: database)
        let senders = try await store.correspondents()
        #expect(senders.map(\.canonicalName) == ["EDP Comercial"] && senders.first?.id == w.sender.id)
        #expect(senders.first?.stableKeys == ["ptNIF:503504564"] && senders.first?.aliases == ["EDP"])
        let rules = try await store.rules()
        #expect(rules.map(\.id) == [w.rule.id] && rules.first?.support == 3)
        #expect(rules.first?.predicates.contains(.correspondent(id: w.sender.id)) == true)
        let rebuiltFolder = try #require(try await taxonomy.snapshot(root: w.h.env.archive).folder(code: w.folder.code))
        #expect(rules.first?.action.folderID == rebuiltFolder.id, "a rule points at the folder by its code")
        #expect(try await store.corrections(limit: 10).count == 1)
        let logic = try #require(try await LogicStore(database: database, maxChars: 1_000).current())
        #expect(logic.body == "Bills by year, one folder per supplier." && !logic.followsBuiltin, "the archive's logic comes back")
        #expect(try await HistoryStore(database: database).events(limit: 1_000).count == eventsBefore + 1, "plus the rebuild itself")
        let queued = try await JobStore(database: database).active(kinds: [.reindex])
        #expect(Set(queued.compactMap(\.docId)) == Set(w.documents), "every document is read again for search")
    }

    @Test func afterARebuildDocumentsAreReadAgainForSearchWithoutMoving() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let paths = try await w.h.services.documents.list(DocumentFilter(), limit: 100).map(\.path).sorted()
        let (database, taxonomy, records) = try freshIndex(w)
        try await records.rebuild()
        let learner = RecordingLearner()
        var services = w.h.services
        services = PipelineServices(
            database: database, config: services.config, settings: services.settings, taxonomy: taxonomy,
            extractor: services.extractor, classifier: services.classifier, learner: learner,
            filer: DocumentFiler(database: database, placer: services.filer.placer, index: IndexStore(database: database),
                                 registry: SelfChangeRegistry(ttl: services.config.watcher.selfChangeTTLSeconds)),
            traces: TraceRecorder(database: database, appVersion: "test"), vectors: VectorIndex())
        await IngestCoordinator(services: services).drain()

        let index = IndexStore(database: database)
        for id in w.documents {
            #expect(try await index.body(docID: id)?.contains("EDP electricity") == true, "the text is searchable again")
            #expect(try await index.embedding(docID: id, model: "stub-embed") != nil)
        }
        #expect(Set(await learner.reembedded) == Set(w.documents), "memories get their vectors back")
        #expect(try await DocumentStore(database: database).list(DocumentFilter(), limit: 100).map(\.path).sorted() == paths,
                "reading again moves nothing")
        #expect(await learner.filed.isEmpty, "and decides nothing")
    }

    @Test func aRecordFileEditedByHandIsReadBack() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let url = try await learned(w, w.h.env.config.records.rulesFileName)
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "enabled: true", with: "enabled: false").write(to: url, atomically: true, encoding: .utf8)
        #expect(try await w.records.reconcile() == 1)
        #expect(try await GRDBLearningStore(database: w.h.env.database).rules().first?.enabled == false)
    }

    @Test func logicEditedInTheFileIsTheArchivesLogicAndNoLongerFollowsTheApp() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let logic = LogicStore(database: w.h.env.database, maxChars: w.h.env.config.classification.logicMaxChars)
        try await logic.reset(to: Self.builtin)
        try await w.records.flush()
        let url = try #require(try await w.records.logicFileURL())
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: Self.builtin, with: "Everything by year.").write(to: url, atomically: true, encoding: .utf8)
        #expect(try await w.records.reconcile() == 1)
        #expect(try await logic.current()?.body == "Everything by year.")
        try await logic.sync(builtin: "A newer text shipped with the app.")
        #expect(try await logic.current()?.body == "Everything by year.", "an edit in the file is never overwritten by the app")
    }

    @Test func aLogicFileWrittenByHandIsTheArchivesLogic() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let url = try #require(try await w.records.logicFileURL())
        try "Just the prompt, no front matter.\n".write(to: url, atomically: true, encoding: .utf8)
        let (database, _, records) = try freshIndex(w)
        let summary = try await records.rebuild()
        #expect(summary.logic)
        let logic = try #require(try await LogicStore(database: database, maxChars: 1_000).current())
        #expect(logic.body == "Just the prompt, no front matter." && !logic.followsBuiltin)
    }

    @Test func aChangeNeverOverwritesAnEditMadeByHand() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let url = try await learned(w, w.h.env.config.records.sendersFileName)
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "canonicalName: EDP Comercial", with: "canonicalName: EDP Energia")
            .write(to: url, atomically: true, encoding: .utf8)
        // Before the app has read the edit, something else changes the senders.
        let store = GRDBLearningStore(database: w.h.env.database)
        _ = try await store.saveCorrespondent(Correspondent(
            id: 0, canonicalName: "MEO", country: "PT", aliases: [], stableKeys: [], emailDomains: [], webDomains: [],
            defaultFolderCode: nil, filedCount: 1, origin: .learned))
        try await w.records.flush()
        let names = try await store.correspondents().map(\.canonicalName).sorted()
        #expect(names == ["EDP Energia", "MEO"])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("EDP Energia"))
    }

    @Test func aDeletedRecordFileIsWrittenAgain() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let url = try await learned(w, w.h.env.config.records.sendersFileName)
        try FileManager.default.removeItem(at: url)
        try await w.records.reconcile()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("EDP Comercial"), "deleting a file does not delete what it records")
        #expect(try await GRDBLearningStore(database: w.h.env.database).correspondents().count == 1)
    }

    @Test func aDocumentsEntryFollowsItAndAnEmptiedDirectoryLosesItsFile() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let other = try await w.h.env.folder("Rent", area: "Home")
        let doc = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        let oldListing = doc.url.deletingLastPathComponent().appendingPathComponent(w.h.env.config.taxonomy.documentsFileName)
        for id in w.documents {
            try await ReviewActions(services: w.h.services, coordinator: w.h.coordinator).move(id, toFolder: other.id)
        }
        try await w.records.flush()
        let moved = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        let newListing = moved.url.deletingLastPathComponent().appendingPathComponent(w.h.env.config.taxonomy.documentsFileName)
        #expect(try String(contentsOf: newListing, encoding: .utf8).contains("uid: \(moved.uid)"))
        #expect(!FileManager.default.fileExists(atPath: oldListing.path), "a directory with no documents keeps no listing")
    }

    @Test func aLostIndexFindsDocumentsAtAnyDepth() async throws {
        let path = ["Portugal", "Hlistan Zolerani LDA", "Banking", "Santander"]
        let deep = FolderSpec(parentCode: nil, levels: path.map { FolderLevel(name: $0, description: "\($0).") },
                              yearSubfolders: true, yearRule: .documentDate)
        let h = try await Harness.make(classifier: StubClassifier(newFolder: deep, band: .auto))
        defer { h.env.cleanup() }
        for (name, text) in [("july.txt", "Santander July"), ("august.txt", "Santander August")] {
            await h.coordinator.enqueue(try h.env.drop(name, text: text))
        }
        await h.coordinator.drain()
        try await ArchiveRecords(database: h.env.database, settings: h.env.settings, taxonomy: h.env.taxonomy, config: h.env.config,
                                 registry: nil).flush()
        let before = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let santander = try #require(before.folders.first { $0.name == "Santander" })
        let banking = try #require(santander.parentCode.flatMap(before.folder(code:)))
        let dropped = [before.url(for: banking).appendingPathComponent("overview.txt"),
                       before.url(for: santander).appendingPathComponent("2025/old-statement.txt")]
        for url in dropped {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("put there by hand".utf8).write(to: url)
        }

        let database = try AppDatabase.inMemory()
        let taxonomy = TaxonomyStore(database: database, config: h.env.config.taxonomy, registry: nil)
        let summary = try await ArchiveRecords(database: database, settings: h.env.settings, taxonomy: taxonomy, config: h.env.config,
                                               registry: nil).rebuild()
        #expect(summary.documents == 2 && summary.missing == 0)
        #expect(summary.adopted == 2, "files put by hand into any folder are adopted, whatever its depth")
        let after = try await taxonomy.snapshot(root: h.env.archive)
        let found = try #require(after.folder(code: santander.code))
        let adoptions = try await JobStore(database: database).active(kinds: [.adopt])
        #expect(Set(adoptions.map(\.sourcePath)) == Set(dropped.map(\.standardizedFileURL.path)))
        let rebuiltBanking = try #require(after.folder(code: banking.code))
        #expect(Set(adoptions.compactMap(\.payload.userFolderID)) == [rebuiltBanking.id, found.id], "each in the folder the user put it in")
        #expect(after.lineage(of: found).map(\.code) == before.lineage(of: santander).map(\.code), "the tree comes back with its codes")
        #expect(after.path(of: found) == path.joined(separator: " / ") && found.yearSubfolders)
        let documents = try await DocumentStore(database: database).list(DocumentFilter(), limit: 10)
        #expect(documents.count == 2 && documents.allSatisfy { $0.folderId == found.id },
                "documents in its year folder belong to the folder four levels down")
    }

    @Test func theSystemAreaIsFoundWhateverItIsCalled() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let config = env.config
        #expect(!ArchiveRecords.mayHoldRecords(archive: env.archive, config: config), "an archive that does not exist yet")
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        #expect(!ArchiveRecords.mayHoldRecords(archive: env.archive, config: config), "an empty archive")
        _ = try await env.taxonomy.ensureSystemFolder(.logic, root: env.archive)
        #expect(ArchiveRecords.mayHoldRecords(archive: env.archive, config: config), "System / Logic, as a new archive has it")

        // Writes `_about.md` files along a chain of directories under a new root.
        func layout(_ levels: [(directory: String, definition: FolderDefinition)]) throws -> URL {
            let root = env.archive.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
            var dir = root
            for level in levels {
                dir = dir.appendingPathComponent(level.directory, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let about = AboutFile(definition: level.definition, body: "")
                try Data(try about.render(hash: .recompute).utf8).write(to: dir.appendingPathComponent(config.taxonomy.aboutFileName))
            }
            return root
        }
        func definition(_ code: String, _ name: String, role: FolderRole? = nil, origin: FolderOrigin) -> FolderDefinition {
            FolderDefinition(code: code, name: name, role: role, description: name, yearSubfolders: false, yearRule: nil,
                             autoFile: false, origin: origin)
        }
        let earlier = try layout([("00-09 System", definition("00-09", "System", origin: .system)),
                                  ("05 Learned", definition("05", "Learned", role: .learned, origin: .system))])
        #expect(ArchiveRecords.mayHoldRecords(archive: earlier, config: config), "the numbered layout of earlier versions")
        let lookalike = try layout([("System", definition("F1", "System", origin: .learned)),
                                    ("Learned", definition("F2", "Learned", origin: .learned))])
        #expect(!ArchiveRecords.mayHoldRecords(archive: lookalike, config: config), "a folder of the user's that is only named so")
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
