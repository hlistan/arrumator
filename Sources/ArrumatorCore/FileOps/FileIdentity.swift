import CryptoKit
import Foundation

/// What a file is on disk at a moment: its size, when it was last changed and its identity on the volume. What the
/// Incoming watcher compares to tell a file has stopped changing, and what a job keeps of the file it read to tell, before
/// it moves it, that it is still that file. A package (`Packages`) is what it holds: the sum of its files' sizes, and the
/// latest change to it or to anything in it, so writing into it, at any depth, changes it.
public struct FileFingerprint: Sendable, Codable, Hashable {
    public var size: Int64
    public var modified: Date?
    public var inode: Int64?

    public static func of(_ url: URL) throws -> FileFingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if attrs[.type] as? FileAttributeType == .typeDirectory, Packages.isPackage(url) {
            return try Packages.survey(url, limit: nil).fingerprint
        }
        return FileFingerprint(size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, modified: attrs[.modificationDate] as? Date,
                               inode: (attrs[.systemFileNumber] as? NSNumber)?.int64Value)
    }

    public static func inode(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.int64Value
    }

    /// How finely a modification time kept with a job compares: a job's payload is JSON, whose dates are ISO 8601 to the
    /// whole second (`JSON.encoder`), so a time read back may be up to this much earlier than the disk's.
    static let modificationPrecision: TimeInterval = 1

    /// Whether the file this fingerprint was taken of is still what `recorded` was taken of: the same size and identity
    /// on the volume, and a modification time that differs by less than the precision a recorded one keeps. What is not
    /// known of `recorded`, as of a job queued without it, is not compared.
    func matches(_ recorded: FileFingerprint) -> Bool {
        guard size == recorded.size, recorded.inode == nil || inode == recorded.inode else { return false }
        guard let then = recorded.modified else { return true }
        guard let now = modified else { return false }
        return abs(now.timeIntervalSince(then)) < Self.modificationPrecision
    }
}

extension URL {
    /// The path of the item at this URL as the file system spells it (`URLResourceKey.canonicalPathKey`): the links in
    /// its folders resolved, `/private` kept and each name in its case on disk, as FSEvents reports paths; the item
    /// itself is never followed, so a link names the link, not what it points to. For an item that is not there, as a
    /// destination, its folder so spelled (`folderOnDisk`) with its own name as written; as written when neither is
    /// there. The one form a path in Incoming is queued, looked up and recorded in, whoever names it: the watcher,
    /// `arrumatorcli ingest`, an undo or an evaluation.
    public var spelledOnDisk: URL {
        if let path = try? resourceValues(forKeys: [.canonicalPathKey]).canonicalPath { return URL(fileURLWithPath: path) }
        return deletingLastPathComponent().folderOnDisk.appendingPathComponent(lastPathComponent)
    }

    /// This folder as the file system spells what is in it (`canonicalFolderPath`): through every link, its own
    /// included, as FSEvents reports the paths of what changes in it; as written when it is not there. What Incoming
    /// and the folders a watcher leaves out are compared as.
    public var folderOnDisk: URL {
        canonicalFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? standardizedFileURL
    }

    /// Whether the item at `path` is in this folder, at any depth, however either is spelled: through a link, in another
    /// case, `/private` or not. The folder that holds the item and this folder are compared as the disk spells them
    /// (`folderOnDisk`); an item whose folder is gone is compared as its path is written against this folder's
    /// spellings (`spellings`). What "in the archive" means wherever it is asked.
    public func holds(_ path: String) -> Bool {
        let folder = folderOnDisk.path
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        let held = { (item: String, root: String) in item == root || item.hasPrefix(root + "/") }
        if parent.canonicalFolderPath != nil { return held(parent.folderOnDisk.path, folder) }
        return spellings.contains { held(parent.standardizedFileURL.path, $0) }
    }

    /// The ways a path recorded under this folder may begin: as it is written, as the disk spells it, and that without
    /// `/private`, as a path is recorded by what named it, the settings or a watcher. Each is a folder path without a
    /// closing separator.
    public var spellings: [String] {
        let onDisk = folderOnDisk
        var all: [String] = []
        for path in [standardizedFileURL.path, onDisk.path, onDisk.standardizedFileURL.path] where !all.contains(path) { all.append(path) }
        return all
    }
}

/// The SHA-256 a document is known by: of a file, its bytes; of a package (`Packages`), a digest over what it holds.
public enum HashService {
    /// Read size for streamed hashing; large enough to amortise syscalls, small enough to keep memory flat.
    static let chunkSize = 1 << 20

    /// What each kind of item in a package is written as in its digest, before its path.
    static func tag(_ kind: Packages.Entry.Kind) -> UInt8 {
        switch kind {
        case .file: UInt8(ascii: "f")
        case .folder: UInt8(ascii: "d")
        case .link: UInt8(ascii: "l")
        case .other: UInt8(ascii: "o")
        }
    }

    /// The SHA-256 of the file at `url`, in lower-case hex. A package's is one over every item it holds, in the order of
    /// their paths in it (`Packages.Entry.path`, byte by byte), whatever order the disk lists them in: for each, its
    /// kind, its path (its length first, as a 64-bit big-endian count, then its UTF-8 bytes), and then, for a file, the
    /// SHA-256 of its bytes and, for a link, where it points, length first. So it is the same for a copy, wherever and
    /// under whatever name, however the disk orders or composes the names in it, and any change to what it holds, a
    /// byte, a name or an item added, changes it.
    public static func sha256(of url: URL) throws -> String {
        guard Packages.isPackage(url) else { return hex(try digest(ofFile: url)) }
        var hasher = SHA256()
        let entries = try Packages.entries(of: url, limit: nil).sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        for entry in entries {
            hasher.update(data: Data([tag(entry.kind)]))
            hasher.update(data: lengthPrefixed(entry.path))
            switch entry.kind {
            case .file: hasher.update(data: Data(try digest(ofFile: entry.url)))
            case .link: hasher.update(data: lengthPrefixed(try FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path)))
            case .folder, .other: break
            }
        }
        return hex(hasher.finalize())
    }

    private static func digest(ofFile url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    private static func lengthPrefixed(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        return withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { Data($0) } + bytes
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

public enum XattrError: Error, LocalizedError {
    case failed(name: String, path: String, errno: Int32)
    public var errorDescription: String? {
        switch self {
        case let .failed(name, path, e): "xattr \(name) on \(path) failed: \(String(cString: strerror(e)))"
        }
    }
}

/// Extended attributes written on filed documents and managed folders.
public enum Xattr {
    public static let documentID = "com.arrumator.docid"
    public static let originalName = "com.arrumator.original-name"
    public static let filedAt = "com.arrumator.filed-at"

    public static func set(_ name: String, _ value: String, on url: URL) throws {
        let data = Array(value.utf8)
        let rc = url.withUnsafeFileSystemRepresentation { path in
            setxattr(path, name, data, data.count, 0, 0)
        }
        if rc != 0 { throw XattrError.failed(name: name, path: url.path, errno: errno) }
    }

    /// Takes the attribute `name` off the file at `url`; one without it is left as it is.
    static func remove(_ name: String, from url: URL) throws {
        let rc = url.withUnsafeFileSystemRepresentation { path in
            removexattr(path, name, 0)
        }
        if rc != 0, errno != ENOATTR { throw XattrError.failed(name: name, path: url.path, errno: errno) }
    }

    public static func get(_ name: String, from url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, name, &buffer, size, 0, 0)
            guard read > 0 else { return nil }
            return String(decoding: buffer.prefix(read), as: UTF8.self)
        }
    }
}
