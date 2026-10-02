import Foundation
import GRDB

/// What a rebuild found in the archive.
public struct RebuildSummary: Sendable, Codable, Hashable {
    public var documents = 0
    public var events = 0
    /// The user's rules for labels.
    public var labelRules = 0
    /// The user's search tasks.
    public var searchTasks = 0
    /// Documents found somewhere other than where their entry said, by the identifier on the file.
    public var relocated = 0
    /// Documents whose file is nowhere in the archive.
    public var missing = 0
    /// Files in the archive without an entry, taken in as new.
    public var adopted = 0
    /// Documents queued to have their text read and their embedding computed again.
    public var queued = 0

    public var summary: String {
        "Rebuilt the index from the archive: \(Format.count(documents, "document")), "
            + "\(Format.count(events, "history event")), \(Format.count(labelRules, "rule")) for labels, "
            + "\(Format.count(searchTasks, "search task")); "
            + "\(relocated) found elsewhere, \(missing) missing, \(adopted) taken in"
    }
}

extension ArchiveRecords {
    // MARK: Rebuilding

    /// Cheaply, without walking the archive: whether it has the system folder, or a list of documents at its top,
    /// which every archive the app has written records into has.
    public static func mayHoldRecords(archive: URL, config: PipelineConfig) -> Bool {
        let layout = ArchiveLayout(root: archive, records: config.records, watcher: config.watcher)
        return FileManager.default.fileExists(atPath: layout.system.path)
            || FileManager.default.fileExists(atPath: archive.appendingPathComponent(config.records.documentsFileName).path)
    }

    /// Whether the archive holds record files a rebuild could read.
    func archiveHasRecords() async throws -> Bool {
        let root = await settings.current.archiveURL
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        let walk = await recordFiles()
        return !walk.records.isEmpty || !walk.unlisted.isEmpty
    }

    /// Rebuilds the index from the archive when it is still to be (`AppDatabase.pendingRebuild`): it was created or set
    /// aside, or its rebuild was refused or cut short. An archive without record files has nothing to rebuild from: its
    /// new index is complete as it is. What the rebuild found, or nil when there was nothing to rebuild.
    public func rebuildIfPending() async throws -> RebuildSummary? {
        guard try await database.pendingRebuild() != nil else { return nil }
        guard try await archiveHasRecords() else {
            try await database.writer.write { db in try AppDatabase.setPendingRebuild(db, nil) }
            return nil
        }
        return try await rebuild()
    }

    /// Reads the whole archive into the index, replacing what it held: documents, history, the rules for labels, the
    /// search tasks and the conversations about their documents, in one transaction. Then documents are located by the
    /// identifier on each file, files without an entry are taken in, and every document is queued to have its text read
    /// and its embedding computed again. Changes the index holds that the record files do not are written into them
    /// first, so nothing the app knows is lost; an index that has read nothing of the archive yet has none.
    ///
    /// A record file, or a folder of the archive, that cannot be read stops it before anything changes
    /// (`RecordsError.unreadableFiles`, naming each and why): going on without it would leave the index without what it
    /// holds, and what the app then did would be written over it once it read again. The index stays to be rebuilt,
    /// and is worked on by nothing until it is (AGENTS.md §4.2). The rebuild says so in the index in the transaction that
    /// replaces it, and its last step, with its History event, clears that, so one cut short is finished at the next
    /// opening (`rebuildIfPending`).
    @discardableResult
    public func rebuild() async throws -> RebuildSummary {
        try await inTurn { try await rebuildInTurn() }
    }

    /// Times a rebuild writes the files and reads the archive again because the index changed while it read it, before
    /// it gives up: each time, what changed was written into the files first, so only a change after that keeps it going.
    static let maxRebuildAttempts = 3

    private func rebuildInTurn() async throws -> RebuildSummary {
        let root = await settings.current.archiveURL
        for attempt in 1...Self.maxRebuildAttempts {
            try await flushInTurn()
            let before = try await indexState()
            let (parsed, unreadable) = await readArchive()
            for file in unreadable { noteUnreadable(file) }
            guard unreadable.isEmpty else {
                // So a change the index then refuses can name them, in any process (`AppDatabase.explained`).
                try await database.writer.write { db in try AppDatabase.setRebuildRefused(db, unreadable) }
                throw RecordsError.unreadableFiles(unreadable)
            }
            guard try await replaceIndex(with: parsed, expecting: before) else {
                Log.info(.db, "The index changed while the archive was read for a rebuild; reading it again", ["attempt": String(attempt)])
                continue
            }
            var summary = RebuildSummary()
            summary.documents = parsed.documents.reduce(0) { $0 + $1.entries.count }
            summary.events = parsed.history.reduce(0) { $0 + $1.entries.count }
            summary.labelRules = parsed.labelRules?.count ?? 0
            summary.searchTasks = parsed.searchTasks?.count ?? 0
            try await locateDocuments(root: root, summary: &summary)
            try await queueReindex(summary: &summary)
            // The last step: what was found is recorded, and the index no longer waits to be rebuilt, together.
            let at = time.now()
            try await database.writer.write { [summary] db in
                try HistoryStore.insert(db, .rebuilt, at: at, summary: summary.summary, payload: summary)
                try AppDatabase.setPendingRebuild(db, nil)
            }
            try await flushInTurn()
            Log.info(.db, "Index rebuilt from the archive", ["documents": String(summary.documents), "missing": String(summary.missing),
                                                             "adopted": String(summary.adopted)])
            return summary
        }
        throw RecordsError.changedWhileRebuilding(Self.maxRebuildAttempts)
    }

    /// The checksum of each record file as last written or read, which a file written by this process or another changes.
    struct IndexState: Equatable, Sendable {
        private var files: [String: String]

        /// The same files, with the same checksums.
        static func == (lhs: IndexState, rhs: IndexState) -> Bool { lhs.files == rhs.files }

        static func read(_ db: Database) throws -> IndexState {
            IndexState(files: Dictionary(try Row.fetchAll(db, sql: "SELECT path, hash FROM record_files").map { ($0["path"], $0["hash"]) },
                                         uniquingKeysWith: { a, _ in a }))
        }
    }

    func indexState() async throws -> IndexState {
        try await database.reader.read { db in try IndexState.read(db) }
    }

    /// Replaces what the index holds with `parsed`, the archive as it was read, in one transaction, if the transaction
    /// finds that the index holds no change the files do not and that no file was written since `before` was taken,
    /// before the archive was read: a change committed meanwhile, by the worker or another process, would otherwise be
    /// replaced by files that do not hold it. An index that has read nothing of the archive has no change of its own to
    /// keep, whatever is marked in it. Whether it replaced it; the index then says its rebuild is unfinished.
    func replaceIndex(with parsed: ParsedRecords, expecting before: IndexState) async throws -> Bool {
        let now = time.now()
        return try await database.writer.write { db in
            let unread = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [AppDatabase.rebuildPendingKey])
                .map { AppDatabase.PendingRebuild(rawValue: $0) ?? .unread } == .unread
            let marked = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM record_dirty)") ?? false
            guard try IndexState.read(db) == before, unread || !marked else { return false }
            // First: an unread index refuses every change to what the record files hold (v19), this one's too.
            try AppDatabase.setPendingRebuild(db, .unfinished)
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            let links = try parsed.eventLinks(db, everyMonth: true)
            for table in Self.rebuiltTables { try db.execute(sql: "DELETE FROM \(table)") }
            let applied = try parsed.apply(to: db, replacing: false, at: now, links: links, everyDirectory: true)
            try db.execute(sql: "DELETE FROM record_files")
            for (path, hash) in parsed.hashes where !applied.notTakenIn.contains(path) { try Self.remember(db, path: path, hash: hash) }
            try db.execute(sql: "DELETE FROM record_dirty")
            for kind in applied.rewrite { try Self.mark(db, kind) }
            return true
        }
    }

    /// Every record file of the archive, read: what they hold, and those that cannot be read, each with why.
    func readArchive() async -> (ParsedRecords, [UnreadableRecordFile]) {
        var parsed = ParsedRecords()
        let walk = await recordFiles()
        var unreadable = walk.unlisted
        for (kind, url) in walk.records {
            do {
                guard let text = try RecordFile.text(at: url) else { continue }
                parsed.merge(try ParsedRecords(kind, url: url, text: text))
                noteReadable(url.path)
            } catch let RecordsError.unreadable(path, why) {
                unreadable.append(UnreadableRecordFile(path: path, reason: why))
            } catch {
                unreadable.append(UnreadableRecordFile(path: url.path, reason: error.localizedDescription))
            }
        }
        return (parsed, unreadable)
    }

    /// Tables a rebuild replaces with what the files say, and working state that cannot outlive the old index.
    /// Documents are updated in place instead, never deleted: their numbers come back unchanged, so their cached text,
    /// embeddings and traces stay attached.
    static let rebuiltTables = ["events", "label_rules", "search_task_documents", "search_task_exports", "search_task_turns", "search_tasks"]

    /// Finds documents whose file is not where their entry says by the identifier on each file, takes back a document
    /// marked missing whose file is found, as `ArchiveReconciler` does when it sees one come back, and takes in files
    /// that no entry describes.
    private func locateDocuments(root: URL, summary: inout RebuildSummary) async throws {
        let documents = try await DocumentStore(database: database, time: time).list(DocumentFilter(), limit: Int.max)
        let byUID = Dictionary(documents.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        let skip = SkipRules(watcher: config.watcher)
        var found: [String: String] = [:]
        var untracked: [String] = []
        // The walk leaves out Incoming and the folders the watcher ignores.
        for url in await recordFiles().files where skip.ignoreReason(url) == nil {
            if let uid = Xattr.get(Xattr.documentID, from: url), byUID[uid] != nil {
                found[uid] = url.path
            } else {
                untracked.append(url.path)
            }
        }
        let store = DocumentStore(database: database, time: time)
        for var document in documents {
            let path = found[document.uid]
            if document.status == .missing {
                guard let path else { continue }
                if path != document.path { summary.relocated += 1 }
                document.path = path
                document.status = .filed
            } else if !FileManager.default.fileExists(atPath: document.path) {
                if let path {
                    document.path = path
                    summary.relocated += 1
                } else {
                    document.status = .missing
                    summary.missing += 1
                }
            } else {
                continue
            }
            _ = try await store.save(document)
        }
        // A file put into the archive by hand is read and labelled where it is; the system folder holds no documents.
        let jobs = JobStore(database: database, time: time)
        let layout = layout(root)
        for path in untracked where !layout.isSystem(URL(fileURLWithPath: path)) {
            if try await jobs.enqueue(path: path, kind: .adopt) != nil { summary.adopted += 1 }
        }
    }

    private func queueReindex(summary: inout RebuildSummary) async throws {
        let jobs = JobStore(database: database, time: time)
        for document in try await DocumentStore(database: database, time: time).list(DocumentFilter(), limit: Int.max)
        where document.status != .missing && FileManager.default.fileExists(atPath: document.path) {
            if try await jobs.enqueue(path: document.path, kind: .reindex, docID: document.id) != nil { summary.queued += 1 }
        }
    }
}
