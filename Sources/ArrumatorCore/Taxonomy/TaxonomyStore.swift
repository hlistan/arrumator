import CryptoKit
import Foundation
import GRDB

public struct TaxonomyChange: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable { case created, adopted, renamed, moved, edited, removed, inferred, invalid }
    public var kind: Kind
    public var code: String
    public var path: String
    public var detail: String
}

public enum TaxonomyError: Error, LocalizedError {
    case unknownFolder(Int64)
    case unknownParent(String)
    case tooDeep(name: String, limit: Int)
    case codeInUse(String)
    case invalidName(String)
    case nameTaken(String)
    case missingSystemFolder(FolderRole)

    public var errorDescription: String? {
        switch self {
        case let .unknownFolder(id): "Folder \(id) does not exist"
        case let .unknownParent(code): "Folder \(code), where the new folder was to go, does not exist"
        case let .tooDeep(name, limit): "“\(name)” would be more than \(limit) folders deep"
        case let .codeInUse(c): "Code \(c) is already used"
        case let .invalidName(n): "Folder name \"\(n)\" is not allowed"
        case let .nameTaken(path): "\(path) is already there and is not a folder documents can be filed into"
        case let .missingSystemFolder(role): "No system folder is configured for \(role.rawValue)"
        }
    }
}

/// Owns the folder tree, whatever its depth. Nothing is pre-created: folders appear on demand (from model decisions,
/// the user, or lazily for system roles), and disk changes made by the user are mirrored into the database.
public actor TaxonomyStore {
    public let database: AppDatabase
    private let config: TaxonomyConfig
    /// Registers the store's own writes so the archive watcher does not mistake them for user edits.
    private let registry: SelfChangeRegistry?
    private let fileManager = FileManager.default
    /// Subtrees of the archive that are not part of its folder tree, such as Incoming when it lives inside.
    private var excluded: [String] = []
    static let versionKey = "taxonomy_version"

    public init(database: AppDatabase, config: TaxonomyConfig, registry: SelfChangeRegistry?) {
        self.database = database
        self.config = config
        self.registry = registry
    }

    /// Leaves these directories, and everything in them, out of the folder tree.
    public func exclude(_ directories: [URL]) {
        excluded = directories.map { $0.standardizedFileURL.path + "/" }
    }

    // MARK: On-demand creation

    /// Returns the system folder for `role`, creating it (and the system area) the first time it is needed.
    public func ensureSystemFolder(_ role: FolderRole, root: URL) async throws -> TaxonomyFolder {
        if let existing = try await snapshot(root: root).folder(role: role) { return existing }
        guard let spec = config.systemFolder(role) else { throw TaxonomyError.missingSystemFolder(role) }
        let areaDir = try await systemAreaDirectory(root: root)
        let dir = areaDir.appendingPathComponent(spec.name, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let def = FolderDefinition(code: spec.code, name: spec.name, role: role, description: spec.description,
                                       yearSubfolders: false, yearRule: nil, autoFile: false, origin: .system)
            try await write(AboutFile(definition: def, body: Self.body(title: spec.name, description: spec.description)),
                            to: dir.appendingPathComponent(config.aboutFileName), hash: .recompute)
        }
        _ = try await sync(root: root)
        guard let folder = try await snapshot(root: root).folder(role: role) else { throw TaxonomyError.missingSystemFolder(role) }
        return folder
    }

    /// The system area is the top-level folder whose `_about.md` says it is the system's, whatever it is called.
    private func systemAreaDirectory(root: URL) async throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = try await snapshot(root: root)
        if let area = snapshot.children(of: nil).first(where: { $0.origin == .system && $0.role == nil }) {
            return snapshot.url(for: area)
        }
        for dir in try subdirectories(of: root) where (try? readAbout(dir.appendingPathComponent(config.aboutFileName)))?.definition.origin == .system {
            return dir
        }
        let spec = config.systemArea
        let dir = root.appendingPathComponent(spec.name, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let def = FolderDefinition(code: spec.code, name: spec.name, description: spec.description, yearSubfolders: false,
                                   yearRule: nil, autoFile: false, origin: .system)
        try await write(AboutFile(definition: def, body: Self.body(title: spec.name, description: spec.description)),
                        to: dir.appendingPathComponent(config.aboutFileName), hash: .recompute)
        return dir
    }

    /// Creates the folders `spec` describes, level by level under its parent, and returns the last. A level whose
    /// name the parent already has is that folder, so only what is missing is created.
    @discardableResult
    public func materialize(_ spec: FolderSpec, root: URL, origin: FolderOrigin) async throws -> TaxonomyFolder {
        guard !spec.levels.isEmpty else { throw TaxonomyError.invalidName("") }
        let snapshot = try await snapshot(root: root)
        var depth = 0
        if let code = spec.parentCode {
            guard let parent = snapshot.folder(code: code), parent.holdsUserDocuments else { throw TaxonomyError.unknownParent(code) }
            depth = snapshot.depth(of: parent)
        }
        guard depth + spec.levels.count <= config.maxDepth else { throw TaxonomyError.tooDeep(name: spec.name, limit: config.maxDepth) }
        var parentCode = spec.parentCode
        var folder: TaxonomyFolder?
        for (index, level) in spec.levels.enumerated() {
            let last = index == spec.levels.count - 1
            let created = try await createFolder(root: root, parentCode: parentCode, name: level.name, description: level.description,
                                                 yearSubfolders: last && spec.yearSubfolders, yearRule: last ? spec.yearRule : nil,
                                                 origin: origin, kind: level.kind, logic: spec.logic)
            parentCode = created.code
            folder = created
        }
        guard let folder else { throw TaxonomyError.invalidName(spec.name) }
        return folder
    }

    /// Creates a folder named `name` inside `parentCode` (at the top of the archive for nil), with the next free code
    /// or with `code` when it is given and free. A folder of that name already there is reused: one home per name.
    @discardableResult
    public func createFolder(root: URL, parentCode: String?, name rawName: String, description: String, yearSubfolders: Bool,
                             yearRule: YearRule?, origin: FolderOrigin, kind: LevelKind? = nil, logic: String? = nil,
                             code requested: String? = nil) async throws -> TaxonomyFolder {
        let name = Self.displayName(rawName)
        try Self.validate(name)
        let snapshot = try await snapshot(root: root)
        var parent: TaxonomyFolder?
        if let parentCode {
            guard let found = snapshot.folder(code: parentCode), found.holdsUserDocuments else { throw TaxonomyError.unknownParent(parentCode) }
            parent = found
        }
        if let existing = snapshot.children(of: parentCode).first(where: { $0.holdsUserDocuments && Self.sameName($0.name, name) }) {
            Log.info(.taxonomy, "Folder already exists; reusing it", ["code": existing.code, "path": existing.relativePath])
            return existing
        }
        let dir = (parent.map(snapshot.url(for:)) ?? root).appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) {
            // A directory the index has yet to read may be a folder the user just made; anything else, such as the
            // system area or an Incoming folder kept in the archive, is never taken over.
            _ = try await sync(root: root)
            if let made = try await self.snapshot(root: root).children(of: parentCode)
                .first(where: { $0.holdsUserDocuments && Self.sameName($0.name, name) }) {
                return made
            }
            throw TaxonomyError.nameTaken(dir.path)
        }
        let depth = (parent.map(snapshot.depth(of:)) ?? 0) + 1
        guard depth <= config.maxDepth else { throw TaxonomyError.tooDeep(name: name, limit: config.maxDepth) }
        let used = try await allCodes()
        let code: String
        if let requested {
            guard !used.contains(requested) else { throw TaxonomyError.codeInUse(requested) }
            code = requested
        } else {
            code = FolderCode.next(after: used)
        }
        let def = FolderDefinition(code: code, name: name, description: description, yearSubfolders: yearSubfolders,
                                   yearRule: yearSubfolders ? (yearRule ?? .documentDate) : nil, autoFile: true, origin: origin,
                                   kind: kind, logic: logic)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try await write(AboutFile(definition: def, body: Self.body(title: name, description: description)),
                        to: dir.appendingPathComponent(config.aboutFileName), hash: origin == .user ? .preserve : .recompute)
        _ = try await sync(root: root)
        guard let folder = try await self.snapshot(root: root).folder(code: code) else { throw TaxonomyError.codeInUse(code) }
        Log.info(.taxonomy, "Created folder", ["code": code, "path": folder.relativePath, "origin": origin.rawValue])
        return folder
    }

    /// Every code a folder has had, removed folders' included, so none is used twice.
    public func allCodes() async throws -> Set<String> {
        try await database.reader.read { db in Set(try String.fetchAll(db, sql: "SELECT code FROM folders")) }
    }

    public static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).compare(b.trimmingCharacters(in: .whitespaces),
                                                       options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Names written entirely in lower case get their first letter capitalised; other names are kept as written.
    public static func displayName(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == name.lowercased(), let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    static func validate(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix("."),
              !YearFolder.matches(trimmed) else {
            throw TaxonomyError.invalidName(name)
        }
    }

    /// The Markdown a new `_about.md` starts with, below its front matter.
    public static func body(title: String, description: String) -> String {
        "# \(title)\n\n\(description)"
    }

    // MARK: Disk → database

    /// Mirrors the archive tree into the database: adoptions, renames, moves, edits and removals.
    @discardableResult
    public func sync(root: URL) async throws -> [TaxonomyChange] {
        let scanned = try scan(root: root)
        let existing = try await database.reader.read { db in try FolderRecord.fetchAll(db) }
        let live = existing.filter { !$0.isArchived }
        let byCode = Dictionary(live.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        let byInode = Dictionary(live.compactMap { r in r.inode.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let byPath = Dictionary(live.map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })
        // A folder with `_about.md` is known by the code in it; one the user made, by its directory (followed through a
        // rename) or else by where it is. Codes are settled before the transaction, so new ones never repeat.
        var used = Set(existing.map(\.code))
        var seen = Set<String>()
        var resolved: [(item: ScannedFolder, prior: FolderRecord?, code: String)] = []
        for item in scanned {
            let prior = item.definition.map { byCode[$0.code] }
                ?? item.inode.flatMap { byInode[$0] }.flatMap { $0.relPath == item.relPath || byPath[item.relPath] == nil ? $0 : nil }
                ?? byPath[item.relPath]
            let code = item.definition?.code ?? prior?.code ?? FolderCode.next(after: used)
            used.insert(code)
            guard seen.insert(code).inserted else {
                Log.warning(.taxonomy, "Two folders carry the same code; the second is left out", ["code": code, "path": item.relPath])
                continue
            }
            resolved.append((item, prior, code))
        }
        let (planned, present) = (resolved, seen)
        let changes: [TaxonomyChange] = try await database.writer.write { db in
            var changes: [TaxonomyChange] = []
            var idByPath: [String: Int64] = [:]
            for (item, prior, code) in planned {
                let def = item.definition
                let now = Date()
                let parentID = item.parentRelPath.flatMap { idByPath[$0] }
                var record = prior ?? FolderRecord(
                    id: nil, uid: UUID().uuidString, parentId: parentID, code: code, name: item.name, relPath: item.relPath,
                    role: nil, autoFile: false, yearSubfolders: false, yearRule: YearRule.documentDate.rawValue,
                    origin: FolderOrigin.inferred.rawValue, levelKind: nil, logicVersion: nil, description: "", aboutJson: "{}",
                    descriptionHash: "", generatedHash: nil,
                    userEdited: false, inode: item.inode, sort: item.sort, isArchived: false, createdAt: now, updatedAt: now)
                let isNew = record.id == nil
                let oldPath = record.relPath
                let oldAbout = record.aboutJson
                let oldParent = record.parentId
                let oldMeaning = (record.levelKind, record.logicVersion)
                record.parentId = parentID
                record.name = item.name
                record.relPath = item.relPath
                record.role = def?.role?.rawValue
                record.autoFile = def?.autoFile ?? false
                record.yearSubfolders = def?.yearSubfolders ?? false
                record.yearRule = (def?.yearRule ?? .documentDate).rawValue
                record.origin = (def.map { $0.origin ?? .user } ?? .inferred).rawValue
                record.levelKind = def?.kind?.rawValue
                record.logicVersion = def?.logic
                record.description = def?.description ?? ""
                record.aboutJson = JSON.string(item.about)
                record.generatedHash = def?.generatedHash
                record.userEdited = !item.pristine
                record.inode = item.inode
                record.sort = item.sort
                if isNew || record.aboutJson != oldAbout || record.relPath != oldPath || record.parentId != oldParent
                    || oldMeaning != (record.levelKind, record.logicVersion) {
                    record.updatedAt = now
                    try record.save(db)
                }
                idByPath[item.relPath] = record.id
                if isNew {
                    changes.append(TaxonomyChange(kind: def == nil ? .inferred : .adopted, code: code, path: item.relPath, detail: item.name))
                    try HistoryStore.insert(db, .folderCreated, summary: "Folder \(item.relPath)",
                                            payload: ["code": code, "path": item.relPath, "origin": record.origin])
                } else if oldPath != item.relPath {
                    changes.append(TaxonomyChange(kind: .renamed, code: code, path: item.relPath, detail: oldPath))
                    try HistoryStore.insert(db, .folderRenamed, actor: .user, summary: "\(oldPath) → \(item.relPath)",
                                            payload: ["from": oldPath, "to": item.relPath])
                    try Self.rebasePaths(db, root: root, from: oldPath, to: item.relPath)
                } else if oldAbout != "{}", JSON.decode(FolderAbout.self, from: oldAbout)?.body != item.about.body
                            || prior?.description != record.description {
                    changes.append(TaxonomyChange(kind: .edited, code: code, path: item.relPath, detail: "description"))
                    try HistoryStore.insert(db, .descriptionChanged, actor: item.pristine ? .system : .user,
                                            summary: "Description of \(item.relPath) changed", payload: ["code": code])
                }
            }
            for (code, record) in byCode where !present.contains(code) {
                var r = record
                r.isArchived = true
                r.updatedAt = Date()
                try r.update(db)
                try db.execute(sql: "UPDATE memories SET orphaned = 1 WHERE folder_id = ?", arguments: [r.id])
                changes.append(TaxonomyChange(kind: .removed, code: code, path: r.relPath, detail: r.name))
                try HistoryStore.insert(db, .folderRemoved, actor: .user, summary: "Folder \(r.relPath) disappeared",
                                        payload: ["code": code, "path": r.relPath])
            }
            if !changes.isEmpty {
                let v = try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM meta WHERE key = ?", arguments: [Self.versionKey]) ?? 0
                try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [Self.versionKey, String(v + 1)])
            }
            return changes
        }
        for invalid in scanned.filter({ $0.invalidReason != nil }) {
            Log.warning(.taxonomy, "Invalid folder description", ["path": invalid.relPath, "error": invalid.invalidReason ?? ""])
        }
        if !changes.isEmpty {
            try await regenerateIndex(root: root, snapshot: try await snapshot(root: root))
            Log.info(.taxonomy, "Taxonomy synced", ["changes": String(changes.count)])
        }
        return changes
    }

    /// Keeps document paths valid after a folder rename.
    private static func rebasePaths(_ db: Database, root: URL, from oldRel: String, to newRel: String) throws {
        let oldPrefix = root.appendingPathComponent(oldRel).path + "/"
        let newPrefix = root.appendingPathComponent(newRel).path + "/"
        try db.execute(sql: """
            UPDATE documents SET path = ? || substr(path, ?), updated_at = ? WHERE substr(path, 1, ?) = ?
            """, arguments: [newPrefix, oldPrefix.count + 1, Date().timeIntervalSince1970, oldPrefix.count, oldPrefix])
    }

    private struct ScannedFolder: Sendable {
        /// From `_about.md`; nil for a directory the user made, which has none.
        var definition: FolderDefinition?
        var about: FolderAbout
        var name: String
        var relPath: String
        var parentRelPath: String?
        var inode: Int64?
        var sort: Int
        var pristine: Bool
        var invalidReason: String?
    }

    /// Every folder in the archive, parents before children, down to `maxDepth`. Year folders, excluded subtrees and
    /// packages are not folders.
    private func scan(root: URL) throws -> [ScannedFolder] {
        var out: [ScannedFolder] = []
        var sort = 0
        func visit(_ directory: URL, relPath: String?, depth: Int) throws {
            for child in try subdirectories(of: directory) {
                let path = child.standardizedFileURL.path + "/"
                guard !excluded.contains(where: { path.hasPrefix($0) }) else { continue }
                if relPath != nil, YearFolder.matches(child.lastPathComponent) { continue }
                let rel = relPath.map { $0 + "/" + child.lastPathComponent } ?? child.lastPathComponent
                out.append(scanFolder(child, relPath: rel, parentRelPath: relPath, sort: &sort))
                if depth < config.maxDepth { try visit(child, relPath: rel, depth: depth + 1) }
            }
        }
        try visit(root, relPath: nil, depth: 1)
        return out
    }

    private func scanFolder(_ url: URL, relPath: String, parentRelPath: String?, sort: inout Int) -> ScannedFolder {
        let directoryName = url.lastPathComponent
        let aboutURL = url.appendingPathComponent(config.aboutFileName)
        let inode = FileFingerprint.inode(of: url)
        sort += 1
        var invalidReason: String?
        if fileManager.fileExists(atPath: aboutURL.path) {
            do {
                let about = try readAbout(aboutURL)
                var definition = about.definition
                definition.name = definition.name(fromDirectory: directoryName)
                return ScannedFolder(definition: definition, about: FolderAbout(about), name: definition.name, relPath: relPath,
                                     parentRelPath: parentRelPath, inode: inode, sort: sort, pristine: about.isPristine,
                                     invalidReason: nil)
            } catch {
                invalidReason = error.localizedDescription
            }
        }
        // A folder the user made, named as its directory.
        return ScannedFolder(definition: nil, about: FolderAbout.empty, name: directoryName,
                             relPath: relPath, parentRelPath: parentRelPath, inode: inode, sort: sort, pristine: false,
                             invalidReason: invalidReason)
    }

    private func subdirectories(of url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                            options: [.skipsHiddenFiles])
            .filter {
                let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return v?.isDirectory == true && v?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Snapshot

    public func version() async throws -> Int {
        Int(try await database.meta(Self.versionKey) ?? "0") ?? 0
    }

    public func records() async throws -> [FolderRecord] {
        try await database.reader.read { db in
            try FolderRecord.filter(Column("is_archived") == false).order(Column("sort")).fetchAll(db)
        }
    }

    public func snapshot(root: URL) async throws -> TaxonomySnapshot {
        let records = try await records()
        let documents = DocumentStore(database: database)
        let counts = try await documents.countsByFolder()
        let senders = try await documents.sendersByFolder()
        let types = try await documents.typesByFolder()
        let titles = try await documents.recentTitles(perFolder: config.recentTitlesPerFolder)
        let codeByID = Dictionary(uniqueKeysWithValues: records.compactMap { r in r.id.map { ($0, r.code) } })
        let folders: [TaxonomyFolder] = records.compactMap { r in
            guard let id = r.id else { return nil }
            let about = JSON.decode(FolderAbout.self, from: r.aboutJson)
            return TaxonomyFolder(
                id: id, code: r.code, name: r.name, parentCode: r.parentId.flatMap { codeByID[$0] }, relativePath: r.relPath,
                role: r.role.flatMap(FolderRole.init(rawValue:)), autoFile: r.autoFile, description: r.description,
                body: about?.body ?? "", learnedExamples: about?.learnedExamples ?? [],
                learnedCorrespondents: about?.learnedCorrespondents ?? [], yearSubfolders: r.yearSubfolders,
                yearRule: YearRule(rawValue: r.yearRule) ?? .documentDate, origin: FolderOrigin(rawValue: r.origin) ?? .user,
                documentCount: counts[id] ?? 0, recentTitles: titles[id] ?? [], kind: r.levelKind.flatMap(LevelKind.init(rawValue:)),
                logic: r.logicVersion, senders: senders[id] ?? [], documentTypes: types[id] ?? [])
        }
        var snapshot = TaxonomySnapshot(version: try await version(), rootPath: root.path, folders: folders)
        // A folder is embedded with the names above it: "Santander" under one company is not "Santander" under another.
        snapshot.folders = folders.map { folder in
            var hashed = folder
            let text = folder.embeddingText(path: snapshot.path(of: folder), bodyChars: config.embeddingBodyChars,
                                            exampleLimit: config.embeddingExampleLimit)
            hashed.descriptionHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            return hashed
        }
        return snapshot
    }

    // MARK: Edits

    public func aboutURL(for record: FolderRecord, root: URL) -> URL {
        root.appendingPathComponent(record.relPath).appendingPathComponent(config.aboutFileName)
    }

    public func readAbout(_ url: URL) throws -> AboutFile {
        try AboutFile.parse(String(contentsOf: url, encoding: .utf8), path: url.path)
    }

    private func write(_ about: AboutFile, to url: URL, hash: AboutFile.HashMode) async throws {
        let text = try about.render(hash: hash)
        await registry?.expect([url.path, url.deletingLastPathComponent().path])
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Saves an edited description (from the Browser or an accepted proposal) to disk and the database.
    public func updateDescription(folderID: Int64, root: URL, definition: FolderDefinition, body: String,
                                  actor: EventActor) async throws {
        guard let record = try await database.reader.read({ db in try FolderRecord.fetchOne(db, key: folderID) }) else {
            throw TaxonomyError.unknownFolder(folderID)
        }
        let url = root.appendingPathComponent(record.relPath).appendingPathComponent(config.aboutFileName)
        let learned = (try? readAbout(url))?.learned ?? LearnedBlock()
        var def = definition
        def.origin = actor == .user ? .user : (def.origin ?? .learned)
        try await write(AboutFile(definition: def, body: body, learned: learned), to: url, hash: actor == .user ? .preserve : .recompute)
        _ = try await sync(root: root)
    }

    /// Rewrites only the learned block (keeps user prose untouched).
    public func updateLearned(folderID: Int64, root: URL, learned: LearnedBlock) async throws {
        guard let record = try await database.reader.read({ db in try FolderRecord.fetchOne(db, key: folderID) }) else {
            throw TaxonomyError.unknownFolder(folderID)
        }
        let url = root.appendingPathComponent(record.relPath).appendingPathComponent(config.aboutFileName)
        var about = try readAbout(url)
        guard about.learned.examples != learned.examples || about.learned.correspondents != learned.correspondents else { return }
        about.learned = learned
        try await write(about, to: url, hash: about.isPristine ? .recompute : .preserve)
        _ = try await sync(root: root)
    }

    // MARK: Empty folders

    /// Removes folders that hold no documents: year folders, and folders whose only contents are the app's own
    /// `_about.md` and leftovers such as `.DS_Store`, deepest first, so a folder left empty by the removal of the ones
    /// inside it goes too. System folders are kept. A removed folder stays in the database as archived, description
    /// included, so nothing the user wrote about it is lost.
    /// - Parameter folderIDs: only these folders and the folders around them; nil considers the whole tree.
    /// - Returns: the folders removed.
    @discardableResult
    public func pruneEmpty(root: URL, folderIDs: Set<Int64>? = nil) async throws -> [TaxonomyFolder] {
        let snapshot = try await snapshot(root: root)
        let considered: Set<Int64> = folderIDs.map { ids in
            Set(snapshot.folders.filter { ids.contains($0.id) }.flatMap { snapshot.lineage(of: $0).map(\.id) })
        } ?? Set(snapshot.folders.map(\.id))
        let candidates = snapshot.folders.filter { $0.holdsUserDocuments && considered.contains($0.id) }
            .sorted { snapshot.depth(of: $0) > snapshot.depth(of: $1) }
        var removed: [TaxonomyFolder] = []
        for folder in candidates {
            let directory = snapshot.url(for: folder)
            for year in (try? subdirectories(of: directory)) ?? [] where YearFolder.matches(year.lastPathComponent) {
                _ = await removeIfEmpty(year)
            }
            if await removeIfEmpty(directory) { removed.append(folder) }
        }
        guard !removed.isEmpty else { return [] }
        let archived = removed
        try await database.writer.write { db in
            for folder in archived {
                try db.execute(sql: "UPDATE folders SET is_archived = 1, updated_at = ? WHERE id = ?",
                               arguments: [Date().unixSeconds, folder.id])
                try db.execute(sql: "UPDATE memories SET orphaned = 1 WHERE folder_id = ?", arguments: [folder.id])
                try HistoryStore.insert(db, .folderRemoved, summary: "Removed empty folder \(folder.relativePath)",
                                        payload: ["code": folder.code, "path": folder.relativePath])
            }
            let v = try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM meta WHERE key = ?", arguments: [Self.versionKey]) ?? 0
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [Self.versionKey, String(v + 1)])
        }
        try await regenerateIndex(root: root, snapshot: try await self.snapshot(root: root))
        Log.info(.taxonomy, "Removed empty folders", ["folders": removed.map(\.relativePath).joined(separator: ", ")])
        return removed
    }

    /// Deletes `directory` when it holds nothing but the app's own files. Leftovers are removed one by one and the
    /// directory with `rmdir`, which refuses a directory that is not empty, so a file that arrives meanwhile is never
    /// touched; the description is then written back.
    private func removeIfEmpty(_ directory: URL) async -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }
        // The documents file only lists what is here; when nothing else is left it is a leftover like any other.
        let leftovers = Set(config.prunableLeftovers + [config.aboutFileName, config.documentsFileName])
        guard names.allSatisfy(leftovers.contains) else { return false }
        let about = directory.appendingPathComponent(config.aboutFileName)
        let description = try? Data(contentsOf: about)
        await registry?.expect([directory.path, directory.deletingLastPathComponent().path]
            + names.map { directory.appendingPathComponent($0).path })
        for name in names {
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
            } catch {
                Log.warning(.taxonomy, "Could not remove leftover", ["path": directory.appendingPathComponent(name).path,
                                                                     "error": error.localizedDescription])
            }
        }
        if rmdir(directory.path) == 0 { return true }
        if let description, !fileManager.fileExists(atPath: about.path) {
            do {
                try description.write(to: about)
            } catch {
                Log.error(.taxonomy, "Could not restore folder description", ["path": about.path, "error": error.localizedDescription])
            }
        }
        return false
    }

    // MARK: _INDEX.md

    public func regenerateIndex(root: URL, snapshot: TaxonomySnapshot) async throws {
        let text = IndexFile.render(snapshot: snapshot, generatedAt: Date())
        let url = root.appendingPathComponent(config.indexFileName)
        await registry?.expect([url.path])
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// The parts of `_about.md` stored in `folders.about_json` for snapshots.
public struct FolderAbout: Sendable, Codable, Hashable {
    public var body: String
    public var learnedExamples: [String]
    public var learnedCorrespondents: [String]

    /// A folder without `_about.md`.
    static let empty = FolderAbout(body: "", learnedExamples: [], learnedCorrespondents: [])

    init(body: String, learnedExamples: [String], learnedCorrespondents: [String]) {
        self.body = body
        self.learnedExamples = learnedExamples
        self.learnedCorrespondents = learnedCorrespondents
    }

    public init(_ about: AboutFile) {
        body = about.body
        learnedExamples = about.learned.examples
        learnedCorrespondents = about.learned.correspondents
    }
}
