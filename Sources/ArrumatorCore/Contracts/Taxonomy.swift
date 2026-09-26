import Foundation

/// App-managed system folders, created only when first needed.
public enum FolderRole: String, Sendable, Codable {
    case needsReview, duplicates
    /// Hold the record files of what the app learned, its logic and its history; never documents.
    case learned, logic, history

    /// Whether documents are filed into folders with this role.
    public var holdsDocuments: Bool { self == .needsReview || self == .duplicates }
}

public enum YearRule: String, Sendable, Codable {
    case documentDate = "document_date"
    case fiscalPeriod = "fiscal_period"
}

public enum FolderOrigin: String, Sendable, Codable {
    /// Created by the app from a model decision.
    case learned
    /// Created or described by the user.
    case user
    /// Found on disk without a description yet.
    case inferred
    /// App-managed system folder (review, duplicates).
    case system
}

/// One folder of the archive, at any depth, as the classifier and UI see it: structure, the prose description from
/// `_about.md`, and what the app has learned about its contents from usage. The tree takes whatever shape the logic
/// describes; a document can be filed into any folder of the user's.
public struct TaxonomyFolder: Sendable, Codable, Identifiable, Hashable {
    public var id: Int64
    /// The app's identifier for the folder, never shown as part of its name and never reused.
    public var code: String
    public var name: String
    /// The folder it is in; nil at the top of the archive.
    public var parentCode: String?
    /// Relative to the archive root, e.g. `Portugal/Hlistan Zolerani LDA/Banking/Santander`.
    public var relativePath: String
    public var role: FolderRole?
    public var autoFile: Bool
    public var description: String
    public var body: String
    public var learnedExamples: [String]
    public var learnedCorrespondents: [String]
    public var yearSubfolders: Bool
    public var yearRule: YearRule
    public var origin: FolderOrigin
    public var documentCount: Int
    /// What the folder stands for in the logic that made it; nil for folders the user made.
    public var kind: LevelKind?
    /// `LogicStore.version` of the logic that made the folder.
    public var logic: String?
    /// The senders of the documents filed in it (and, while a rethink plans, of those it would put there).
    public var senders: Set<Int64>
    /// The types of those documents.
    public var documentTypes: Set<DocumentType>
    public var recentTitles: [String]
    public var descriptionHash: String

    public init(id: Int64, code: String, name: String, parentCode: String?, relativePath: String, role: FolderRole? = nil, autoFile: Bool = true, description: String = "", body: String = "",
                learnedExamples: [String] = [], learnedCorrespondents: [String] = [], yearSubfolders: Bool = false,
                yearRule: YearRule = .documentDate, origin: FolderOrigin = .learned, documentCount: Int = 0,
                recentTitles: [String] = [], descriptionHash: String = "", kind: LevelKind? = nil, logic: String? = nil, senders: Set<Int64> = [], documentTypes: Set<DocumentType> = []) {
        self.id = id
        self.code = code
        self.name = name
        self.kind = kind
        self.logic = logic
        self.senders = senders
        self.documentTypes = documentTypes
        self.parentCode = parentCode
        self.relativePath = relativePath
        self.role = role
        self.autoFile = autoFile
        self.description = description
        self.body = body
        self.learnedExamples = learnedExamples
        self.learnedCorrespondents = learnedCorrespondents
        self.yearSubfolders = yearSubfolders
        self.yearRule = yearRule
        self.origin = origin
        self.documentCount = documentCount
        self.recentTitles = recentTitles
        self.descriptionHash = descriptionHash
    }

    /// A folder of the user's, rather than of the app's system area: where the user's documents live.
    public var holdsUserDocuments: Bool { role == nil && origin != .system }
    /// Folders the classifier may file into automatically.
    public var acceptsFiles: Bool { holdsUserDocuments && autoFile }
    /// A folder a rethink plan intends to create; it is not on disk yet and carries a negative id.
    public var isPlanned: Bool { id < 0 }

    /// Text embedded to represent the folder, `path` being the names from the top of the archive down to it; its hash
    /// is `descriptionHash`, the embedding cache key.
    public func embeddingText(path: String, bodyChars: Int, exampleLimit: Int) -> String {
        var parts = [path, description, String(body.prefix(bodyChars))]
        if !learnedExamples.isEmpty { parts.append("Filed here: " + learnedExamples.prefix(exampleLimit).joined(separator: "; ")) }
        return parts.joined(separator: "\n")
    }
}

public struct TaxonomySnapshot: Sendable, Codable {
    public var version: Int
    public var rootPath: String
    public var folders: [TaxonomyFolder]

    public init(version: Int, rootPath: String, folders: [TaxonomyFolder]) {
        self.version = version
        self.rootPath = rootPath
        self.folders = folders
    }

    public var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }
    public func folder(code: String) -> TaxonomyFolder? { folders.first { $0.code == code } }
    public func folder(id: Int64) -> TaxonomyFolder? { folders.first { $0.id == id } }
    public func folder(role: FolderRole) -> TaxonomyFolder? { folders.first { $0.role == role } }
    /// The folders directly inside `code`, or at the top of the archive for nil.
    public func children(of code: String?) -> [TaxonomyFolder] { folders.filter { $0.parentCode == code } }
    /// The user's folders at the top of the archive; the system area is left out.
    public var topLevel: [TaxonomyFolder] { children(of: nil).filter(\.holdsUserDocuments) }
    /// Every folder the classifier may file into.
    public var fileable: [TaxonomyFolder] { folders.filter(\.acceptsFiles) }
    public func url(for folder: TaxonomyFolder) -> URL {
        rootURL.appendingPathComponent(folder.relativePath, isDirectory: true)
    }

    /// The folders from the top of the archive down to `folder`, which comes last.
    public func lineage(of folder: TaxonomyFolder) -> [TaxonomyFolder] {
        var chain = [folder]
        var seen: Set<String> = [folder.code]
        while let code = chain[0].parentCode, let parent = self.folder(code: code), seen.insert(code).inserted {
            chain.insert(parent, at: 0)
        }
        return chain
    }

    /// Where `folder` is, by name from the top of the archive: `Portugal / Hlistan Zolerani LDA / Banking`.
    public func path(of folder: TaxonomyFolder, separator: String = TaxonomySnapshot.pathSeparator) -> String {
        lineage(of: folder).map(\.name).joined(separator: separator)
    }

    /// How many folders deep `folder` is; 1 at the top of the archive.
    public func depth(of folder: TaxonomyFolder) -> Int { lineage(of: folder).count }

    /// Every folder inside `code` (the whole archive for nil), parents before children in the tree's order, each with
    /// its depth below `code`: what an outline of the tree lists. `include` leaves out a folder and all inside it.
    public func outline(inside code: String? = nil, include: (TaxonomyFolder) -> Bool = { _ in true }) -> [(folder: TaxonomyFolder, depth: Int)] {
        var out: [(folder: TaxonomyFolder, depth: Int)] = []
        func visit(_ parent: String?, depth: Int) {
            for folder in children(of: parent) where include(folder) {
                out.append((folder, depth))
                visit(folder.code, depth: depth + 1)
            }
        }
        visit(code, depth: 1)
        return out
    }

    /// Where the folders of `spec` would be, by name from the top of the archive.
    public func path(of spec: FolderSpec, separator: String = TaxonomySnapshot.pathSeparator) -> String {
        let above = spec.parentCode.flatMap { folder(code: $0) }.map { lineage(of: $0).map(\.name) } ?? []
        return (above + spec.levels.map(\.name)).joined(separator: separator)
    }

    /// The path of the folder with `code`, for places that know a folder only by its code; nil once it is gone.
    public func path(ofCode code: String, separator: String = TaxonomySnapshot.pathSeparator) -> String? {
        folder(code: code).map { path(of: $0, separator: separator) }
    }

    /// Where a decision points, by path: the folder it names, or the one it proposes to create. Nil when it points
    /// nowhere, or at a folder that has since been removed. Folder codes are the app's own, so this is what people read.
    public func destination(of decision: FilingDecision, separator: String = TaxonomySnapshot.pathSeparator) -> (path: String, isNew: Bool)? {
        if let code = decision.folderCode { return path(ofCode: code, separator: separator).map { ($0, false) } }
        return decision.proposedNewFolder.map { (path(of: $0, separator: separator), true) }
    }

    /// Separates folder names where the model reads a path.
    public static let pathSeparator = " / "
    public static let empty = TaxonomySnapshot(version: 0, rootPath: "/", folders: [])
}
