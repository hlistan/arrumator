import Foundation

/// A file as the disk knows it, by its volume and inode, rather than by how a path spells it. On a volume that ignores
/// case, as APFS does unless formatted otherwise, `bill.txt` finds `Bill.txt`; two paths are one file when they name the
/// same inode on the same volume (`stat(2)`). The device number is the volume's only while it is mounted: mounted again,
/// it is given another (`FolderIdentity` is the same across mounts).
struct FileOnDisk: Sendable, Hashable {
    let device: Int32
    let inode: UInt64

    init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// The file at `url`, links followed; nil when nothing is there.
    init?(_ url: URL) {
        var info = stat()
        let found = url.withUnsafeFileSystemRepresentation { path in path.map { stat($0, &info) == 0 } ?? false }
        guard found else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }

    /// The inode as the index keeps it (`DocumentRecord.inode`, `FileFingerprint.inode`).
    var number: Int64 { Int64(bitPattern: inode) }

    /// Whether `url`, inside the folder at `root`, is there under that very name, in the case the disk has it. On a volume
    /// that ignores case, a path that differs from the name on disk only in case finds the file all the same, though
    /// nothing is there under that name: a rename that changed only case leaves the old name naming what went. `rootOnDisk`
    /// is the folder as the disk names it (`canonicalFolderPath`); without it, or outside the folder, a path that finds a
    /// file counts as there.
    static func isThere(_ url: URL, inside root: URL, rootOnDisk: String?) -> Bool {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let top = root.standardizedFileURL.path
        guard let rootOnDisk, path.hasPrefix(top + "/") else { return true }
        return URL(fileURLWithPath: path).spelledOnDisk.path == rootOnDisk + path.dropFirst(top.count)
    }
}

/// A folder as the same folder whatever mounts its volume: the volume's own identifier (`volumeUUIDStringKey`), which
/// stays when the volume is mounted again while its device number does not, and the folder's inode. A volume without an
/// identifier is known by its name, and the folder by its path, as its device number and, on such formats, its folders'
/// numbers may change each time it is mounted; one without a name either, by its device number, as long as it stays
/// mounted.
struct FolderIdentity: Sendable, Hashable, Codable {
    /// The volume: its identifier, `named <name>`, or `device <number>`.
    let volume: String
    /// The folder on it: `inode <number>`, or `path <path>` on a volume known by its name.
    let place: String

    init(volume: String, place: String) {
        self.volume = volume
        self.place = place
    }

    /// As the index keeps it (`ArchiveWatcher.folderKey`).
    var stored: String { get throws { try JSON.string(self) } }

    /// The identity kept as `stored`; nil for anything else.
    init?(stored: String) {
        guard let identity = JSON.decode(FolderIdentity.self, from: stored) else { return nil }
        self = identity
    }
}

/// What watching the archive asks the disk: the file at a path, the identifier and the name of the volume a path is on,
/// and whether that volume gives each file an ID of its own for good. A test tells them otherwise, as a volume mounted
/// again, or of another format, would.
struct ArchiveDisk: Sendable {
    /// The file at a URL; nil when nothing is there.
    let file: @Sendable (URL) -> FileOnDisk?
    /// The identifier of the volume a URL is on, which stays when it is mounted again; nil for a volume without one.
    let volume: @Sendable (URL) -> String?
    /// The name of the volume a URL is on; nil when it cannot be told.
    let volumeName: @Sendable (URL) -> String?
    /// Whether the volume a URL is on keeps each file's ID for good, never giving one a deletion freed to another file
    /// (`volumeSupportsPersistentIDsKey`): APFS and HFS+ do, exFAT does not. Only there does an inode tell a file.
    let keepsFileIDs: @Sendable (URL) -> Bool

    /// The disk itself. Each answer is read afresh, from a URL of its own, as a URL keeps what it was told of a volume
    /// that may since have been mounted again.
    static let disk = ArchiveDisk(
        file: { FileOnDisk($0) },
        volume: { (try? URL(fileURLWithPath: $0.path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString },
        volumeName: { (try? URL(fileURLWithPath: $0.path).resourceValues(forKeys: [.volumeNameKey]))?.volumeName },
        keepsFileIDs: {
            (try? URL(fileURLWithPath: $0.path).resourceValues(forKeys: [.volumeSupportsPersistentIDsKey]))?.volumeSupportsPersistentIDs == true
        })

    /// The folder at `url` as the same folder across mounts; nil when nothing is there.
    func identity(of url: URL) -> FolderIdentity? {
        guard let found = file(url) else { return nil }
        if let volume = volume(url) { return FolderIdentity(volume: volume, place: "inode \(found.inode)") }
        if let name = volumeName(url) { return FolderIdentity(volume: "named \(name)", place: "path \(url.standardizedFileURL.path)") }
        return FolderIdentity(volume: "device \(found.device)", place: "inode \(found.inode)")
    }
}
