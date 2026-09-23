import Foundation

public enum FolderKind: String, Sendable, Codable {
    case area, category
}

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

/// One area or category as the classifier and UI see it: structure, the prose description from `_about.md`,
/// and what the app has learned about its contents from usage.
public struct TaxonomyFolder: Sendable, Codable, Identifiable, Hashable {
    public var id: Int64
    public var code: String
    public var name: String
    public var parentCode: String?
    /// Relative to the archive root, e.g. `20-29 Money & taxes/23 Taxes (Portugal)`.
    public var relativePath: String
    public var kind: FolderKind
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
    public var recentTitles: [String]
    public var descriptionHash: String

    public init(id: Int64, code: String, name: String, parentCode: String?, relativePath: String, kind: FolderKind,
                role: FolderRole? = nil, autoFile: Bool = true, description: String = "", body: String = "",
                learnedExamples: [String] = [], learnedCorrespondents: [String] = [], yearSubfolders: Bool = false,
                yearRule: YearRule = .documentDate, origin: FolderOrigin = .learned, documentCount: Int = 0,
                recentTitles: [String] = [], descriptionHash: String = "") {
        self.id = id
        self.code = code
        self.name = name
        self.parentCode = parentCode
        self.relativePath = relativePath
        self.kind = kind
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

    /// Categories the classifier may file into automatically.
    public var acceptsFiles: Bool { kind == .category && autoFile && role == nil }
    /// A folder a rethink plan intends to create; it is not on disk yet and carries a negative id.
    public var isPlanned: Bool { id < 0 }

    /// Text embedded to represent the folder; its hash is `descriptionHash`, the embedding cache key.
    public func embeddingText(bodyChars: Int, exampleLimit: Int) -> String {
        var parts = ["\(code) \(name)", description, String(body.prefix(bodyChars))]
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
    public func children(of code: String) -> [TaxonomyFolder] { folders.filter { $0.parentCode == code } }
    public var areas: [TaxonomyFolder] { folders.filter { $0.kind == .area } }
    public var fileableCategories: [TaxonomyFolder] { folders.filter(\.acceptsFiles) }
    public func url(for folder: TaxonomyFolder) -> URL {
        rootURL.appendingPathComponent(folder.relativePath, isDirectory: true)
    }
    public static let empty = TaxonomySnapshot(version: 0, rootPath: "/", folders: [])
}
