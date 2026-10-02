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

/// Keeps the archive's record files and the database together (docs/storage.md). Changes reach the index first and
/// are marked by triggers; `flush` writes every marked file from the index. `reconcile` reads back any file that
/// changed on disk, and `rebuild` reads the whole archive into an empty index.
public actor ArchiveRecords {
    private let database: AppDatabase
    private let settings: SettingsStore
    private let config: PipelineConfig
    private let registry: SelfChangeRegistry?
    private let time: any TimeSource

    public init(database: AppDatabase, settings: SettingsStore, config: PipelineConfig, registry: SelfChangeRegistry?,
                time: any TimeSource) {
        self.database = database
        self.settings = settings
        self.config = config
        self.registry = registry
        self.time = time
    }

    private func layout(_ root: URL) -> ArchiveLayout {
        ArchiveLayout(root: root, records: config.records, watcher: config.watcher)
    }

    // MARK: Writing files from the index

    /// Rendering a file can itself mark others (a file edited by hand is read first), so flushing repeats, a bounded
    /// number of times, until nothing is marked.
    static let maxFlushPasses = 4

    /// Writes every record file a change has made stale. A file changed again while it is written stays marked and is
    /// written again.
    @discardableResult
    public func flush() async throws -> Int {
        let root = await settings.current.archiveURL
        var written = 0
        var failures: [String: any Error] = [:]
        for _ in 0..<Self.maxFlushPasses {
            let marks = try await database.reader.read { db in
                try Row.fetchAll(db, sql: "SELECT key, version FROM record_dirty").map { ($0["key"] as String, $0["version"] as Int64) }
            }.filter { failures[$0.0] == nil }
            guard !marks.isEmpty else { break }
            for (key, version) in marks {
                guard let kind = RecordKind(key: key) else {
                    Log.warning(.db, "Unknown record mark dropped", ["key": key])
                    try await unmark(key, version: version)
                    continue
                }
                do {
                    if try await render(kind, root: root) { written += 1 }
                    try await unmark(key, version: version)
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

    /// Writes one record file from the index. A file edited on disk since the app last wrote or read it is read first,
    /// so an edit made by hand is never overwritten.
    private func render(_ kind: RecordKind, root: URL) async throws -> Bool {
        switch kind {
        case let .documents(directory):
            let dir = URL(fileURLWithPath: directory, isDirectory: true)
            // Documents are filed at the top of the archive, or kept where an earlier version filed them below it.
            guard directory == root.path || directory.hasPrefix(root.path + "/") else { return false }
            let url = dir.appendingPathComponent(config.records.documentsFileName)
            try await readIfEditedByHand(kind, url: url)
            let entries = try await database.reader.read { db in
                try DocumentRecord.fetchAll(db, sql: "SELECT * FROM documents WHERE rtrim(path, replace(path, '/', '')) = ? ORDER BY path",
                                            arguments: [directory + "/"]).compactMap(DocumentEntry.init)
            }
            guard !entries.isEmpty else { return try await remove(url) }
            guard FileManager.default.fileExists(atPath: directory) else { return false }
            return try await write(try FrontMatter.compose(RecordList(entries), body: RecordText.documents(entries, in: dir)),
                                   to: url)
        case let .history(month):
            let url = try directoryMade(for: layout(root).historyFile(month: month))
            try await readIfEditedByHand(kind, url: url)
            let entries = try await database.reader.read { db in
                try EventRecord.fetchAll(db, sql: "SELECT * FROM events WHERE strftime('%Y-%m', at, 'unixepoch') = ? ORDER BY at, id",
                                         arguments: [month]).compactMap(EventEntry.init)
            }
            guard !entries.isEmpty else { return try await remove(url) }
            return try await write(try FrontMatter.compose(RecordList(entries), body: RecordText.history(entries, month: month)),
                                   to: url)
        case .labelRules:
            let url = layout(root).labelRules
            try await readIfEditedByHand(kind, url: url)
            let entries = try await database.reader.read { db in
                try LabelRule.order(Column("id")).fetchAll(db).compactMap(LabelRuleEntry.init)
            }
            guard !entries.isEmpty else { return try await remove(url) }
            return try await write(try FrontMatter.compose(RecordList(entries), body: RecordText.labelRules(entries)),
                                   to: try directoryMade(for: url))
        case .searchTasks:
            let url = layout(root).searchTasks
            try await readIfEditedByHand(kind, url: url)
            let entries = try await database.reader.read { db in try SearchTaskStore.entries(db) }
            guard !entries.isEmpty else { return try await remove(url) }
            return try await write(try FrontMatter.compose(RecordList(entries), body: RecordText.searchTasks(entries)),
                                   to: try directoryMade(for: url))
        case let .conversation(task):
            let url = layout(root).conversationFile(task: task)
            try await readIfEditedByHand(kind, url: url)
            let tasks = config.tasks
            let (entries, name, documents) = try await database.reader.read { db -> ([ConversationTurnEntry], String?, [Int64: String]) in
                let entries = try TaskConversationStore.entries(db, task: task)
                let name = try SearchTaskRecord.fetchOne(db, key: task).map { SearchTaskStore.name($0, config: tasks) }
                let named = Set(entries.flatMap { ($0.sources ?? []) + ($0.finding?.documents ?? []) })
                let documents = Dictionary(try DocumentRecord.fetchAll(db, keys: Array(named)).compactMap { d in d.id.map { ($0, d.filename) } },
                                           uniquingKeysWith: { a, _ in a })
                return (entries, name, documents)
            }
            guard let name, !entries.isEmpty else { return try await remove(url) }
            return try await write(try FrontMatter.compose(RecordList(entries), body: RecordText.conversation(entries, task: name, documents: documents)),
                                   to: try directoryMade(for: url))
        }
    }

    // MARK: Files and their checksums

    /// The checksum of each record file as last written or read, mirrored from `record_files`.
    private var knownHashes: [String: String] = [:]

    private func loadKnownHashes() async throws {
        knownHashes = try await database.reader.read { db in
            Dictionary(try Row.fetchAll(db, sql: "SELECT path, hash FROM record_files").map { ($0["path"] as String, $0["hash"] as String) },
                       uniquingKeysWith: { a, _ in a })
        }
    }

    /// `url`, with the directory it goes in made first: the system folder appears when it is first needed.
    private func directoryMade(for url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RecordsError.unwritable(directory.path, error.localizedDescription)
        }
        return url
    }

    /// Writes `text` atomically unless the file already holds exactly that, and remembers its checksum.
    private func write(_ text: String, to url: URL) async throws -> Bool {
        let hash = FrontMatter.sha256(text)
        let current = try? String(contentsOf: url, encoding: .utf8)
        if current.map(FrontMatter.sha256) != hash {
            await registry?.expect([url.path, url.deletingLastPathComponent().path])
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                throw RecordsError.unwritable(url.path, error.localizedDescription)
            }
        }
        try await remember(url, hash: hash)
        return current.map(FrontMatter.sha256) != hash
    }

    private func remove(_ url: URL) async throws -> Bool {
        let existed = FileManager.default.fileExists(atPath: url.path)
        if existed {
            await registry?.expect([url.path, url.deletingLastPathComponent().path])
            try FileManager.default.removeItem(at: url)
        }
        knownHashes[url.path] = nil
        try await database.writer.write { db in try db.execute(sql: "DELETE FROM record_files WHERE path = ?", arguments: [url.path]) }
        return existed
    }

    private func remember(_ url: URL, hash: String) async throws {
        knownHashes[url.path] = hash
        try await database.writer.write { db in try Self.remember(db, path: url.path, hash: hash) }
    }

    private static func remember(_ db: Database, path: String, hash: String) throws {
        try db.execute(sql: "INSERT INTO record_files(path, hash) VALUES(?, ?) ON CONFLICT(path) DO UPDATE SET hash = excluded.hash",
                       arguments: [path, hash])
    }

    // MARK: Reading files into the index

    /// Reads every record file that changed on disk since the app last wrote or read it (an edit by hand, a copy
    /// synchronised from another Mac, a crash between the index and the file), then writes whatever is still stale.
    @discardableResult
    public func reconcile() async throws -> Int {
        let root = await settings.current.archiveURL
        try await loadKnownHashes()
        let files = recordFiles(root: root)
        var reread = 0
        for (kind, url) in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let hash = FrontMatter.sha256(text)
            guard knownHashes[url.path] != hash else { continue }
            try await read(kind, url: url, replacing: !(try await isMarked(kind)))
            reread += 1
        }
        let present = Set(files.map(\.1.path))
        for path in knownHashes.keys where !present.contains(path) {
            // A record file that disappeared is written again from the index: deleting it is not deleting its records.
            let kind = kind(ofMissing: path, root: root)
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM record_files WHERE path = ?", arguments: [path])
                if let kind { try Self.mark(db, kind) }
            }
            knownHashes[path] = nil
        }
        if reread > 0 { Log.info(.db, "Record files read again", ["files": String(reread)]) }
        try await flush()
        return reread
    }

    /// Reads a file into the index if it changed since the app last wrote or read it.
    private func readIfEditedByHand(_ kind: RecordKind, url: URL) async throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let known = try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT hash FROM record_files WHERE path = ?", arguments: [url.path])
        }
        guard let known, known != FrontMatter.sha256(text) else { return }
        Log.info(.db, "Record file changed by hand; merging it before writing", ["path": url.path])
        // The index has changes of its own for this file, so the edit is merged in rather than replacing it.
        try await read(kind, url: url, replacing: false)
    }

    private func isMarked(_ kind: RecordKind) async throws -> Bool {
        try await database.reader.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM record_dirty WHERE key = ?)", arguments: [kind.key]) ?? false
        }
    }

    /// Reads one record file into the index. `replacing` also removes what the file no longer lists; merging only adds
    /// and updates, and leaves the file marked so it is written with both.
    private func read(_ kind: RecordKind, url: URL, replacing: Bool) async throws {
        let parsed = try parse(kind, url: url)
        let now = time.now()
        try await database.writer.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try Self.apply(parsed, db: db, replacing: replacing, at: now)
            for (path, hash) in parsed.hashes { try Self.remember(db, path: path, hash: hash) }
            if replacing { try db.execute(sql: "DELETE FROM record_dirty WHERE key = ?", arguments: [kind.key]) }
        }
        for (path, hash) in parsed.hashes { knownHashes[path] = hash }
    }

    /// Record files as parsed from disk, ready to apply in one transaction.
    struct Parsed: Sendable {
        var documents: [(directory: URL, entries: [DocumentEntry])] = []
        var history: [(month: String, entries: [EventEntry])] = []
        var labelRules: [LabelRuleEntry]?
        var searchTasks: [SearchTaskEntry]?
        var conversations: [(task: Int64, entries: [ConversationTurnEntry])] = []
        var hashes: [String: String] = [:]

        mutating func merge(_ other: Parsed) {
            documents += other.documents
            history += other.history
            labelRules = other.labelRules ?? labelRules
            searchTasks = other.searchTasks ?? searchTasks
            conversations += other.conversations
            hashes.merge(other.hashes) { _, new in new }
        }
    }

    private nonisolated func parse(_ kind: RecordKind, url: URL) throws -> Parsed {
        var parsed = Parsed()
        func text(_ url: URL) throws -> String {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                parsed.hashes[url.path] = FrontMatter.sha256(text)
                return text
            } catch {
                throw RecordsError.unreadable(url.path, error.localizedDescription)
            }
        }
        func list<Entry: Codable & Sendable>(_ type: Entry.Type, _ url: URL) throws -> [Entry] {
            try FrontMatter.read(RecordList<Entry>.self, from: try text(url), path: url.path).value.entries
        }
        switch kind {
        case .documents:
            parsed.documents = [(url.deletingLastPathComponent(), try list(DocumentEntry.self, url))]
        case let .history(month): parsed.history = [(month, try list(EventEntry.self, url))]
        case .labelRules: parsed.labelRules = try list(LabelRuleEntry.self, url)
        case .searchTasks: parsed.searchTasks = try list(SearchTaskEntry.self, url)
        case let .conversation(task): parsed.conversations = [(task, try list(ConversationTurnEntry.self, url))]
        }
        return parsed
    }

    /// Puts parsed records into the index. Documents are only ever added or updated here: an entry missing from a
    /// file does not delete a document, whose entry is written back instead. Other files replace their table when
    /// `replacing`, and otherwise add and update their rows.
    private static func apply(_ parsed: Parsed, db: Database, replacing: Bool, at now: Date) throws {
        for (directory, entries) in parsed.documents {
            for entry in entries { try upsert(entry, directory: directory, db: db, at: now) }
        }
        for (month, entries) in parsed.history {
            if replacing {
                try db.execute(sql: "DELETE FROM events WHERE strftime('%Y-%m', at, 'unixepoch') = ? AND id NOT IN (\(ids(entries.map(\.id))))",
                               arguments: [month])
            }
            for entry in entries {
                var record = entry.record
                if let doc = record.docId, try !DocumentRecord.exists(db, key: doc) { record.docId = nil }
                try record.save(db)
            }
        }
        if let entries = parsed.labelRules {
            if replacing {
                try db.execute(sql: "DELETE FROM label_rules WHERE id NOT IN (\(ids(entries.map(\.id))))")
            }
            for entry in entries {
                var record = entry.record
                try record.save(db)
            }
        }
        if let entries = parsed.searchTasks {
            if replacing {
                try db.execute(sql: "DELETE FROM search_tasks WHERE id NOT IN (\(ids(entries.map(\.id))))")
            }
            for entry in entries { try SearchTaskStore.restore(entry, db: db) }
        }
        // After the tasks, whose conversations they are.
        for (task, entries) in parsed.conversations {
            try TaskConversationStore.restore(entries, task: task, replacing: replacing, db: db)
        }
    }

    /// Adds or updates a document from its entry, keeping what the index caches about the file.
    private static func upsert(_ entry: DocumentEntry, directory: URL, db: Database, at now: Date) throws {
        var record = entry.record(directory: directory, now: now)
        let existing = try DocumentRecord.fetchOne(db, key: entry.id)
            ?? DocumentRecord.filter(Column("uid") == entry.uid).fetchOne(db)
        if let existing {
            record.id = existing.id
            record.inode = existing.inode
            record.contentJson = existing.contentJson
            record.extractedAt = existing.extractedAt
            record.embeddedAt = existing.embeddedAt
            record.fileMtime = existing.fileMtime
            record.lastTraceId = existing.lastTraceId
            record.createdAt = existing.createdAt
            try record.update(db)
        } else {
            try record.insert(db)
        }
    }

    static func ids(_ values: [Int64]) -> String {
        values.isEmpty ? "NULL" : values.map(String.init).joined(separator: ",")
    }

    static func mark(_ db: Database, _ kind: RecordKind) throws {
        try db.execute(sql: "INSERT INTO record_dirty(key, version) VALUES (?, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1",
                       arguments: [kind.key])
    }

    // MARK: Rebuilding

    /// Cheaply, without walking the archive: whether it has the system folder, or a list of documents at its top,
    /// which every archive the app has written records into has.
    public static func mayHoldRecords(archive: URL, config: PipelineConfig) -> Bool {
        let layout = ArchiveLayout(root: archive, records: config.records, watcher: config.watcher)
        return FileManager.default.fileExists(atPath: layout.system.path)
            || FileManager.default.fileExists(atPath: archive.appendingPathComponent(config.records.documentsFileName).path)
    }

    /// Whether the archive holds record files a rebuild could read.
    public func archiveHasRecords() async throws -> Bool {
        let root = await settings.current.archiveURL
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        return !recordFiles(root: root).isEmpty
    }

    /// Rebuilds the index from the archive on request. Changes not yet written to the record files are written first,
    /// so nothing the app knows is lost.
    @discardableResult
    public func rebuildIndex() async throws -> RebuildSummary {
        try await flush()
        return try await rebuild()
    }

    /// Reads the whole archive into the index, replacing what it held: documents, history, the rules for labels, the
    /// search tasks and the conversations about their documents, in one transaction. Then documents are located by the identifier on each file, files without an entry
    /// are taken in, and every document is queued to have its text read and its embedding computed again. Called on a
    /// new or set-aside index, whose tables are empty, and by `rebuildIndex`.
    @discardableResult
    public func rebuild() async throws -> RebuildSummary {
        let root = await settings.current.archiveURL
        var summary = RebuildSummary()
        var parsed = Parsed()
        for (kind, url) in recordFiles(root: root) {
            do {
                parsed.merge(try parse(kind, url: url))
            } catch {
                Log.error(.db, "Record file could not be read; skipped", ["path": url.path, "error": error.localizedDescription])
            }
        }
        summary.documents = parsed.documents.reduce(0) { $0 + $1.entries.count }
        summary.events = parsed.history.reduce(0) { $0 + $1.entries.count }
        summary.labelRules = parsed.labelRules?.count ?? 0
        summary.searchTasks = parsed.searchTasks?.count ?? 0
        let ready = parsed
        let now = time.now()
        try await database.writer.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for table in Self.rebuiltTables { try db.execute(sql: "DELETE FROM \(table)") }
            try Self.apply(ready, db: db, replacing: false, at: now)
            try db.execute(sql: "DELETE FROM record_files")
            for (path, hash) in ready.hashes { try Self.remember(db, path: path, hash: hash) }
            try db.execute(sql: "DELETE FROM record_dirty")
        }
        try await loadKnownHashes()
        try await locateDocuments(root: root, summary: &summary)
        try await queueReindex(summary: &summary)
        try await HistoryStore(database: database, time: time).record(.rebuilt, summary: summary.summary, payload: summary)
        try await flush()
        Log.info(.db, "Index rebuilt from the archive", ["documents": String(summary.documents), "missing": String(summary.missing),
                                                         "adopted": String(summary.adopted)])
        return summary
    }

    /// Tables a rebuild replaces with what the files say, and working state that cannot outlive the old index.
    /// Documents are updated in place instead, never deleted: their numbers come back unchanged, so their cached text,
    /// embeddings and traces stay attached.
    static let rebuiltTables = ["events", "label_rules", "search_task_documents", "search_task_exports", "search_task_turns", "search_tasks"]

    /// Finds documents whose file is not where their entry says by the identifier on each file, and takes in files
    /// that no entry describes.
    private func locateDocuments(root: URL, summary: inout RebuildSummary) async throws {
        let documents = try await DocumentStore(database: database, time: time).list(DocumentFilter(), limit: Int.max)
        let byUID = Dictionary(documents.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        let skip = SkipRules(watcher: config.watcher)
        var found: [String: String] = [:]
        var untracked: [String] = []
        for url in Self.files(under: root) where skip.ignoreReason(url) == nil && !skip.isInsideIgnoredDirectory(url, root: root) {
            if let uid = Xattr.get(Xattr.documentID, from: url), byUID[uid] != nil {
                found[uid] = url.path
            } else {
                untracked.append(url.path)
            }
        }
        let store = DocumentStore(database: database, time: time)
        for var document in documents where document.status != .missing && !FileManager.default.fileExists(atPath: document.path) {
            if let path = found[document.uid] {
                document.path = path
                summary.relocated += 1
            } else {
                document.status = .missing
                summary.missing += 1
            }
            _ = try await store.save(document)
        }
        // A file put into the archive by hand is read and labelled where it is; the system folder holds no documents.
        let jobs = JobStore(database: database, time: time)
        let layout = layout(root)
        let incoming = await settings.current.incomingURL.path + "/"
        for path in untracked where !layout.isSystem(URL(fileURLWithPath: path)) && !path.hasPrefix(incoming) {
            if try await jobs.enqueue(path: path, kind: .adopt) != nil { summary.adopted += 1 }
        }
    }

    /// Every regular file under `root`, hidden files and package contents aside.
    private static func files(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            // Listings resolve /var to /private/var; standardizing gives the paths the index stores.
            files.append(url.standardizedFileURL)
        }
        return files
    }

    private func queueReindex(summary: inout RebuildSummary) async throws {
        let jobs = JobStore(database: database, time: time)
        for document in try await DocumentStore(database: database, time: time).list(DocumentFilter(), limit: Int.max)
        where document.status != .missing && FileManager.default.fileExists(atPath: document.path) {
            if try await jobs.enqueue(path: document.path, kind: .reindex, docID: document.id) != nil { summary.queued += 1 }
        }
    }
}

extension ArchiveRecords {
    // MARK: Finding record files

    /// Every record file in the archive with the kind it holds.
    private func recordFiles(root: URL) -> [(RecordKind, URL)] {
        let layout = layout(root)
        let files: [(RecordKind, URL)] = Self.files(under: root).filter { $0.lastPathComponent == config.records.documentsFileName }.map {
            (.documents(directory: $0.deletingLastPathComponent().path), $0)
        }
        let rules = FileManager.default.fileExists(atPath: layout.labelRules.path) ? [(RecordKind.labelRules, layout.labelRules)] : []
        let tasks = FileManager.default.fileExists(atPath: layout.searchTasks.path) ? [(RecordKind.searchTasks, layout.searchTasks)] : []
        return files + historyFiles(layout) + rules + tasks + conversationFiles(layout)
    }

    /// The kind of a record file the index knew about, from where it was.
    private func kind(ofMissing path: String, root: URL) -> RecordKind? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let layout = layout(root)
        if url.lastPathComponent == config.records.documentsFileName { return .documents(directory: url.deletingLastPathComponent().path) }
        if url.path == layout.labelRules.standardizedFileURL.path { return .labelRules }
        if url.path == layout.searchTasks.standardizedFileURL.path { return .searchTasks }
        if url.deletingLastPathComponent().path == layout.conversations.standardizedFileURL.path {
            return layout.task(ofConversationFile: url.lastPathComponent).map { .conversation(task: $0) }
        }
        guard url.deletingLastPathComponent().path == layout.history.standardizedFileURL.path else { return nil }
        return layout.month(ofHistoryFile: url.lastPathComponent).map { .history(month: $0) }
    }

    private nonisolated func conversationFiles(_ layout: ArchiveLayout) -> [(RecordKind, URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.conversations.path)) ?? []
        return names.sorted().compactMap { name in
            layout.task(ofConversationFile: name).map { (.conversation(task: $0), layout.conversations.appendingPathComponent(name).standardizedFileURL) }
        }
    }

    private nonisolated func historyFiles(_ layout: ArchiveLayout) -> [(RecordKind, URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.history.path)) ?? []
        return names.compactMap { name in
            layout.month(ofHistoryFile: name).map { (.history(month: $0), layout.history.appendingPathComponent(name).standardizedFileURL) }
        }
    }
}

public enum RecordsError: Error, LocalizedError {
    case unreadable(String, String)
    case unwritable(String, String)
    case notWritten(String, String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, why): "Could not read the record file \(path): \(why)"
        case let .unwritable(path, why): "Could not write the record file \(path): \(why)"
        case let .notWritten(key, why): "The record file for \(key) was not written and will be tried again: \(why)"
        }
    }
}
