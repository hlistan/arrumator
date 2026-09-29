import Foundation
import GRDB

/// What a rebuild found in the archive.
public struct RebuildSummary: Sendable, Codable, Hashable {
    public var folders = 0
    public var documents = 0
    public var senders = 0
    public var rules = 0
    public var corrections = 0
    public var memories = 0
    /// Whether the archive's logic file was read.
    public var logic = false
    public var events = 0
    /// Documents found somewhere other than where their entry said, by the identifier on the file.
    public var relocated = 0
    /// Documents whose file is nowhere in the archive.
    public var missing = 0
    /// Files in the archive without an entry, taken in as new.
    public var adopted = 0
    /// Documents queued to have their text read and their embedding computed again.
    public var queued = 0

    public var summary: String {
        "Rebuilt the index from the archive: \(Format.count(documents, "document")), \(Format.count(senders, "sender")), "
            + "\(Format.count(rules, "rule")), \(Format.count(corrections, "correction")), \(Format.count(events, "history event")); "
            + "\(relocated) found elsewhere, \(missing) missing, \(adopted) taken in"
    }
}

/// Keeps the archive's record files and the database together (docs/storage.md). Changes reach the index first and
/// are marked by triggers; `flush` writes every marked file from the index. `reconcile` reads back any file that
/// changed on disk, and `rebuild` reads the whole archive into an empty index.
public actor ArchiveRecords {
    private let database: AppDatabase
    private let settings: SettingsStore
    private let taxonomy: TaxonomyStore
    private let config: PipelineConfig
    private let registry: SelfChangeRegistry?

    public init(database: AppDatabase, settings: SettingsStore, taxonomy: TaxonomyStore, config: PipelineConfig,
                registry: SelfChangeRegistry?) {
        self.database = database
        self.settings = settings
        self.taxonomy = taxonomy
        self.config = config
        self.registry = registry
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
            guard directory.hasPrefix(root.path + "/") else { return false }
            let url = dir.appendingPathComponent(config.taxonomy.documentsFileName)
            try await readIfEditedByHand(kind, url: url, root: root)
            let entries = try await database.reader.read { db in
                try DocumentRecord.fetchAll(db, sql: "SELECT * FROM documents WHERE rtrim(path, replace(path, '/', '')) = ? ORDER BY path",
                                            arguments: [directory + "/"]).compactMap(DocumentEntry.init)
            }
            guard !entries.isEmpty else { return try await remove(url) }
            guard FileManager.default.fileExists(atPath: directory) else { return false }
            return try await write(try FrontMatter.compose(RecordList(entries), body: RecordText.documents(entries, in: dir)),
                                   to: url)
        case .senders: return try await renderLearned(.senders, root: root)
        case .rules: return try await renderLearned(.rules, root: root)
        case .corrections: return try await renderLearned(.corrections, root: root)
        case .memories: return try await renderLearned(.memories, root: root)
        case .logic:
            let url = try await logicFile(root: root)
            try await readIfEditedByHand(kind, url: url, root: root)
            // Without logic in the index there is nothing to write, and the file is never removed: it is the user's.
            guard let logic = try await database.reader.read({ db in try LogicRecord.fetchOne(db) }) else { return false }
            return try await write(try FrontMatter.compose(LogicEntry(logic), body: logic.body + "\n"), to: url)
        case let .history(month):
            let url = try await historyFile(month: month, root: root)
            try await readIfEditedByHand(kind, url: url, root: root)
            let entries = try await database.reader.read { db in
                try EventRecord.fetchAll(db, sql: "SELECT * FROM events WHERE strftime('%Y-%m', at, 'unixepoch') = ? ORDER BY at, id",
                                         arguments: [month]).compactMap(EventEntry.init)
            }
            guard !entries.isEmpty else { return try await remove(url) }
            return try await write(try FrontMatter.compose(RecordList(entries), body: RecordText.history(entries, month: month)),
                                   to: url)
        }
    }

    private func renderLearned(_ table: LearnedTable, root: URL) async throws -> Bool {
        let url = try await learnedFile(table, root: root)
        try await readIfEditedByHand(table.kind, url: url, root: root)
        return try await write(try await learnedText(table), to: url)
    }

    private func learnedText(_ table: LearnedTable) async throws -> String {
        try await database.reader.read { db in
            switch table {
            case .senders:
                let entries = try CorrespondentRecord.order(Column("canonical_name")).fetchAll(db).map(\.correspondent)
                return try FrontMatter.compose(RecordList(entries), body: RecordText.senders(entries))
            case .rules:
                let entries = try RuleRecord.order(Column("id")).fetchAll(db).compactMap(\.rule)
                return try FrontMatter.compose(RecordList(entries), body: RecordText.rules(entries))
            case .corrections:
                let codes = try Self.folderCodes(db)
                let entries = try CorrectionRecord.order(Column("at"), Column("id")).fetchAll(db)
                    .compactMap { CorrectionEntry($0, folderCodes: codes) }
                return try FrontMatter.compose(RecordList(entries), body: RecordText.corrections(entries))
            case .memories:
                let entries = try MemoryRecord.order(Column("id")).fetchAll(db).compactMap(MemoryEntry.init)
                return try FrontMatter.compose(RecordList(entries), body: RecordText.memories(entries))
            }
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
        let files = try await recordFiles(root: root)
        var reread = 0
        for (kind, url) in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let hash = FrontMatter.sha256(text)
            guard knownHashes[url.path] != hash else { continue }
            try await read(kind, url: url, root: root, replacing: !(try await isMarked(kind)))
            reread += 1
        }
        let present = Set(files.map(\.1.path))
        for path in knownHashes.keys where !present.contains(path) {
            // A record file that disappeared is written again from the index: deleting it is not deleting its records.
            let kind = try await kind(ofMissing: path, root: root)
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
    private func readIfEditedByHand(_ kind: RecordKind, url: URL, root: URL) async throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let known = try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT hash FROM record_files WHERE path = ?", arguments: [url.path])
        }
        guard let known, known != FrontMatter.sha256(text) else { return }
        Log.info(.db, "Record file changed by hand; merging it before writing", ["path": url.path])
        // The index has changes of its own for this file, so the edit is merged in rather than replacing it.
        try await read(kind, url: url, root: root, replacing: false)
    }

    private func isMarked(_ kind: RecordKind) async throws -> Bool {
        try await database.reader.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM record_dirty WHERE key = ?)", arguments: [kind.key]) ?? false
        }
    }

    /// Reads one record file into the index. `replacing` also removes what the file no longer lists; merging only adds
    /// and updates, and leaves the file marked so it is written with both.
    private func read(_ kind: RecordKind, url: URL, root: URL, replacing: Bool) async throws {
        let parsed = try parse(kind, url: url)
        let snapshot = try await taxonomy.snapshot(root: root)
        try await database.writer.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try Self.apply(parsed, snapshot: snapshot, db: db, replacing: replacing)
            for (path, hash) in parsed.hashes { try Self.remember(db, path: path, hash: hash) }
            if replacing { try db.execute(sql: "DELETE FROM record_dirty WHERE key = ?", arguments: [kind.key]) }
        }
        for (path, hash) in parsed.hashes { knownHashes[path] = hash }
    }

    /// Record files as parsed from disk, ready to apply in one transaction.
    struct Parsed: Sendable {
        var documents: [(directory: URL, entries: [DocumentEntry])] = []
        var senders: [Correspondent]?
        var rules: [FilingRule]?
        var corrections: [CorrectionEntry]?
        var memories: [MemoryEntry]?
        var logic: LogicRecord?
        var history: [(month: String, entries: [EventEntry])] = []
        var hashes: [String: String] = [:]

        mutating func merge(_ other: Parsed) {
            documents += other.documents
            senders = other.senders ?? senders
            rules = other.rules ?? rules
            corrections = other.corrections ?? corrections
            memories = other.memories ?? memories
            logic = other.logic ?? logic
            history += other.history
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
        case .senders: parsed.senders = try list(Correspondent.self, url)
        case .rules: parsed.rules = try list(FilingRule.self, url)
        case .corrections: parsed.corrections = try list(CorrectionEntry.self, url)
        case .memories: parsed.memories = try list(MemoryEntry.self, url)
        case .logic:
            let text = try text(url)
            do {
                let (entry, body) = try FrontMatter.read(LogicEntry.self, from: text, path: url.path)
                parsed.logic = entry.record(body: LogicRecord.normalized(body))
            } catch FrontMatterError.missingFrontMatter {
                // Just the prompt, as someone wrote it by hand: logic of their own.
                parsed.logic = LogicRecord(body: LogicRecord.normalized(text), builtinHash: nil)
            }
        case let .history(month): parsed.history = [(month, try list(EventEntry.self, url))]
        }
        return parsed
    }

    /// Puts parsed records into the index. Documents are only ever added or updated here: an entry missing from a
    /// file does not delete a document, whose entry is written back instead. Other files replace their table.
    private static func apply(_ parsed: Parsed, snapshot: TaxonomySnapshot, db: Database, replacing: Bool) throws {
        let folderIDs = Dictionary(snapshot.folders.map { ($0.code, $0.id) }, uniquingKeysWith: { a, _ in a })
        if var logic = parsed.logic { try logic.save(db) }
        if let senders = parsed.senders {
            if replacing { try db.execute(sql: "DELETE FROM correspondents WHERE id NOT IN (\(ids(senders.map(\.id))))") }
            for sender in senders {
                var record = CorrespondentRecord(sender)
                record.id = sender.id
                try record.save(db)
            }
        }
        if let rules = parsed.rules {
            if replacing { try db.execute(sql: "DELETE FROM rules WHERE id NOT IN (\(ids(rules.map(\.id))))") }
            for var rule in rules {
                if let id = folderIDs[rule.action.folderCode] { rule.action.folderID = id }
                var record = RuleRecord(rule)
                record.id = rule.id
                try record.save(db)
            }
        }
        for (directory, entries) in parsed.documents {
            let folderID = snapshot.folder(holding: directory)?.id
            for entry in entries { try upsert(entry, directory: directory, folderID: folderID, db: db) }
        }
        if let corrections = parsed.corrections {
            if replacing { try db.execute(sql: "DELETE FROM corrections WHERE id NOT IN (\(ids(corrections.map(\.id))))") }
            for entry in corrections where try DocumentRecord.exists(db, key: entry.document) {
                var record = entry.record(folderIDs: folderIDs)
                try record.save(db)
            }
        }
        if let memories = parsed.memories {
            if replacing { try db.execute(sql: "DELETE FROM memories WHERE id NOT IN (\(ids(memories.map(\.id))))") }
            for entry in memories {
                guard let folderID = folderIDs[entry.folder], try DocumentRecord.exists(db, key: entry.document) else { continue }
                var record = entry.record(folderID: folderID)
                if let existing = try MemoryRecord.fetchOne(db, key: entry.id), existing.docId == entry.document {
                    record.embedding = existing.embedding
                    record.model = existing.model
                }
                try record.save(db)
            }
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
    }

    /// Adds or updates a document from its entry, keeping what the index caches about the file.
    private static func upsert(_ entry: DocumentEntry, directory: URL, folderID: Int64?, db: Database) throws {
        var record = entry.record(directory: directory, folderID: folderID)
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

    private static func ids(_ values: [Int64]) -> String {
        values.isEmpty ? "NULL" : values.map(String.init).joined(separator: ",")
    }

    static func folderCodes(_ db: Database) throws -> [Int64: String] {
        Dictionary(try Row.fetchAll(db, sql: "SELECT id, code FROM folders").map { ($0["id"] as Int64, $0["code"] as String) },
                   uniquingKeysWith: { a, _ in a })
    }

    static func mark(_ db: Database, _ kind: RecordKind) throws {
        try db.execute(sql: "INSERT INTO record_dirty(key, version) VALUES (?, 1) ON CONFLICT(key) DO UPDATE SET version = version + 1",
                       arguments: [kind.key])
    }

    // MARK: Finding record files

    /// Every record file in the archive with the kind it holds.
    private func recordFiles(root: URL) async throws -> [(RecordKind, URL)] {
        let documentsName = config.taxonomy.documentsFileName
        var files: [(RecordKind, URL)] = Self.files(under: root).filter { $0.lastPathComponent == documentsName }.map {
            (.documents(directory: $0.deletingLastPathComponent().path), $0)
        }
        let snapshot = try await taxonomy.snapshot(root: root)
        if let learned = snapshot.folder(role: .learned).map({ snapshot.url(for: $0) }) {
            for table in LearnedTable.allCases {
                let url = learned.appendingPathComponent(learnedName(table))
                if FileManager.default.fileExists(atPath: url.path) { files.append((table.kind, url)) }
            }
        }
        if let logic = snapshot.folder(role: .logic).map({ snapshot.url(for: $0).appendingPathComponent(config.records.logicFileName) }),
           FileManager.default.fileExists(atPath: logic.path) {
            files.append((.logic, logic))
        }
        if let history = snapshot.folder(role: .history).map({ snapshot.url(for: $0) }) {
            files += try historyFiles(in: history)
        }
        return files
    }

    /// The kind of a record file the index knew about, from where it was.
    private func kind(ofMissing path: String, root: URL) async throws -> RecordKind? {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == config.taxonomy.documentsFileName {
            return .documents(directory: url.deletingLastPathComponent().path)
        }
        let snapshot = try await taxonomy.snapshot(root: root)
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        func isIn(_ role: FolderRole) -> Bool {
            snapshot.folder(role: role).map { snapshot.url(for: $0).standardizedFileURL.path == parent } ?? false
        }
        if isIn(.learned) { return LearnedTable.allCases.first { learnedName($0) == url.lastPathComponent }?.kind }
        if isIn(.logic) { return url.lastPathComponent == config.records.logicFileName ? .logic : nil }
        if isIn(.history) { return month(ofHistoryFile: url.lastPathComponent).map { .history(month: $0) } }
        return nil
    }

    private func learnedName(_ table: LearnedTable) -> String {
        switch table {
        case .senders: config.records.sendersFileName
        case .rules: config.records.rulesFileName
        case .corrections: config.records.correctionsFileName
        case .memories: config.records.memoriesFileName
        }
    }

    private nonisolated func isManagedName(_ name: String) -> Bool {
        name.hasPrefix(config.watcher.managedFilePrefix) && name.hasSuffix("." + config.watcher.managedFileExtension)
            && name != config.taxonomy.aboutFileName && name != config.taxonomy.documentsFileName
    }

    private nonisolated func historyFiles(in dir: URL) throws -> [(RecordKind, URL)] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map(\.standardizedFileURL)
            .compactMap { url in month(ofHistoryFile: url.lastPathComponent).map { (.history(month: $0), url) } }
    }

    private nonisolated func month(ofHistoryFile name: String) -> String? {
        guard isManagedName(name) else { return nil }
        let month = String(name.dropFirst(config.watcher.managedFilePrefix.count).dropLast(config.watcher.managedFileExtension.count + 1))
        return month.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) == nil ? nil : month
    }

    private func systemDirectory(_ role: FolderRole, root: URL) async throws -> URL {
        let folder = try await taxonomy.ensureSystemFolder(role, root: root)
        return try await taxonomy.snapshot(root: root).url(for: folder)
    }

    private func learnedFile(_ table: LearnedTable, root: URL) async throws -> URL {
        try await systemDirectory(.learned, root: root).appendingPathComponent(learnedName(table))
    }

    private func logicFile(root: URL) async throws -> URL {
        try await systemDirectory(.logic, root: root).appendingPathComponent(config.records.logicFileName)
    }

    /// The file the archive keeps its logic in, or nil before the app has written it.
    public func logicFileURL() async throws -> URL? {
        let snapshot = try await taxonomy.snapshot(root: await settings.current.archiveURL)
        return snapshot.folder(role: .logic).map { snapshot.url(for: $0).appendingPathComponent(config.records.logicFileName) }
    }

    private func historyFile(month: String, root: URL) async throws -> URL {
        try await systemDirectory(.history, root: root)
            .appendingPathComponent("\(config.watcher.managedFilePrefix)\(month).\(config.watcher.managedFileExtension)")
    }

    // MARK: Rebuilding

    /// Cheaply, without walking the archive: whether it has the system folders that hold learned state, logic and
    /// history, which every archive the app has written records into has.
    public static func mayHoldRecords(archive: URL, config: PipelineConfig) -> Bool {
        func definition(_ directory: URL) -> FolderDefinition? {
            let url = directory.appendingPathComponent(config.taxonomy.aboutFileName)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return try? AboutFile.parse(text, path: url.path).definition
        }
        func directories(_ url: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        let roles: Set<FolderRole> = [.learned, .logic, .history]
        return directories(archive).contains { area in
            definition(area)?.origin == .system && directories(area).contains { definition($0)?.role.map(roles.contains) ?? false }
        }
    }

    /// Whether the archive holds record files a rebuild could read.
    public func archiveHasRecords() async throws -> Bool {
        let root = await settings.current.archiveURL
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        // The folders holding what was learned, the logic and the history are found through the taxonomy, which a new
        // index has not read yet. Without them an archive holding only its logic would look empty, and the logic
        // would be written over.
        _ = try await taxonomy.sync(root: root)
        return try await !recordFiles(root: root).isEmpty
    }

    /// Rebuilds the index from the archive on request. Changes not yet written to the record files are written first,
    /// so nothing the app knows is lost.
    @discardableResult
    public func rebuildIndex() async throws -> RebuildSummary {
        try await flush()
        return try await rebuild()
    }

    /// Reads the whole archive into the index, replacing what it held: folders, documents, what was learned, logic and
    /// history, in one transaction. Then documents are located by the identifier on each file, files without an entry
    /// are taken in, and every document is queued to have its text read and its embedding computed again. Called on a
    /// new or set-aside index, whose tables are empty, and by `rebuildIndex`.
    @discardableResult
    public func rebuild() async throws -> RebuildSummary {
        let root = await settings.current.archiveURL
        var summary = RebuildSummary()
        summary.folders = try await taxonomy.sync(root: root).count
        let snapshot = try await taxonomy.snapshot(root: root)
        summary.folders = snapshot.folders.count
        var parsed = Parsed()
        for (kind, url) in try await recordFiles(root: root) {
            do {
                parsed.merge(try parse(kind, url: url))
            } catch {
                Log.error(.db, "Record file could not be read; skipped", ["path": url.path, "error": error.localizedDescription])
            }
        }
        summary.documents = parsed.documents.reduce(0) { $0 + $1.entries.count }
        summary.senders = parsed.senders?.count ?? 0
        summary.rules = parsed.rules?.count ?? 0
        summary.corrections = parsed.corrections?.count ?? 0
        summary.memories = parsed.memories?.count ?? 0
        summary.logic = parsed.logic != nil
        summary.events = parsed.history.reduce(0) { $0 + $1.entries.count }
        let ready = parsed
        try await database.writer.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for table in Self.rebuiltTables { try db.execute(sql: "DELETE FROM \(table)") }
            try Self.apply(ready, snapshot: snapshot, db: db, replacing: false)
            try db.execute(sql: "DELETE FROM record_files")
            for (path, hash) in ready.hashes { try Self.remember(db, path: path, hash: hash) }
            try db.execute(sql: "DELETE FROM record_dirty")
        }
        try await loadKnownHashes()
        try await locateDocuments(root: root, summary: &summary)
        try await queueReindex(summary: &summary)
        try await HistoryStore(database: database).record(.rebuilt, summary: summary.summary, payload: summary)
        try await flush()
        Log.info(.db, "Index rebuilt from the archive", ["documents": String(summary.documents), "missing": String(summary.missing),
                                                         "adopted": String(summary.adopted)])
        return summary
    }

    /// Tables a rebuild replaces with what the files say, and working state that cannot outlive the old index.
    /// Documents are updated in place instead, never deleted: their numbers come back unchanged, so their cached text,
    /// embeddings and traces stay attached.
    static let rebuiltTables = ["memories", "corrections", "events", "rules", "correspondents", "logic", "rethink_items",
                                "rethink_runs", "proposals"]

    /// Finds documents whose file is not where their entry says by the identifier on each file, and takes in files
    /// that no entry describes.
    private func locateDocuments(root: URL, summary: inout RebuildSummary) async throws {
        let documents = try await DocumentStore(database: database).list(DocumentFilter(), limit: Int.max)
        let byUID = Dictionary(documents.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        let skip = SkipRules(watcher: config.watcher, taxonomy: config.taxonomy)
        var found: [String: String] = [:]
        var untracked: [String] = []
        for url in Self.files(under: root) where skip.ignoreReason(url) == nil && !skip.isInsideIgnoredDirectory(url, root: root) {
            if let uid = Xattr.get(Xattr.documentID, from: url), byUID[uid] != nil {
                found[uid] = url.path
            } else {
                untracked.append(url.path)
            }
        }
        let store = DocumentStore(database: database)
        for var document in documents where document.status != .missing && !FileManager.default.fileExists(atPath: document.path) {
            if let path = found[document.uid] {
                document.path = path
                document.folderId = try await taxonomy.snapshot(root: root)
                    .folder(holding: URL(fileURLWithPath: path).deletingLastPathComponent())?.id
                summary.relocated += 1
            } else {
                document.status = .missing
                summary.missing += 1
            }
            _ = try await store.save(document)
        }
        // A file put by hand into one of the user's folders, at any depth or in its year folder, is filed there.
        let jobs = JobStore(database: database)
        let tree = try await taxonomy.snapshot(root: root)
        for path in untracked {
            guard let folder = tree.folder(holding: URL(fileURLWithPath: path).deletingLastPathComponent()), folder.holdsUserDocuments
            else { continue }
            var payload = JobPayload()
            payload.userFolderID = folder.id
            if try await jobs.enqueue(path: path, kind: .adopt, payload: payload) != nil { summary.adopted += 1 }
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
        let jobs = JobStore(database: database)
        for document in try await DocumentStore(database: database).list(DocumentFilter(), limit: Int.max)
        where document.status != .missing && FileManager.default.fileExists(atPath: document.path) {
            if try await jobs.enqueue(path: document.path, kind: .reindex, docID: document.id) != nil { summary.queued += 1 }
        }
    }
}

/// The learned-state tables, each kept in one file in the Learned folder.
enum LearnedTable: CaseIterable {
    case senders, rules, corrections, memories

    var kind: RecordKind {
        switch self {
        case .senders: .senders
        case .rules: .rules
        case .corrections: .corrections
        case .memories: .memories
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
