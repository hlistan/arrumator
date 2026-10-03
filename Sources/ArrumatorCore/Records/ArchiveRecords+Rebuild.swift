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
    /// which every archive the app has written records into has. What decides whether an index that cannot be opened
    /// may be set aside to be rebuilt (`AppDatabase.open`); whether a new index has anything to be rebuilt from is
    /// decided by walking the archive whole when it is opened (`rebuildIfPending`).
    public static func mayHoldRecords(archive: URL, config: PipelineConfig) -> Bool {
        let layout = ArchiveLayout(root: archive, records: config.records, watcher: config.watcher)
        return FileManager.default.fileExists(atPath: layout.system.path)
            || FileManager.default.fileExists(atPath: archive.appendingPathComponent(config.records.documentsFileName).path)
    }

    /// Whether the archive holds record files a rebuild could read, or may: one in a folder that cannot be listed, or
    /// anywhere in an archive whose folder is not there.
    func archiveHasRecords() async throws -> Bool {
        let walk = await recordFiles()
        return !walk.records.isEmpty || !walk.unlisted.isEmpty
    }

    /// Rebuilds the index from the archive when it is still to be (`AppDatabase.pendingRebuild`): it was created or set
    /// aside, or its rebuild was refused or cut short. A new index whose archive, walked whole now, holds no record file
    /// has nothing to rebuild from, and is complete as it is; one whose rebuild was refused or cut short is complete only
    /// once rebuilt, as the archive held records when it was read. An archive whose folder is not there is away, and
    /// its rebuild is refused, naming the folder. What the rebuild found, or nil when there was nothing to rebuild.
    public func rebuildIfPending() async throws -> RebuildSummary? {
        try await inTurn {
            guard let pending = try await database.pendingRebuild() else { return nil }
            if pending == .unread, try await !archiveHasRecords(), try await completeAsEmpty() { return nil }
            return try await rebuildInTurn()
        }
    }

    /// Takes the index, found to have nothing to read in its archive, for complete, unless it was refused or its rebuild
    /// began meanwhile: decided in the transaction that completes it. Whether the index is complete once it has run, as
    /// it is too when another process completed it meanwhile, which leaves nothing to rebuild.
    func completeAsEmpty() async throws -> Bool {
        try await database.writer.write { db in
            guard let pending = try AppDatabase.pendingRebuild(db) else { return true }
            guard pending == .unread, try !AppDatabase.rebuildWasRefused(db) else { return false }
            try AppDatabase.setPendingRebuild(db, nil)
            return true
        }
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
        for attempt in 1...Self.maxRebuildAttempts {
            try await flushInTurn()
            let before = try await indexState()
            let (parsed, unreadable) = await readArchive()
            for file in unreadable { noteUnreadable(file) }
            guard unreadable.isEmpty else {
                // So a change the index then refuses can name them, in any process (`AppDatabase.explained`).
                try await database.writer.write { db in try AppDatabase.setRebuildRefused(db, unreadable) }
                guard archiveIsThere else { throw RecordsError.archiveNotThere(archive.path) }
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
            try await locateDocuments(summary: &summary)
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
            let unread = try AppDatabase.pendingRebuild(db) == .unread
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

    /// Finds documents whose file is not where their entry says by the identifier on each file, files a document marked
    /// missing whose file is found, and takes in files that no entry describes. Each document found keeps the inode its
    /// file has, which the record files do not hold, by which the archive watcher tells it from a copy
    /// (`ArchiveReconciler`): it is written with where the document is, in one transaction.
    private func locateDocuments(summary: inout RebuildSummary) async throws {
        let documents = try await DocumentStore(database: database, time: time).list(DocumentFilter(), limit: Int.max)
        let byUID = Dictionary(documents.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        let skip = SkipRules(watcher: config.watcher)
        var found: [String: String] = [:]
        var untracked: [String] = []
        // The walk leaves out Incoming and the folders the watcher ignores.
        for url in await recordFiles().files where skip.ignoreReason(url) == nil {
            if let uid = Xattr.get(Xattr.documentID, from: url), let document = byUID[uid] {
                // A file carrying it where the document is recorded is its file, before any other that carries it.
                if found[uid] != document.path { found[uid] = url.path }
            } else {
                untracked.append(url.path)
            }
        }
        var located: [DocumentRecord] = []
        for var document in documents {
            let path = found[document.uid]
            if document.status == .missing {
                guard let path else { continue }
                if path != document.path { summary.relocated += 1 }
                document.path = path
                document.status = .filed
            } else if let path, path != document.path,
                      archive.holds(document.path) || !FileManager.default.fileExists(atPath: document.path) {
                // Its file, by the identifier on it, is elsewhere in the archive: the document follows it, as the archive
                // watcher has it follow (`ArchiveReconciler`), and a file left where it was recorded, as a copy without
                // the identifier, is taken in as a document of its own. One left in Incoming stays with its file there.
                document.path = path
                summary.relocated += 1
            } else if path == nil, !FileManager.default.fileExists(atPath: document.path) {
                document.status = .missing
                summary.missing += 1
            }
            let inode = document.status == .missing ? nil : FileOnDisk(document.url)?.number
            guard document != byUID[document.uid] || inode != document.inode else { continue }
            document.inode = inode ?? document.inode
            located.append(document)
        }
        let now = time.now()
        try await database.writer.write { [located] db in
            for var document in located {
                document.updatedAt = now
                try document.update(db)
            }
        }
        // A file put into the archive by hand is read and labelled where it is; the system folder holds no documents. A
        // file without an identifier where a document not found elsewhere is recorded, as one whose identifier a copy
        // or a synchronisation left off, is that document's, as the archive watcher takes it (`ArchiveReconciler`).
        let recordedAt = Set(documents.filter { $0.status != .missing && found[$0.uid] == nil }.map(\.path))
        let jobs = JobStore(database: database, time: time)
        for path in untracked where !layout.isSystem(URL(fileURLWithPath: path)) && !recordedAt.contains(path) {
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
