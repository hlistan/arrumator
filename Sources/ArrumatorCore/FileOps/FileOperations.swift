import Foundation

public enum FileOperationError: Error, LocalizedError {
    case sourceMissing(String)
    case sourceChanged(String)
    case verificationFailed(String)
    case notAFileName(String)
    case tooManyCollisions(String)

    public var errorDescription: String? {
        switch self {
        case let .sourceMissing(p): "Source file is gone: \(p)"
        case let .sourceChanged(p): "Source file changed while being processed: \(p)"
        case let .verificationFailed(p): "Copy verification failed for \(p)"
        case let .notAFileName(name): "“\(name)” is no file name: a file is only ever placed in the directory the app chose"
        case let .tooManyCollisions(p): "Could not find a free file name for \(p)"
        }
    }
}

public struct MoveResult: Sendable, Codable, Hashable {
    public var from: String
    public var to: String
    public var crossVolume: Bool
    public var collisionIndex: Int?
}

/// Moves files without ever deleting user data: rename on the same volume, verified copy + Trash across volumes.
public struct FileOperations: Sendable {
    public let naming: NamingConfig
    /// Upper bound on ` (n)` suffix attempts before giving up.
    static let maxCollisionAttempts = 10_000

    public init(naming: NamingConfig) { self.naming = naming }

    /// First free URL for `name` inside `directory`, appending the collision suffix before the extension. `filename`
    /// must be one name, never a path: nothing it says can place the file anywhere but in `directory`.
    public func uniqueDestination(directory: URL, filename: String) throws -> (URL, Int?) {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains(FilenameBuilder.pathSeparator),
              !filename.unicodeScalars.contains("\u{0}") else { throw FileOperationError.notAFileName(filename) }
        let fm = FileManager.default
        let first = directory.appendingPathComponent(filename)
        if !fm.fileExists(atPath: first.path) { return (first, nil) }
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        for n in 2...Self.maxCollisionAttempts {
            let candidate = stem + String(format: naming.collisionFormat, n) + (ext.isEmpty ? "" : "." + ext)
            let url = directory.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: url.path) { return (url, n) }
        }
        throw FileOperationError.tooManyCollisions(first.path)
    }

    /// Moves `source` into `directory` as `filename`, verifying cross-volume copies by hash.
    public func move(_ source: URL, toDirectory directory: URL, filename: String, expectedSHA256: String?) throws -> MoveResult {
        guard FileManager.default.fileExists(atPath: source.path) else { throw FileOperationError.sourceMissing(source.path) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (destination, collision) = try uniqueDestination(directory: directory, filename: filename)
        return try move(source, to: destination, collision: collision, expectedSHA256: expectedSHA256)
    }

    /// Moves `source` to `destination`, a free path from `uniqueDestination`: a rename on the same volume, and across
    /// volumes a copy that must hash as `expectedSHA256` (or as the source) before the source goes to the Trash.
    public func move(_ source: URL, to destination: URL, collision: Int?, expectedSHA256: String?) throws -> MoveResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw FileOperationError.sourceMissing(source.path) }
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceVolume = try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let destVolume = try? directory.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let sameVolume = sourceVolume.map { s in destVolume.map { s.isEqual($0) } ?? false } ?? false
        if sameVolume {
            try fm.moveItem(at: source, to: destination)
            Log.info(.fileops, "Moved", ["from": source.path, "to": destination.path])
            return MoveResult(from: source.path, to: destination.path, crossVolume: false, collisionIndex: collision)
        }
        let temp = directory.appendingPathComponent(".arrumator-tmp-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: temp)
        let expected = try expectedSHA256 ?? HashService.sha256(of: source)
        guard try HashService.sha256(of: temp) == expected else {
            try? fm.removeItem(at: temp)
            throw FileOperationError.verificationFailed(source.path)
        }
        let attrs = try fm.attributesOfItem(atPath: source.path)
        try fm.moveItem(at: temp, to: destination)
        try fm.setAttributes([.modificationDate: attrs[.modificationDate] as Any,
                              .creationDate: attrs[.creationDate] as Any].filter { !($0.value is NSNull) },
                             ofItemAtPath: destination.path)
        try fm.trashItem(at: source, resultingItemURL: nil)
        Log.info(.fileops, "Copied across volumes and trashed source", ["from": source.path, "to": destination.path])
        return MoveResult(from: source.path, to: destination.path, crossVolume: true, collisionIndex: collision)
    }
}
