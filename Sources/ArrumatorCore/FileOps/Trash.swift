import Foundation

/// The Trash of the volume a file is on, from which the user can take it back ("trashItem(at:resultingItemURL:)",
/// Apple Developer Documentation › FileManager). A volume without a Trash, such as many network shares, refuses it.
public struct SystemTrash: Trashing {
    /// The Trash of the volume of a folder that is there; nil when the volume has none. The system's answer
    /// (`FileManager.url(for:in:appropriateFor:create:)`), which a test replaces so it needs no Trash of the machine's.
    private let trashOfVolume: @Sendable (URL) -> URL?

    public init() {
        self.init(trashOfVolume: { folder in
            try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: folder, create: false)
        })
    }

    init(trashOfVolume: @escaping @Sendable (URL) -> URL?) { self.trashOfVolume = trashOfVolume }

    public func trash(_ url: URL) throws -> URL? {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// In the Trash of the volume the item is on.
    public func holds(_ url: URL) -> Bool { folder(ofVolumeOf: url)?.holds(url.path) == true }

    /// The Trash of the volume the item at `url` is, or would be, on, asked of the nearest folder that is there, as the
    /// system takes none that is not; it is not made.
    func folder(ofVolumeOf url: URL) -> URL? { trashOfVolume(Self.nearestFolder(above: url)) }

    /// The nearest folder that is there above the item at `url`, which need not be. `url` comes from a record a person can
    /// edit, so `..` is taken out first (it would never shorten the walk), and the walk ends at the top whatever it is given.
    static func nearestFolder(above url: URL) -> URL {
        var nearest = url.standardizedFileURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: nearest.path) {
            let up = nearest.deletingLastPathComponent()
            guard up != nearest else { break }
            nearest = up
        }
        return nearest
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

    public func holds(_ url: URL) -> Bool { folder.holds(url.path) }
}
