import Foundation

/// A folder the user puts at the top of Incoming names a tag (docs/how-it-works.md#folders-in-incoming): every file in it,
/// at any depth, is given the folder's name, as the disk writes it, as a label of the user's own (`LabelKind.tag`), when it
/// is queued. Only the top folder counts, so the folders inside it give nothing, and a file directly in Incoming gets
/// none. A package, a folder macOS shows as one document, is a document and names nothing, and so does a folder the
/// watcher ignores, such as a hidden one. The folder is the user's: the app never moves, renames or removes it, so a file
/// put there later is tagged too, as paperless-ngx tags what is consumed from its subfolders
/// (docs/organizing-principles-sources.md#sources-for-labels).
public struct IncomingFolders: Sendable {
    public let incoming: URL
    public let watcher: WatcherConfig
    public let labels: LabelsConfig

    public init(incoming: URL, watcher: WatcherConfig, labels: LabelsConfig) {
        self.incoming = incoming
        self.watcher = watcher
        self.labels = labels
    }

    /// The tag the folder at the top of Incoming that holds `file` gives it; nil for a file directly in Incoming, one
    /// in a package there or in a folder the watcher ignores, and one elsewhere.
    public func tag(of file: URL) -> GivenTag? {
        guard let below = Self.components(of: file, under: incoming), below.count > 1, let first = below.first else { return nil }
        let folder = incoming.standardizedFileURL.appendingPathComponent(first, isDirectory: true)
        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .nameKey])
        guard values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true,
              !watcher.ignoredNamePrefixes.contains(where: { first.hasPrefix($0) }),
              let label = labels.label(values?.name ?? first, kind: .tag) else { return nil }
        return GivenTag(label: label, source: .folder, folder: folder.path)
    }

    /// The path components of `file` below `root`, however either is spelled (`/var` or `/private/var`); nil when it is not
    /// below it.
    static func components(of file: URL, under root: URL) -> [String]? {
        for (path, base) in [(file.standardizedFileURL, root.standardizedFileURL),
                             (file.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())] {
            let (parts, prefix) = (path.pathComponents, base.pathComponents)
            if parts.count > prefix.count, Array(parts.prefix(prefix.count)) == prefix { return Array(parts.dropFirst(prefix.count)) }
        }
        return nil
    }
}
