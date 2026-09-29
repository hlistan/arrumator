import Foundation

public struct PlacementPlan: Sendable, Codable, Hashable {
    public var folderCode: String
    public var folderID: Int64
    public var directory: String
    public var filename: String
    public var yearFolder: String?
}

public enum PlacementError: Error, LocalizedError {
    case unknownFolder(String)
    case notFileable(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownFolder(c): "Folder \(c) is not in the taxonomy"
        case let .notFileable(c): "Folder \(c) does not accept documents"
        }
    }
}

/// Computes where a document goes: into a folder of the tree, at whatever depth, or its year folder, never into a
/// folder that holds no documents of the user's or a system folder other than the review and duplicate folders.
public struct Placer: Sendable {
    public let builder: FilenameBuilder
    public let operations: FileOperations

    public init(builder: FilenameBuilder, operations: FileOperations) {
        self.builder = builder
        self.operations = operations
    }

    /// - Parameter userChosen: the user picked the folder explicitly, so any of the user's folders is allowed.
    public func plan(decision: FilingDecision, folderCode: String, source: SourceFile, taxonomy: TaxonomySnapshot,
                     settings: AppSettings, userChosen: Bool) throws -> PlacementPlan {
        guard let folder = taxonomy.folder(code: folderCode) else { throw PlacementError.unknownFolder(folderCode) }
        let isSystemTarget = folder.role == .needsReview || folder.role == .duplicates
        guard folder.acceptsFiles || isSystemTarget || (userChosen && folder.holdsUserDocuments) else {
            throw PlacementError.notFileable(folderCode)
        }
        var directory = taxonomy.url(for: folder)
        var yearFolder: String?
        // The decision says whether this document goes in a year folder; placements from learned evidence follow the folder.
        if decision.yearFolder ?? folder.yearSubfolders, !isSystemTarget {
            let year = (folder.yearRule == .fiscalPeriod ? decision.periodYear : nil)
                ?? decision.year
                ?? source.modifiedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
            if let year {
                yearFolder = String(year)
                directory = directory.appendingPathComponent(String(year), isDirectory: true)
            }
        }
        let filename: String
        if settings.renameFiles, !isSystemTarget {
            filename = builder.name(for: decision, source: source, transliterate: settings.transliterate)
        } else {
            filename = source.originalFilename
        }
        return PlacementPlan(folderCode: folderCode, folderID: folder.id, directory: directory.path, filename: filename,
                             yearFolder: yearFolder)
    }

    public func execute(_ plan: PlacementPlan, source: URL, sha256: String, documentUID: String,
                        originalName: String) throws -> MoveResult {
        let result = try operations.move(source, toDirectory: URL(fileURLWithPath: plan.directory, isDirectory: true),
                                         filename: plan.filename, expectedSHA256: sha256)
        let dest = URL(fileURLWithPath: result.to)
        do {
            try Xattr.set(Xattr.documentID, documentUID, on: dest)
            try Xattr.set(Xattr.originalName, originalName, on: dest)
            try Xattr.set(Xattr.filedAt, Date().formatted(.iso8601), on: dest)
        } catch {
            Log.warning(.fileops, "Could not tag filed document", ["path": dest.path, "error": error.localizedDescription])
        }
        return result
    }
}
