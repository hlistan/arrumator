import Foundation

public enum FileOperationError: Error, LocalizedError {
    case sourceMissing(String)
    /// The file is no longer what was read of it: its size, modification time or identity on the volume differ from
    /// what was recorded then (`FileFingerprint.matches`), so it is not moved as though it were; what holds it reads it
    /// again.
    case sourceChanged(String)
    case verificationFailed(String)
    case notAFileName(String)
    case tooManyCollisions(String)
    /// Copied to another volume, the file could not go to the Trash, for the reason given, so it stays where it was and
    /// its copy went to the Trash in its place, rather than leave two of it. `copy` is where the copy stays when the
    /// Trash refused it too.
    case sourceNotTrashed(String, reason: String, copy: String?)
    /// The folder a file was to be moved into, as the archive's, is not there, as when it was renamed away or its disk
    /// is not attached: nothing is moved, and the folder is never made again where it was (`FileOperations.move`).
    case folderMissing(String)
    /// A package holds more items than the limit (`watcher.maxPackageItems`): too many for one document, as a photo
    /// library or an app holds; it is not walked further, nor taken.
    case tooManyItems(String, limit: Int)
    /// The file to bring back is not in the Trash the app was given: only what the Trash holds is taken out of it.
    case sourceNotInTrash(String)
    /// The item to bring back is a link, which is not the file it was recorded as, and which would be moved as the link.
    case sourceIsALink(String)

    public var errorDescription: String? {
        switch self {
        case let .sourceMissing(p): "Source file is gone: \(p)"
        case let .sourceChanged(p): "Source file changed while being processed: \(p)"
        case let .verificationFailed(p): "Copy verification failed for \(p)"
        case let .notAFileName(name): "“\(name)” is no file name: a file is only ever placed in the directory the app chose"
        case let .tooManyCollisions(p): "Could not find a free file name for \(p)"
        case let .sourceNotTrashed(p, reason, nil):
            "\(p) was not moved: the Trash would not take it (\(reason)), so it stays where it is, and its copy went to the Trash"
        case let .sourceNotTrashed(p, reason, copy?):
            "\(p) was not moved: the Trash would not take it (\(reason)), so it stays where it is; nor would the Trash take its copy, at \(copy)"
        case let .folderMissing(p): "The folder \(p) is not there, as when its disk is not attached: nothing is moved into it"
        case let .tooManyItems(p, limit):
            "\((p as NSString).lastPathComponent) holds more than \(Format.count(limit, "item")), too many for one document (watcher.maxPackageItems)"
        case let .sourceNotInTrash(p): "\(p) is not in the Trash, so it is not taken out of it"
        case let .sourceIsALink(p): "\(p) is a link, not a file, so it is not taken out of the Trash"
        }
    }
}

public struct MoveResult: Sendable, Codable, Hashable {
    public var from: String
    public var to: String
    public var crossVolume: Bool
    public var collisionIndex: Int?
}

/// Moves files without ever deleting user data: a rename on one volume, and across volumes a verified copy, after which
/// the source goes to the Trash (`Trashing`).
public struct FileOperations: Sendable {
    /// Whether `file` and the folder it is moved into are on one volume, where a move is a rename.
    public typealias VolumeCheck = @Sendable (_ file: URL, _ folder: URL) -> Bool

    /// Where a source moved to another volume goes once its copy is in place, and a copy taken back.
    let trash: any Trashing
    let sameVolume: VolumeCheck
    /// How a copy in progress is named, beside where it goes: hidden, and a name the watchers never take in.
    static let temporaryPrefix = ".arrumator-tmp-"

    public init(trash: any Trashing, sameVolume: @escaping VolumeCheck) {
        self.trash = trash
        self.sameVolume = sameVolume
    }

    /// Whether the volumes of `file` and `folder` are one, by their identifiers (`URLResourceKey.volumeIdentifierKey`);
    /// not when either cannot be told, so a move that cannot be shown to be a rename is a verified copy.
    public static func onOneVolume(_ file: URL, _ folder: URL) -> Bool {
        guard let a = try? file.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let b = try? folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return false }
        return a.isEqual(b)
    }

    /// Moves `source` to `destination`, a free path (`FilenameBuilder.uniqueDestination`) in `root` or a folder below it:
    /// a rename on one volume; across volumes, a copy that hashes as `expectedSHA256` (or as the source) is put in
    /// place, and then the source goes to the Trash. A source no longer as `fingerprint` recorded it, when given, is not
    /// moved (`sourceChanged`). The folders below `root` the destination needs are made; `root` itself, and anything
    /// above it, never is: one that is gone, as an archive renamed away or on a disk not attached, is `folderMissing`,
    /// as made again it would be an empty folder in its place, or one on the startup disk where the other was mounted.
    ///
    /// Across volumes, what a failure leaves, step by step (swift-apple.md F4): the copy is made beside `destination`
    /// under a temporary name, checked, given the source's dates, and only then renamed into place, so `destination`
    /// never holds anything but a whole, checked copy, and the temporary copy is removed whatever fails before it is in
    /// place. The source goes to the Trash last; when the Trash will not take it, the copy goes there instead
    /// (`sourceNotTrashed`), so the file is where it was, once, and a retry makes no second copy.
    public func move(_ source: URL, to destination: URL, within root: URL, collision: Int?, expectedSHA256: String?,
                     fingerprint: FileFingerprint?) throws -> MoveResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw FileOperationError.sourceMissing(source.path) }
        if let fingerprint, try !FileFingerprint.of(source).matches(fingerprint) { throw FileOperationError.sourceChanged(source.path) }
        let directory = destination.deletingLastPathComponent()
        try Self.makeFolders(down: directory, from: root)
        if sameVolume(source, directory) {
            try fm.moveItem(at: source, to: destination)
            Log.info(.fileops, "Moved", ["from": source.path, "to": destination.path])
            return MoveResult(from: source.path, to: destination.path, crossVolume: false, collisionIndex: collision)
        }
        try place(copyOf: source, at: destination, expectedSHA256: expectedSHA256)
        do {
            _ = try trash.trash(source)
        } catch {
            throw FileOperationError.sourceNotTrashed(source.path, reason: error.localizedDescription, copy: trashOrReport(destination))
        }
        Log.info(.fileops, "Copied across volumes and trashed source", ["from": source.path, "to": destination.path])
        return MoveResult(from: source.path, to: destination.path, crossVolume: true, collisionIndex: collision)
    }

    /// Brings a file out of the Trash to `destination`, a free path in a folder that is there, inside `root`: a rename on
    /// one volume; across volumes, a copy that hashes as `expectedSHA256` is put in place with its dates, as `move` puts
    /// one, and the source stays where it is in the Trash, as a file in the Trash goes nowhere but to the Trash and is
    /// never deleted (§4.2). It makes no folder: the folders of the archive are the user's, and one that is gone is
    /// `folderMissing` (`ReviewActions.putBack` chooses a folder that is there). What a failure leaves is what `move`
    /// leaves: `destination` never holds anything but a whole, checked file, and no copy in progress. Only a file the
    /// Trash holds (`Trashing.holds`) is brought back, never a link: a path read from a record is no leave to take any
    /// other file, and a link would be moved as the link.
    public func bringBack(_ source: URL, to destination: URL, within root: URL, expectedSHA256: String) throws -> MoveResult {
        let fm = FileManager.default
        guard trash.holds(source) else { throw FileOperationError.sourceNotInTrash(source.path) }
        guard let attributes = try? fm.attributesOfItem(atPath: source.path) else { throw FileOperationError.sourceMissing(source.path) }
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw FileOperationError.sourceIsALink(source.path) }
        let directory = destination.deletingLastPathComponent()
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else { throw FileOperationError.folderMissing(root.path) }
        guard fm.fileExists(atPath: directory.path, isDirectory: &isFolder), isFolder.boolValue else { throw FileOperationError.folderMissing(directory.path) }
        guard root.holds(destination.path) else { throw FileOperationError.notAFileName(destination.path) }
        if sameVolume(source, directory) {
            try fm.moveItem(at: source, to: destination)
            Log.info(.fileops, "Brought back from the Trash", ["from": source.path, "to": destination.path])
            return MoveResult(from: source.path, to: destination.path, crossVolume: false, collisionIndex: nil)
        }
        try place(copyOf: source, at: destination, expectedSHA256: expectedSHA256)
        Log.info(.fileops, "Copied back from the Trash across volumes", ["from": source.path, "to": destination.path])
        return MoveResult(from: source.path, to: destination.path, crossVolume: true, collisionIndex: nil)
    }

    /// Undoes `bringBack` when the document it was for cannot be recorded: a file renamed goes back to exactly where it
    /// was in the Trash, not to a new place of it; a copy made across volumes goes to the Trash, never deleted, the
    /// original being there still. The Trash refusing the copy throws what it threw, and the copy stays where it is.
    public func takeBack(_ moved: MoveResult) throws {
        if moved.crossVolume {
            _ = try trash.trash(URL(fileURLWithPath: moved.to))
        } else {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: moved.to), to: URL(fileURLWithPath: moved.from))
        }
    }

    /// Makes the folders from `root`, which must be there, down to `directory`, one at a time, so a `root` that goes
    /// meanwhile is not made again by making what is below it. `directory` is in `root` however either is spelled,
    /// through a link or in another case: the deepest folder of it that is there is compared with `root` as the disk
    /// spells both (`folderOnDisk`, as `URL.holds` compares), and only what is below that folder is made.
    static func makeFolders(down directory: URL, from root: URL) throws {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw FileOperationError.folderMissing(root.path)
        }
        var (there, missing) = (directory.standardized, [String]())
        while !FileManager.default.fileExists(atPath: there.path), there.pathComponents.count > 1 {
            missing.insert(there.lastPathComponent, at: 0)
            there = there.deletingLastPathComponent()
        }
        let (folderOnDisk, rootOnDisk) = (there.folderOnDisk.path, root.folderOnDisk.path)
        guard folderOnDisk == rootOnDisk || folderOnDisk.hasPrefix(rootOnDisk + "/") else { throw FileOperationError.notAFileName(directory.path) }
        var folder = there
        for name in missing {
            folder.appendPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch CocoaError.fileNoSuchFile {
                throw FileOperationError.folderMissing(root.path)
            }
        }
    }

    /// Puts a checked copy of `source`, with its dates, at `destination`, as `move` describes.
    private func place(copyOf source: URL, at destination: URL, expectedSHA256: String?) throws {
        let fm = FileManager.default
        // With the destination's extension, so the copy of a package is a package too, and is checked as one.
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(Self.temporaryPrefix + UUID().uuidString).appendingPathExtension(destination.pathExtension)
        var placed = false
        defer { if !placed { remove(temporary) } }
        try fm.copyItem(at: source, to: temporary)
        let expected = try expectedSHA256 ?? HashService.sha256(of: source)
        guard try HashService.sha256(of: temporary) == expected else { throw FileOperationError.verificationFailed(source.path) }
        let attrs = try fm.attributesOfItem(atPath: source.path)
        var dates: [FileAttributeKey: Any] = [:]
        for key in [FileAttributeKey.modificationDate, .creationDate] { dates[key] = attrs[key] as? Date }
        try fm.setAttributes(dates, ofItemAtPath: temporary.path)
        try fm.moveItem(at: temporary, to: destination)
        placed = true
    }

    /// Removes a copy in progress, the app's own: one left behind would be a second copy of a document nothing records.
    private func remove(_ temporary: URL) {
        guard FileManager.default.fileExists(atPath: temporary.path) else { return }
        do { try FileManager.default.removeItem(at: temporary) } catch {
            Log.error(.fileops, "Could not remove a copy in progress", ["path": temporary.path, "error": error.localizedDescription])
        }
    }

    /// Takes a copy just put in place back out, to the Trash, when the move it was made for cannot be finished; where it
    /// stays when the Trash will not take it either.
    private func trashOrReport(_ copy: URL) -> String? {
        do {
            _ = try trash.trash(copy)
            return nil
        } catch {
            Log.error(.fileops, "Could not take back a copy", ["path": copy.path, "error": error.localizedDescription])
            return copy.path
        }
    }
}
