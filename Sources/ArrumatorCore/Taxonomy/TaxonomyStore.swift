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
    case unknownArea(String)
    case areaFull(String)
    case archiveFull
    case codeInUse(String)
    case invalidName(String)
    case missingSystemFolder(FolderRole)

    public var errorDescription: String? {
        switch self {
        case let .unknownFolder(id): "Folder \(id) does not exist"
        case let .unknownArea(a): "Area \(a) does not exist"
        case let .areaFull(a): "Area \(a) has no free category codes"
        case .archiveFull: "All area codes are in use"
        case let .codeInUse(c): "Code \(c) is already used"
        case let .invalidName(n): "Folder name \"\(n)\" is not allowed"
        case let .missingSystemFolder(role): "No system folder is configured for \(role.rawValue)"
        }
    }
}

/// Owns the folder tree. Nothing is pre-created: folders appear on demand (from model decisions, the user, or
/// lazily for system roles), and disk changes made by the user are mirrored into the database.
public actor TaxonomyStore {
    public let database: AppDatabase
    private let config: TaxonomyConfig
    /// Registers the store's own writes so the archive watcher does not mistake them for user edits.
    private let registry: SelfChangeRegistry?
    private let fileManager = FileManager.default
    static let versionKey = "taxonomy_version"

    public init(database: AppDatabase, config: TaxonomyConfig, registry: SelfChangeRegistry?) {
        self.database = database
        self.config = config
        self.registry = registry
    }

    // MARK: On-demand creation

    /// Returns the system folder for `role`, creating it (and the system area) the first time it is needed.
    public func ensureSystemFolder(_ role: FolderRole, root: URL) async throws -> TaxonomyFolder {
        if let existing = try await snapshot(root: root).folder(role: role) { return existing }
        guard let spec = config.systemFolder(role) else { throw TaxonomyError.missingSystemFolder(role) }
        let areaDir = try await directory(forArea: config.systemArea, root: root, origin: .system)
        let dir = areaDir.appendingPathComponent("\(spec.code) \(spec.name)", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let def = FolderDefinition(code: spec.code, area: config.systemArea.code, name: spec.name, role: role,
                                       description: spec.description, yearSubfolders: false, yearRule: nil, autoFile: false,
                                       origin: .system)
            try await write(AboutFile(definition: def, body: Self.body(code: spec.code, name: spec.name, description: spec.description)),
                      to: dir.appendingPathComponent(config.aboutFileName), hash: .recompute)
        }
        _ = try await sync(root: root)
        guard let folder = try await snapshot(root: root).folder(role: role) else { throw TaxonomyError.missingSystemFolder(role) }
        return folder
    }

    private func directory(forArea spec: SystemFolderSpec, root: URL, origin: FolderOrigin) async throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if let existing = try locateDirectory(code: spec.code, in: root) { return existing }
        let dir = root.appendingPathComponent("\(spec.code) \(spec.name)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let def = FolderDefinition(code: spec.code, area: nil, name: spec.name, description: spec.description, yearSubfolders: false,
                                   yearRule: nil, autoFile: false, origin: origin)
        try await write(AboutFile(definition: def, body: Self.body(code: spec.code, name: spec.name, description: spec.description)),
                  to: dir.appendingPathComponent(config.aboutFileName), hash: .recompute)
        return dir
    }

    /// Creates the folder described by `spec` (and its area when new) and returns it.
    @discardableResult
    public func materialize(_ spec: FolderSpec, root: URL, origin: FolderOrigin) async throws -> TaxonomyFolder {
        let areaCode: String
        if let code = spec.areaCode {
            guard try await snapshot(root: root).folder(code: code)?.kind == .area else { throw TaxonomyError.unknownArea(code) }
            areaCode = code
        } else {
            guard let name = spec.newAreaName else { throw TaxonomyError.invalidName("") }
            areaCode = try await createArea(root: root, name: name, description: spec.newAreaDescription ?? "", origin: origin).code
        }
        let name = Self.displayName(spec.name)
        return try await createCategory(root: root, areaCode: areaCode, code: nil, name: name, description: spec.description,
                                        body: Self.body(code: nil, name: name, description: spec.description),
                                        yearSubfolders: spec.yearSubfolders, yearRule: spec.yearRule, origin: origin)
    }

    /// Creates an area with the next free code, or with `code` when it is given and still free.
    @discardableResult
    public func createArea(root: URL, name rawName: String, description: String, origin: FolderOrigin,
                           code requested: String? = nil) async throws -> TaxonomyFolder {
        let name = Self.displayName(rawName)
        try Self.validate(name)
        if let existing = try await snapshot(root: root).areas.first(where: { Self.sameName($0.name, name) }) {
            Log.info(.taxonomy, "Area already exists; reusing it", ["code": existing.code, "name": name])
            return existing
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let used = Set(try await records().map(\.code)).union([config.systemArea.code])
        let code: String
        if let requested, JDCode.isArea(requested), !used.contains(requested) {
            code = requested
        } else {
            guard let free = JDCode.nextFreeArea(used: used, first: config.firstAreaCode, last: config.lastAreaCode) else {
                throw TaxonomyError.archiveFull
            }
            code = free
        }
        let def = FolderDefinition(code: code, area: nil, name: name, description: description, yearSubfolders: false,
                                   yearRule: nil, autoFile: true, origin: origin)
        let dir = root.appendingPathComponent(def.directoryName, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try await write(AboutFile(definition: def, body: Self.body(code: code, name: name, description: description)),
                  to: dir.appendingPathComponent(config.aboutFileName), hash: origin == .user ? .preserve : .recompute)
        _ = try await sync(root: root)
        guard let folder = try await snapshot(root: root).folder(code: code) else { throw TaxonomyError.codeInUse(code) }
        Log.info(.taxonomy, "Created area", ["code": code, "name": name, "origin": origin.rawValue])
        return folder
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).compare(b.trimmingCharacters(in: .whitespaces),
                                                       options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Names written entirely in lower case get their first letter capitalised; other names are kept as written.
    static func displayName(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == name.lowercased(), let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    static func validate(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix(".") else {
            throw TaxonomyError.invalidName(name)
        }
    }

    static func body(code: String?, name: String, description: String) -> String {
        "# \(code.map { "\($0) " } ?? "")\(name)\n\n\(description)"
    }

    // MARK: Disk → database

    /// Mirrors the archive tree into the database: adoptions, renames, edits and removals.
    @discardableResult
    public func sync(root: URL) async throws -> [TaxonomyChange] {
        let scanned = try scan(root: root)
        let existing = try await database.reader.read { db in try FolderRecord.fetchAll(db) }
        let byCode = Dictionary(existing.filter { !$0.isArchived }.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        let changes: [TaxonomyChange] = try await database.writer.write { [scanned] db in
            var changes: [TaxonomyChange] = []
            var seen = Set<String>()
            var idByCode: [String: Int64] = [:]
            for item in scanned.sorted(by: { $0.definition.kind == .area && $1.definition.kind != .area }) {
                let def = item.definition
                seen.insert(def.code)
                let now = Date()
                let parentID = def.area.flatMap { idByCode[$0] }
                var record = byCode[def.code] ?? FolderRecord(
                    id: nil, uid: UUID().uuidString, parentId: parentID, code: def.code, name: item.name, relPath: item.relPath,
                    kind: def.kind.rawValue, role: def.role?.rawValue, autoFile: def.autoFile, yearSubfolders: def.yearSubfolders,
                    yearRule: (def.yearRule ?? .documentDate).rawValue, origin: (def.origin ?? .user).rawValue,
                    description: def.description, aboutJson: "{}", descriptionHash: "", generatedHash: def.generatedHash,
                    userEdited: false, inode: item.inode, sort: item.sort, isArchived: false, createdAt: now, updatedAt: now)
                let isNew = record.id == nil
                let oldPath = record.relPath
                let oldAbout = record.aboutJson
                record.parentId = parentID
                record.name = item.name
                record.relPath = item.relPath
                record.kind = def.kind.rawValue
                record.role = def.role?.rawValue
                record.autoFile = item.inferred ? false : def.autoFile
                record.yearSubfolders = def.yearSubfolders
                record.yearRule = (def.yearRule ?? .documentDate).rawValue
                record.origin = (item.inferred ? FolderOrigin.inferred : (def.origin ?? .user)).rawValue
                record.description = def.description
                record.aboutJson = JSON.string(item.about)
                record.generatedHash = def.generatedHash
                record.userEdited = !item.pristine
                record.inode = item.inode
                record.sort = item.sort
                if isNew || record.aboutJson != oldAbout || record.relPath != oldPath {
                    record.updatedAt = now
                    try record.save(db)
                }
                idByCode[def.code] = record.id
                if isNew {
                    let kind: TaxonomyChange.Kind = item.inferred ? .inferred : .adopted
                    changes.append(TaxonomyChange(kind: kind, code: def.code, path: item.relPath, detail: item.name))
                    try HistoryStore.insert(db, .folderCreated, summary: "Folder \(def.code) \(item.name)",
                                            payload: ["code": def.code, "path": item.relPath, "origin": record.origin])
                } else if oldPath != item.relPath {
                    changes.append(TaxonomyChange(kind: .renamed, code: def.code, path: item.relPath, detail: oldPath))
                    try HistoryStore.insert(db, .folderRenamed, actor: .user, summary: "\(oldPath) → \(item.relPath)",
                                            payload: ["from": oldPath, "to": item.relPath])
                    try Self.rebasePaths(db, root: root, from: oldPath, to: item.relPath)
                } else if oldAbout != "{}", JSON.decode(FolderAbout.self, from: oldAbout)?.body != item.about.body
                            || byCode[def.code]?.description != def.description {
                    changes.append(TaxonomyChange(kind: .edited, code: def.code, path: item.relPath, detail: "description"))
                    try HistoryStore.insert(db, .descriptionChanged, actor: item.pristine ? .system : .user,
                                            summary: "Description of \(def.code) changed", payload: ["code": def.code])
                }
            }
            for (code, record) in byCode where !seen.contains(code) {
                var r = record
                r.isArchived = true
                r.updatedAt = Date()
                try r.update(db)
                try db.execute(sql: "UPDATE memories SET orphaned = 1 WHERE folder_id = ?", arguments: [r.id])
                changes.append(TaxonomyChange(kind: .removed, code: code, path: r.relPath, detail: r.name))
                try HistoryStore.insert(db, .folderRemoved, actor: .user, summary: "Folder \(code) \(r.name) disappeared",
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
        var definition: FolderDefinition
        var about: FolderAbout
        var name: String
        var relPath: String
        var inode: Int64?
        var sort: Int
        var pristine: Bool
        var inferred: Bool
        var invalidReason: String?
    }

    /// Scans `root/NN-NN Area/NN Category`. Folder identity is the code in `_about.md`, else the directory name.
    private func scan(root: URL) throws -> [ScannedFolder] {
        var out: [ScannedFolder] = []
        var sort = 0
        for areaURL in try subdirectories(of: root) {
            guard let area = try scanFolder(areaURL, relPath: areaURL.lastPathComponent, parentCode: nil, sort: &sort),
                  area.definition.kind == .area else { continue }
            out.append(area)
            for catURL in try subdirectories(of: areaURL) {
                let rel = area.relPath + "/" + catURL.lastPathComponent
                guard let cat = try scanFolder(catURL, relPath: rel, parentCode: area.definition.code, sort: &sort),
                      cat.definition.kind == .category else { continue }
                out.append(cat)
            }
        }
        return out
    }

    private func scanFolder(_ url: URL, relPath: String, parentCode: String?, sort: inout Int) throws -> ScannedFolder? {
        let dirName = url.lastPathComponent
        let parsed = JDCode.parse(directoryName: dirName)
        let aboutURL = url.appendingPathComponent(config.aboutFileName)
        let inode = FileFingerprint.inode(of: url)
        sort += 1
        if fileManager.fileExists(atPath: aboutURL.path) {
            do {
                let about = try readAbout(aboutURL)
                var def = about.definition
                if let parentCode, def.kind == .category, def.area != parentCode {
                    def.area = parentCode
                }
                let name = parsed?.code == def.code ? (parsed?.name ?? def.name) : def.name
                def.name = name
                return ScannedFolder(definition: def, about: FolderAbout(about), name: name, relPath: relPath, inode: inode,
                                     sort: sort, pristine: about.isPristine, inferred: false, invalidReason: nil)
            } catch {
                guard let parsed else { return nil }
                return inferred(parsed, parentCode: parentCode, relPath: relPath, inode: inode, sort: sort,
                                reason: error.localizedDescription)
            }
        }
        guard let parsed else { return nil }
        return inferred(parsed, parentCode: parentCode, relPath: relPath, inode: inode, sort: sort, reason: nil)
    }

    private func inferred(_ parsed: (code: String, name: String), parentCode: String?, relPath: String, inode: Int64?,
                          sort: Int, reason: String?) -> ScannedFolder? {
        let isArea = JDCode.isArea(parsed.code)
        guard isArea || (JDCode.isCategory(parsed.code) && parentCode != nil) else { return nil }
        let def = FolderDefinition(code: parsed.code, area: isArea ? nil : parentCode, name: parsed.name, description: "",
                                   yearSubfolders: false, yearRule: nil, autoFile: false, origin: .inferred)
        return ScannedFolder(definition: def, about: FolderAbout(AboutFile(definition: def, body: "")), name: parsed.name,
                             relPath: relPath, inode: inode, sort: sort, pristine: false, inferred: true, invalidReason: reason)
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

    private func locateDirectory(code: String, in parent: URL) throws -> URL? {
        for dir in try subdirectories(of: parent) {
            let aboutURL = dir.appendingPathComponent(config.aboutFileName)
            if let about = try? readAbout(aboutURL), about.definition.code == code { return dir }
            if JDCode.parse(directoryName: dir.lastPathComponent)?.code == code { return dir }
        }
        return nil
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
        let counts = try await documents.counts(byFolder: true)
        let titles = try await documents.recentTitles(perFolder: config.recentTitlesPerFolder)
        let codeByID = Dictionary(uniqueKeysWithValues: records.compactMap { r in r.id.map { ($0, r.code) } })
        let folders: [TaxonomyFolder] = records.compactMap { r in
            guard let id = r.id else { return nil }
            let about = JSON.decode(FolderAbout.self, from: r.aboutJson)
            var folder = TaxonomyFolder(
                id: id, code: r.code, name: r.name, parentCode: r.parentId.flatMap { codeByID[$0] }, relativePath: r.relPath,
                kind: FolderKind(rawValue: r.kind) ?? .category, role: r.role.flatMap(FolderRole.init(rawValue:)),
                autoFile: r.autoFile, description: r.description, body: about?.body ?? "",
                learnedExamples: about?.learnedExamples ?? [], learnedCorrespondents: about?.learnedCorrespondents ?? [],
                yearSubfolders: r.yearSubfolders, yearRule: YearRule(rawValue: r.yearRule) ?? .documentDate,
                origin: FolderOrigin(rawValue: r.origin) ?? .user, documentCount: counts[id] ?? 0, recentTitles: titles[id] ?? [])
            let text = folder.embeddingText(bodyChars: config.embeddingBodyChars, exampleLimit: config.embeddingExampleLimit)
            folder.descriptionHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            return folder
        }
        return TaxonomySnapshot(version: try await version(), rootPath: root.path, folders: folders)
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

    /// Creates a new category under `areaCode` with the next free code (or `code` when given).
    @discardableResult
    public func createCategory(root: URL, areaCode: String, code: String?, name rawName: String, description: String,
                               body: String, yearSubfolders: Bool, yearRule: YearRule?, origin: FolderOrigin) async throws -> TaxonomyFolder {
        let name = Self.displayName(rawName)
        try Self.validate(name)
        // One home per kind of document in each area: a category with this name in the area is reused.
        if let existing = try await snapshot(root: root).folders.first(where: {
            $0.kind == .category && $0.parentCode == areaCode && Self.sameName($0.name, name)
        }) {
            Log.info(.taxonomy, "Category already exists; reusing it", ["code": existing.code, "name": name])
            return existing
        }
        let records = try await records()
        guard let area = records.first(where: { $0.code == areaCode }) else { throw TaxonomyError.unknownArea(areaCode) }
        let used = Set(records.map(\.code))
        let newCode: String
        if let code {
            guard !used.contains(code), JDCode.area(of: code) == areaCode else { throw TaxonomyError.codeInUse(code) }
            newCode = code
        } else {
            guard let free = JDCode.nextFreeCategory(in: areaCode, used: used) else { throw TaxonomyError.areaFull(areaCode) }
            newCode = free
        }
        let def = FolderDefinition(code: newCode, area: areaCode, name: name, description: description,
                                   yearSubfolders: yearSubfolders, yearRule: yearSubfolders ? (yearRule ?? .documentDate) : nil,
                                   autoFile: true, origin: origin)
        let dir = root.appendingPathComponent(area.relPath).appendingPathComponent(def.directoryName, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = body.replacingOccurrences(of: "# \(name)", with: "# \(newCode) \(name)")
        try await write(AboutFile(definition: def, body: text), to: dir.appendingPathComponent(config.aboutFileName),
                  hash: origin == .user ? .preserve : .recompute)
        _ = try await sync(root: root)
        guard let folder = try await snapshot(root: root).folder(code: newCode) else { throw TaxonomyError.codeInUse(newCode) }
        Log.info(.taxonomy, "Created category", ["code": newCode, "name": name, "origin": origin.rawValue])
        return folder
    }

    // MARK: Empty folders

    /// Removes folders that hold no documents: year folders, categories and areas whose only contents are the app's
    /// own `_about.md` and leftovers such as `.DS_Store`. System folders are kept. A removed folder stays in the
    /// database as archived, description included, so nothing the user wrote about it is lost.
    /// - Parameter folderIDs: only these categories (and the areas they leave empty); nil considers the whole tree.
    /// - Returns: the areas and categories removed.
    @discardableResult
    public func pruneEmpty(root: URL, folderIDs: Set<Int64>? = nil) async throws -> [TaxonomyFolder] {
        let snapshot = try await snapshot(root: root)
        let categories = snapshot.folders.filter {
            $0.kind == .category && $0.role == nil && $0.origin != .system && (folderIDs?.contains($0.id) ?? true)
        }
        var removed: [TaxonomyFolder] = []
        for category in categories {
            let directory = snapshot.url(for: category)
            for year in try subdirectories(of: directory) where JDCode.isYearFolder(year.lastPathComponent) {
                _ = await removeIfEmpty(year)
            }
            if await removeIfEmpty(directory) { removed.append(category) }
        }
        let areaCodes = folderIDs == nil ? Set(snapshot.areas.map(\.code)) : Set(categories.compactMap(\.parentCode))
        for area in snapshot.areas where area.origin != .system && areaCodes.contains(area.code) {
            if await removeIfEmpty(snapshot.url(for: area)) { removed.append(area) }
        }
        guard !removed.isEmpty else { return [] }
        let archived = removed
        try await database.writer.write { db in
            for folder in archived {
                try db.execute(sql: "UPDATE folders SET is_archived = 1, updated_at = ? WHERE id = ?",
                               arguments: [Date().unixSeconds, folder.id])
                try db.execute(sql: "UPDATE memories SET orphaned = 1 WHERE folder_id = ?", arguments: [folder.id])
                try HistoryStore.insert(db, .folderRemoved, summary: "Removed empty folder \(folder.code) \(folder.name)",
                                        payload: ["code": folder.code, "path": folder.relativePath])
            }
            let v = try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM meta WHERE key = ?", arguments: [Self.versionKey]) ?? 0
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [Self.versionKey, String(v + 1)])
        }
        try await regenerateIndex(root: root, snapshot: try await self.snapshot(root: root))
        Log.info(.taxonomy, "Removed empty folders", ["folders": removed.map(\.code).joined(separator: ",")])
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

    public init(_ about: AboutFile) {
        body = about.body
        learnedExamples = about.learned.examples
        learnedCorrespondents = about.learned.correspondents
    }
}
