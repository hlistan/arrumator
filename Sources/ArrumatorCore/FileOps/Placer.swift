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

    /// Under the name the model gave the document, when files are renamed; otherwise, or when it gave none it can have,
    /// under the name it has now, at `current` (`FilenameBuilder.name`).
    public func plan(analysis: DocumentAnalysis, current: URL, directory: URL, settings: AppSettings) -> PlacementPlan {
        let filename = settings.renameFiles
            ? builder.name(for: analysis, current: current.lastPathComponent, transliterate: settings.transliterate)
            : current.lastPathComponent
        return PlacementPlan(directory: directory.path, filename: filename)
    }

    /// Whether `plan` leaves the document at `current` where it is: in its own directory, under a name that is its own
    /// but for case or the collision suffix it was given (`FilenameBuilder.isSameName`).
    func keeps(_ plan: PlacementPlan, at current: URL) -> Bool {
        URL(fileURLWithPath: plan.directory).folderOnDisk == current.deletingLastPathComponent().folderOnDisk
            && builder.isSameName(current.lastPathComponent, as: plan.filename)
    }

    /// Where `plan` puts a document: under a free name in its directory (`FilenameBuilder.uniqueDestination`), and the
    /// collision suffix that name was given, if any.
    public func destination(of plan: PlacementPlan) throws -> (url: URL, collision: Int?) {
        try builder.uniqueDestination(directory: URL(fileURLWithPath: plan.directory, isDirectory: true), filename: plan.filename)
    }

    /// Moves the document at `source` to `destination` (`destination(of:)`), in the archive at `archive`, which is never
    /// made again where it is gone (`FileOperationError.folderMissing`), and tags it with its identity. `fingerprint`,
    /// when given, is what the file was when it was read: one that has changed since is not moved
    /// (`FileOperationError.sourceChanged`).
    public func execute(to destination: (url: URL, collision: Int?), source: URL, archive: URL, sha256: String, fingerprint: FileFingerprint?,
                        documentUID: String, originalName: String, filedAt: Date) throws -> MoveResult {
        let result = try operations.move(source, to: destination.url, within: archive, collision: destination.collision, expectedSHA256: sha256,
                                         fingerprint: fingerprint)
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
