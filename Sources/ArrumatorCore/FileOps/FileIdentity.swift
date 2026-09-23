import CryptoKit
import Foundation

/// Size/mtime/inode snapshot of a file, used for stability checks and move reconciliation.
public struct FileFingerprint: Sendable, Codable, Hashable {
    public var size: Int64
    public var modified: Date?
    public var inode: Int64?
    public var volume: String?

    public static func of(_ url: URL) throws -> FileFingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey])
        return FileFingerprint(size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                               modified: attrs[.modificationDate] as? Date,
                               inode: (attrs[.systemFileNumber] as? NSNumber)?.int64Value,
                               volume: values?.volumeIdentifier.map { String(describing: $0) })
    }

    public static func inode(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.int64Value
    }
}

public enum HashService {
    /// Read size for streamed hashing; large enough to amortise syscalls, small enough to keep memory flat.
    static let chunkSize = 1 << 20

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
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
    public static let folderID = "com.arrumator.folderid"

    public static func set(_ name: String, _ value: String, on url: URL) throws {
        let data = Array(value.utf8)
        let rc = url.withUnsafeFileSystemRepresentation { path in
            setxattr(path, name, data, data.count, 0, 0)
        }
        if rc != 0 { throw XattrError.failed(name: name, path: url.path, errno: errno) }
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

    public static func remove(_ name: String, from url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in removexattr(path, name, 0) }
    }
}
