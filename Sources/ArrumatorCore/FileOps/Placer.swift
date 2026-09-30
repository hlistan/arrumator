import Foundation

public struct PlacementPlan: Sendable, Codable, Hashable {
    public var directory: String
    public var filename: String
}

/// Computes where a document goes, a directory of the archive given by the caller, and what it is called there, then
/// moves it and tags it with its identity.
public struct Placer: Sendable {
    public let builder: FilenameBuilder
    public let operations: FileOperations

    public init(builder: FilenameBuilder, operations: FileOperations) {
        self.builder = builder
        self.operations = operations
    }

    /// Under the name the model gave the document, when files are renamed; otherwise under its own.
    public func plan(analysis: DocumentAnalysis, source: SourceFile, directory: URL, settings: AppSettings) -> PlacementPlan {
        let filename = settings.renameFiles
            ? builder.name(for: analysis, source: source, transliterate: settings.transliterate)
            : source.originalFilename
        return PlacementPlan(directory: directory.path, filename: filename)
    }

    public func execute(_ plan: PlacementPlan, source: URL, sha256: String, documentUID: String,
                        originalName: String, filedAt: Date) throws -> MoveResult {
        let result = try operations.move(source, toDirectory: URL(fileURLWithPath: plan.directory, isDirectory: true),
                                         filename: plan.filename, expectedSHA256: sha256)
        let dest = URL(fileURLWithPath: result.to)
        do {
            try Xattr.set(Xattr.documentID, documentUID, on: dest)
            try Xattr.set(Xattr.originalName, originalName, on: dest)
            try Xattr.set(Xattr.filedAt, filedAt.formatted(.iso8601), on: dest)
        } catch {
            Log.warning(.fileops, "Could not tag filed document", ["path": dest.path, "error": error.localizedDescription])
        }
        return result
    }
}
