import Foundation

/// The Trash of the volume a file is on, from which the user can take it back ("trashItem(at:resultingItemURL:)",
/// Apple Developer Documentation › FileManager). A volume without a Trash, such as many network shares, refuses it.
public struct SystemTrash: Trashing {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }
}

/// A folder that stands in for the Trash: each file it is given goes into a folder of its own inside it, under its own
/// name, so nothing it is given replaces anything.
public struct FolderTrash: Trashing {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public func trash(_ url: URL) throws -> URL? {
        let place = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let destination = place.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}
