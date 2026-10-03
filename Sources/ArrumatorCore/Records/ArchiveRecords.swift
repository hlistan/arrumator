import Foundation
import GRDB

/// Keeps the archive's record files and the database together (docs/storage.md). Changes reach the index first and
/// are marked by triggers; `flush` writes every marked file from the index. `reconcile` reads back any file that
/// changed on disk, and `rebuild` reads the whole archive into an empty index. A record file is the user's: one that is
/// there is written over or removed only when it holds what the index last wrote or has just read, and one that cannot
/// be read is never taken for absent or empty, but reported (`unreadableFiles`) and left as it is. Flushing, reading
/// back and rebuilding take turns (`inTurn`).
public actor ArchiveRecords {
    let database: AppDatabase
    /// The archive whose record files these are, as it was given when they were opened. The settings may name another
    /// archive meanwhile, as at the end of a switch, and this one's record files never go into it.
    let archive: URL
    let config: PipelineConfig
    private let registry: SelfChangeRegistry?
    let time: any TimeSource
    private let timeZone: TimeZone
    /// Why each record file that cannot be read cannot, by its path, as it was last found.
    private var unreadable: [String: String] = [:]
    /// Whether a flush, a read-back or a rebuild runs, and those waiting for their turn, the first first.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Called with each record file's URL between reading it and writing or removing it: what a test does there is what
    /// another process or the user could do at that moment. Set by tests only.
    private var beforeWriting: (@Sendable (URL) async -> Void)?
    /// Called with each record file's URL between reading it and applying what it holds to the index, as `beforeWriting`
    /// is. Set by tests only.
    private var beforeApplying: (@Sendable (URL) async -> Void)?

    /// - Parameter timeZone: the Mac's, which the moments and days written for people browsing the archive are in.
    public init(database: AppDatabase, archive: URL, config: PipelineConfig, registry: SelfChangeRegistry?,
                time: any TimeSource, timeZone: TimeZone) {
        self.timeZone = timeZone
        self.database = database
        self.archive = archive.standardizedFileURL
        self.config = config
        self.registry = registry
        self.time = time
    }

    /// Where things are in this archive.
    var layout: ArchiveLayout {
        ArchiveLayout(root: archive, records: config.records, watcher: config.watcher)
    }

    // MARK: Taking turns

    /// Runs `body` when no other flush, read-back or rebuild of this actor runs, and before the next. Each awaits the
    /// index between reading a file and writing it; one that entered there would take the file the other had just
    /// written, its checksum not yet remembered, for an edit by hand, and merge it back over newer changes. A flush that
    /// waits writes, when its turn comes, everything marked by then, so flushes queued behind each other find little
    /// left to write.
    func inTurn<T>(_ body: () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        return try await body()
    }

    /// How many flushes, read-backs and rebuilds wait for their turn.
    var waitingTurns: Int { waiting.count }

    func setBeforeWriting(_ hook: (@Sendable (URL) async -> Void)?) {
        beforeWriting = hook
    }

    func setBeforeApplying(_ hook: (@Sendable (URL) async -> Void)?) {
        beforeApplying = hook
    }

    /// Whether the index has read nothing of the archive yet (`AppDatabase.PendingRebuild.unread`): until its rebuild
    /// succeeds, nothing is read into it from the record files, nor written into them from it, as it would fill them with
    /// what it lacks.
    private func isUnread() async throws -> Bool {
        try await database.pendingRebuild() == .unread
    }

    // MARK: Files that cannot be read

    /// The record files that could not be read when they were last read, and why: the app neither reads nor writes them
    /// until they read again, and what the index holds for them waits.
    public func unreadableFiles() -> [UnreadableRecordFile] {
        unreadable.map { UnreadableRecordFile(path: $0.key, reason: $0.value) }.sorted { $0.path < $1.path }
    }

    func noteUnreadable(_ file: UnreadableRecordFile) {
        guard unreadable[file.path] != file.reason else { return }
        unreadable[file.path] = file.reason
        Log.error(.db, "Record file cannot be read; it is neither read nor written until it can", ["path": file.path, "reason": file.reason])
    }

    func noteReadable(_ path: String) {
        guard unreadable.removeValue(forKey: path) != nil else { return }
        Log.info(.db, "Record file reads again", ["path": path])
    }

    // MARK: Writing files from the index

    /// Rendering a file can itself mark others (a file edited by hand is read first), so flushing repeats, a bounded
    /// number of times, until nothing is marked.
    static let maxFlushPasses = 4

    /// Writes every record file a change has made stale. A file changed again while it is written stays marked and is
    /// written again. A file that cannot be read is left as it is and stays marked, so its changes are written once it
    /// reads again; it is reported, not thrown, as it waits for the user. A file that cannot be written throws.
    @discardableResult
    public func flush() async throws -> Int {
        try await inTurn { try await flushInTurn() }
    }

    /// `flush`, for one that already has its turn.
    @discardableResult
    func flushInTurn() async throws -> Int {
        guard try await !isUnread() else {
            Log.warning(.db, "Record files not written: the index has not been rebuilt from the archive yet")
            return 0
        }
        var written = 0
        var failures: [String: any Error] = [:]
        var unreadableKeys: Set<String> = []
        for _ in 0..<Self.maxFlushPasses {
            let marks = try await database.reader.read { db in
                try Row.fetchAll(db, sql: "SELECT key, version FROM record_dirty").map { ($0["key"] as String, $0["version"] as Int64) }
            }.filter { failures[$0.0] == nil && !unreadableKeys.contains($0.0) }
            guard !marks.isEmpty else { break }
            for (key, version) in marks {
                guard let kind = RecordKind(key: key) else {
                    Log.warning(.db, "Unknown record mark dropped", ["key": key])
                    try await unmark(key, version: version)
                    continue
                }
                do {
                    switch try await render(kind) {
                    case .written:
                        written += 1
                        try await unmark(key, version: version)
                    case .unchanged: try await unmark(key, version: version)
                    case .changedMeanwhile: continue
                    }
                } catch let error as CancellationError {
                    throw error
                } catch let RecordsError.unreadable(path, why) {
                    noteUnreadable(UnreadableRecordFile(path: path, reason: why))
                    unreadableKeys.insert(key)
                } catch {
                    // One file that cannot be written keeps its mark to be tried again; the others still are written.
                    failures[key] = error
                    Log.error(.db, "Could not write record file", ["key": key, "error": error.localizedDescription])
                }
            }
        }
        if written > 0 { Log.debug(.db, "Record files written", ["files": String(written)]) }
        if let (key, error) = failures.first { throw RecordsError.notWritten(key, error.localizedDescription) }
        return written
    }

    private func unmark(_ key: String, version: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM record_dirty WHERE key = ? AND version = ?", arguments: [key, version])
        }
    }

    /// What writing one record file came to.
    private enum Rendering {
        /// The file was written or removed.
        case written
        /// It already held what the index has.
        case unchanged
        /// It changed on disk between being read and being written, so it was left to be read again first.
        case changedMeanwhile
    }

    /// Writes one record file from the index. A file that does not hold what the app last wrote or read, an edit by hand
    /// or one the index has never read, is read first, so it is never written over unread.
    private func render(_ kind: RecordKind) async throws -> Rendering {
        guard let url = recordURL(of: kind) else { return .unchanged }
        let held = try await readUnlessKnown(kind, url: url)
        let text = try await composed(kind, at: url)
        await beforeWriting?(url)
        guard let text else { return try await remove(url, holding: held) }
        if case .documents = kind {
            // A directory that is gone is not made again for its list.
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return .unchanged }
            return try await write(text, to: url, holding: held)
        }
        return try await write(text, to: try directoryMade(for: url), holding: held)
    }

    /// Where the record file of `kind` is; nil for documents outside the archive, which have no list.
    private func recordURL(of kind: RecordKind) -> URL? {
        switch kind {
        case let .documents(directory):
            // Documents are filed at the top of the archive, or kept where an earlier version filed them below it.
            guard directory == archive.path || directory.hasPrefix(archive.path + "/") else { return nil }
            return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(config.records.documentsFileName)
        case let .history(month): return layout.historyFile(month: month)
        case .labelRules: return layout.labelRules
        case .searchTasks: return layout.searchTasks
        case let .conversation(task): return layout.conversationFile(task: task)
        }
    }

    /// The record file of `kind`, at `url`, as the index has it now; nil when the index holds nothing for it, which then
    /// has no file.
    private func composed(_ kind: RecordKind, at url: URL) async throws -> String? {
        switch kind {
        case let .documents(directory):
            let entries = try await database.reader.read { db in
                try DocumentRecord.fetchAll(db, sql: "SELECT * FROM documents WHERE rtrim(path, replace(path, '/', '')) = ? ORDER BY path",
                                            arguments: [directory + "/"]).compactMap(DocumentEntry.init)
            }
            guard !entries.isEmpty else { return nil }
            return try FrontMatter.compose(RecordList(entries), body: RecordText.documents(entries, in: url.deletingLastPathComponent()))
        case let .history(month):
            let entries = try await database.reader.read { db in
                try EventRecord.fetchAll(db, sql: "SELECT * FROM events WHERE strftime('%Y-%m', at, 'unixepoch') = ? ORDER BY at, id",
                                         arguments: [month]).compactMap(EventEntry.init)
            }
            guard !entries.isEmpty else { return nil }
            return try FrontMatter.compose(RecordList(entries), body: RecordText.history(entries, month: month, in: timeZone))
        case .labelRules:
            let entries = try await database.reader.read { db in
                try LabelRule.order(Column("id")).fetchAll(db).compactMap(LabelRuleEntry.init)
            }
            guard !entries.isEmpty else { return nil }
            return try FrontMatter.compose(RecordList(entries), body: RecordText.labelRules(entries, in: timeZone))
        case .searchTasks:
            let entries = try await database.reader.read { db in try SearchTaskStore.entries(db) }
            guard !entries.isEmpty else { return nil }
            return try FrontMatter.compose(RecordList(entries), body: RecordText.searchTasks(entries))
        case let .conversation(task):
            let tasks = config.tasks
            let (entries, name, documents) = try await database.reader.read { db -> ([ConversationTurnEntry], String?, [Int64: String]) in
                let entries = try TaskConversationStore.entries(db, task: task)
                let name = try SearchTaskRecord.fetchOne(db, key: task).map { SearchTaskStore.name($0, config: tasks) }
                let named = Set(entries.flatMap { ($0.sources ?? []) + ($0.finding?.documents ?? []) })
                let documents = Dictionary(try DocumentRecord.fetchAll(db, keys: Array(named)).compactMap { d in d.id.map { ($0, d.filename) } },
                                           uniquingKeysWith: { a, _ in a })
                return (entries, name, documents)
            }
            guard let name, !entries.isEmpty else { return nil }
            return try FrontMatter.compose(RecordList(entries), body: RecordText.conversation(entries, task: name, documents: documents, in: timeZone))
        }
    }

    // MARK: Files and their checksums

    /// `url`, with the directory it goes in made first: the system folder appears when it is first needed. Never in an
    /// archive whose folder is not there, renamed or on a disk that went, which a folder made in its place would hide:
    /// its files stay marked, and are written once it is back.
    private func directoryMade(for url: URL) throws -> URL {
        guard archiveIsThere else { throw RecordsError.archiveNotThere(archive.path) }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RecordsError.unwritable(directory.path, error.localizedDescription)
        }
        return url
    }

    /// The checksum of each record file as last written or read, by its path.
    func knownHashes() async throws -> [String: String] {
        try await database.reader.read { db in
            Dictionary(try Row.fetchAll(db, sql: "SELECT path, hash FROM record_files").map { ($0["path"] as String, $0["hash"] as String) },
                       uniquingKeysWith: { a, _ in a })
        }
    }

    private func knownHash(of url: URL) async throws -> String? {
        try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT hash FROM record_files WHERE path = ?", arguments: [url.path])
        }
    }

    /// Writes `text` atomically to `url`, whose file held `held` when it was read (nil: there was none), and remembers
    /// its checksum. A file that holds anything else by now was changed meanwhile, and is not written over.
    private func write(_ text: String, to url: URL, holding held: String?) async throws -> Rendering {
        let hash = FrontMatter.sha256(text)
        await registry?.expect([url.path, url.deletingLastPathComponent().path])
        let current = try RecordFile.text(at: url).map(FrontMatter.sha256)
        guard current == held else { return .changedMeanwhile }
        if current != hash {
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                throw RecordsError.unwritable(url.path, error.localizedDescription)
            }
        }
        try await remember(url, hash: hash)
        return current == hash ? .unchanged : .written
    }

    /// Removes the file at `url`, now that the index holds nothing for it, if it still holds `held`: what the index wrote
    /// or has just read. One changed meanwhile is left to be read again.
    private func remove(_ url: URL, holding held: String?) async throws -> Rendering {
        await registry?.expect([url.path, url.deletingLastPathComponent().path])
        let current = try RecordFile.text(at: url).map(FrontMatter.sha256)
        guard current == held else { return .changedMeanwhile }
        if current != nil {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw RecordsError.unwritable(url.path, error.localizedDescription)
            }
        }
        try await database.writer.write { db in try db.execute(sql: "DELETE FROM record_files WHERE path = ?", arguments: [url.path]) }
        return current == nil ? .unchanged : .written
    }

    private func remember(_ url: URL, hash: String) async throws {
        try await database.writer.write { db in try Self.remember(db, path: url.path, hash: hash) }
    }

    static func remember(_ db: Database, path: String, hash: String) throws {
        try db.execute(sql: "INSERT INTO record_files(path, hash) VALUES(?, ?) ON CONFLICT(path) DO UPDATE SET hash = excluded.hash",
                       arguments: [path, hash])
    }

    // MARK: Reading files into the index

    /// Reads every record file that changed on disk since the app last wrote or read it (an edit by hand, a copy
    /// synchronised from another Mac, a crash between the index and the file), then writes whatever is still stale.
    /// Each file is read on its own: one that cannot be read is reported (`unreadableFiles`) and keeps none of the others
    /// from being read, nor the archive from being opened.
    @discardableResult
    public func reconcile() async throws -> Int {
        try await inTurn { try await reconcileInTurn() }
    }

    private func reconcileInTurn() async throws -> Int {
        guard try await !isUnread() else {
            Log.warning(.db, "Record files not read: the index has not been rebuilt from the archive yet")
            return 0
        }
        let walk = await recordFiles()
        for folder in walk.unlisted { noteUnreadable(folder) }
        // Nothing of an archive that is not there is read, taken for gone or written again.
        guard archiveIsThere else { throw RecordsError.archiveNotThere(archive.path) }
        var merging = try await owesMerge()
        if merging { try await forgetFiles() }
        let known = try await knownHashes()
        var reread = 0
        for (kind, url) in walk.records {
            do {
                // Gone since the listing: the next read finds it gone.
                guard let text = try RecordFile.text(at: url) else { continue }
                if known[url.path] != FrontMatter.sha256(text) {
                    // Another folder put in place while this one is read: what is read from now on, and every file
                    // before it is written, is merged (`forgetFiles`), asked once what was read is in hand.
                    if !merging, try await owesMerge() {
                        try await forgetFiles()
                        merging = true
                    }
                    try await read(kind, url: url, text: text, replacing: nil)
                    reread += 1
                }
                noteReadable(url.path)
            } catch let RecordsError.unreadable(path, why) {
                noteUnreadable(UnreadableRecordFile(path: path, reason: why))
            }
        }
        let present = Set(walk.records.map(\.1.path) + walk.unlisted.map(\.path))
        unreadable = unreadable.filter { present.contains($0.key) }
        // A file in a folder that was not, or could not be, looked into is not known to be gone.
        for path in known.keys where !present.contains(path) && !walk.hides(path) {
            // A record file that disappeared is written again from the index: deleting it is not deleting its records.
            let kind = kind(of: URL(fileURLWithPath: path))
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM record_files WHERE path = ?", arguments: [path])
                if let kind { try Self.mark(db, kind) }
            }
        }
        if reread > 0 { Log.info(.db, "Record files read again", ["files": String(reread)]) }
        // Read merged: what is marked for a file that could not be read keeps it merged once it can be.
        if merging { try await database.writer.write { db in try AppDatabase.setMeta(db, Self.mergeOwedKey, nil) } }
        try await flushInTurn()
        return reread
    }

    /// Reads the file at `url` into the index unless it holds what the index last wrote or read. An edit by hand, or a
    /// file the index has never read, such as one a rebuild could not read or one another Mac synchronised, is merged in
    /// before anything is written over it: the index has changes of its own for it. The checksum of what the file holds
    /// now; nil when there is no file.
    private func readUnlessKnown(_ kind: RecordKind, url: URL) async throws -> String? {
        guard let text = try RecordFile.text(at: url) else { return nil }
        let hash = FrontMatter.sha256(text)
        let known = try await knownHash(of: url)
        if known != hash {
            Log.info(.db, known == nil ? "Record file the index has not read; reading it before writing" : "Record file changed by hand; merging it before writing",
                     ["path": url.path])
            try await read(kind, url: url, text: text, replacing: false)
        }
        noteReadable(url.path)
        return hash
    }

    /// Reads one record file, whose text is `text`, into the index. Replacing also removes what the file no longer
    /// lists; merging only adds and updates, and leaves the file marked so it is written with both. With `replacing`
    /// nil, the write that applies the file decides: it merges when the index has changes of its own for the file (its
    /// kind is marked), as a change committed after anything else was read would otherwise be replaced. A list of
    /// documents that leaves out a document the index has in its directory, or whose entries were given numbers of
    /// their own, is marked again, to be written with them.
    private func read(_ kind: RecordKind, url: URL, text: String, replacing: Bool?) async throws {
        let parsed = try ParsedRecords(kind, url: url, text: text)
        let now = time.now()
        await beforeApplying?(url)
        try await database.writer.write { db in
            let replacing = try replacing ?? !(Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM record_dirty WHERE key = ?)",
                                                              arguments: [kind.key]) ?? false)
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            let applied = try parsed.apply(to: db, replacing: replacing, at: now, links: try parsed.eventLinks(db, everyMonth: false),
                                           everyDirectory: false)
            for (path, hash) in parsed.hashes where !applied.notTakenIn.contains(path) { try Self.remember(db, path: path, hash: hash) }
            if replacing { try db.execute(sql: "DELETE FROM record_dirty WHERE key = ?", arguments: [kind.key]) }
            for kind in applied.rewrite { try Self.mark(db, kind) }
        }
    }

    /// Kept in the index, in the one write that names another folder as the archive's (`ArchiveWatcher`), until the
    /// record files of that folder are read merged with the index (`reconcile`).
    static let mergeOwedKey = "archive_folder_merge_owed"
    static let mergeOwed = "yes"

    /// Whether the record files at the archive's path are to be merged with the index rather than read as edits: another
    /// folder was taken as the archive, or the earlier one is back, and they have not been read merged since
    /// (`mergeOwedKey`); or the folder there is not the one the index was kept for (`ArchiveWatcher.folderKey`), as one
    /// the watcher has not seen yet, or none. Decided by the read itself, which another folder may be put in place of at
    /// any time.
    private func owesMerge() async throws -> Bool {
        if try await database.meta(Self.mergeOwedKey) != nil { return true }
        guard let kept = try await database.meta(ArchiveWatcher.folderKey).flatMap(FolderIdentity.init(stored:)) else { return false }
        // No folder there, as between another taken away and one put in its place, is not the one kept for either.
        return ArchiveDisk.disk.identity(of: archive) != kept
    }

    /// The archive's folder is another than the one the index last read and wrote its record files in, or the earlier one
    /// back (`owesMerge`): its files are not the ones the index knows, and their changes are no edits to take over what
    /// the index holds. No file is known any more and every kind is marked, so each file is read next merged with the
    /// index (`read`, which merges what is marked), never replacing it: what was decided meanwhile, such as a rule for
    /// labels, a task or a question, is kept, and written into the folder that is now the archive. For one that has its
    /// turn.
    private func forgetFiles() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM record_files")
            try Self.markEvery(db)
        }
        Log.info(.db, "Record files of another archive folder are merged with the index", ["archive": archive.path])
    }

    /// Marks every record file the index has anything for.
    static func markEvery(_ db: Database) throws {
        let upsert = " ON CONFLICT(key) DO UPDATE SET version = version + 1"
        try db.execute(sql: "INSERT INTO record_dirty(key, version) SELECT DISTINCT ? || rtrim(path, replace(path, '/', '')), 1 FROM documents WHERE 1"
                           + upsert, arguments: [RecordKind.documentsPrefix])
        try db.execute(sql: "INSERT INTO record_dirty(key, version) SELECT DISTINCT ? || strftime('%Y-%m', at, 'unixepoch'), 1 FROM events WHERE 1"
                           + upsert, arguments: [RecordKind.historyPrefix])
        try db.execute(sql: "INSERT INTO record_dirty(key, version) SELECT DISTINCT ? || task_id, 1 FROM search_task_turns WHERE 1" + upsert,
                       arguments: [RecordKind.conversationPrefix])
        if try LabelRule.fetchCount(db) > 0 { try mark(db, .labelRules) }
        if try SearchTaskRecord.fetchCount(db) > 0 { try mark(db, .searchTasks) }
    }

    static func ids(_ values: [Int64]) -> String {
        values.isEmpty ? "NULL" : values.map(String.init).joined(separator: ",")
    }

    static func mark(_ db: Database, _ kind: RecordKind) throws {
        try db.execute(sql: "INSERT INTO record_dirty(key, version) VALUES (?, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1",
                       arguments: [kind.key])
    }
}

extension ArchiveRecords {
    // MARK: Finding record files

    /// Why a folder the file system gives no listing of at all is not read.
    static let notListed = "it cannot be listed"
    /// Why an archive whose folder is not there is not read: what it holds is not known, as on a disk that is not
    /// mounted or a cloud folder not connected, so it is neither taken for an archive without records nor written into.
    static let notThere = "no folder is there"

    /// What walking the archive found.
    struct ArchiveWalk {
        /// Every regular file in it, hidden files and package contents aside.
        var files: [URL] = []
        /// The record files among them, with the kind each holds.
        var records: [(RecordKind, URL)] = []
        /// The folders that are there but cannot be listed, each with why: what they hold is not known to be absent.
        var unlisted: [UnreadableRecordFile] = []
        /// The folders not looked into: those the watcher ignores. Incoming is never inside the archive
        /// (`AppSettings.problems`).
        var skipped: [String] = []

        /// Whether `path` is in a folder that was not, or could not be, looked into.
        func hides(_ path: String) -> Bool {
            (skipped + unlisted.map(\.path)).contains { path.hasPrefix($0 + "/") }
        }
    }

    /// Walks the archive at `root`, leaving out the folders `skip` ignores, as nothing in them is a document of the archive
    /// or a record file.
    static func walk(_ root: URL, skip: SkipRules) -> ArchiveWalk {
        var walk = ArchiveWalk()
        // The archive itself not there is no archive without record files, unlike a folder gone while it is walked.
        guard isFolder(root) else {
            walk.unlisted = [UnreadableRecordFile(path: root.standardizedFileURL.path, reason: notThere)]
            return walk
        }
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) { url, error in
            // One gone while the folder is walked is simply not there.
            if (error as? CocoaError)?.code != .fileReadNoSuchFile {
                walk.unlisted.append(UnreadableRecordFile(path: url.standardizedFileURL.path, reason: error.localizedDescription))
            }
            return true
        }
        guard let walker else {
            walk.unlisted = [UnreadableRecordFile(path: root.standardizedFileURL.path, reason: notListed)]
            return walk
        }
        for case let url as URL in walker {
            // Listings resolve /var to /private/var; standardizing gives the paths the index stores.
            let url = url.standardizedFileURL
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true, skip.isIgnoredDirectory(named: url.lastPathComponent) {
                walker.skipDescendants()
                walk.skipped.append(url.path)
            } else if values?.isRegularFile == true {
                walk.files.append(url)
            }
        }
        return walk
    }

    /// Whether the archive's folder is there: an archive whose folder is not is neither read nor written, nor filed into.
    public nonisolated var archiveIsThere: Bool { Self.isFolder(archive) }

    /// Whether a folder is at `url`.
    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The archive walked, with every record file in it and the kind it holds: the lists of documents first, and the
    /// search tasks before the conversations about them, as each refers to those before it.
    func recordFiles() async -> ArchiveWalk {
        var walk = Self.walk(archive, skip: SkipRules(watcher: config.watcher))
        walk.records = walk.files.compactMap { url in kind(of: url).map { ($0, url) } }
            .sorted { Self.readingOrder($0.0) < Self.readingOrder($1.0) }
        return walk
    }

    private static func readingOrder(_ kind: RecordKind) -> Int {
        switch kind {
        case .documents: 0
        case .history: 1
        case .labelRules: 2
        case .searchTasks: 3
        case .conversation: 4
        }
    }

    /// The kind of record file at `url` from where it is, or nil for a file that is none.
    private func kind(of url: URL) -> RecordKind? {
        let url = url.standardizedFileURL
        if url.lastPathComponent == config.records.documentsFileName { return .documents(directory: url.deletingLastPathComponent().path) }
        if url.path == layout.labelRules.standardizedFileURL.path { return .labelRules }
        if url.path == layout.searchTasks.standardizedFileURL.path { return .searchTasks }
        if url.deletingLastPathComponent().path == layout.conversations.standardizedFileURL.path {
            return layout.task(ofConversationFile: url.lastPathComponent).map { .conversation(task: $0) }
        }
        guard url.deletingLastPathComponent().path == layout.history.standardizedFileURL.path else { return nil }
        return layout.month(ofHistoryFile: url.lastPathComponent).map { .history(month: $0) }
    }
}
