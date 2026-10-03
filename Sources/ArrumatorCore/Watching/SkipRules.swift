import Foundation

/// Decides which paths are never ingested (temporary downloads, Office locks, app-managed files, …).
public struct SkipRules: Sendable {
    public let watcher: WatcherConfig

    public init(watcher: WatcherConfig) {
        self.watcher = watcher
    }

    /// Reason the file is ignored, or nil when it should be processed: its name (`ignoreReason(name:)`), or what it is,
    /// a link, a folder that is no package, anything else that is no regular file (a pipe, a socket, a device, which
    /// reading could wait on for ever), or a file iCloud has not downloaded. Nothing is said of what is not there.
    public func ignoreReason(_ url: URL) -> String? {
        if let reason = ignoreReason(name: url.lastPathComponent) { return reason }
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .isRegularFileKey,
                                                             .ubiquitousItemDownloadingStatusKey]) else { return nil }
        if values.isSymbolicLink == true { return "symbolic link" }
        if values.isDirectory == true, values.isPackage != true { return "directory" }
        if values.isDirectory != true, values.isRegularFile != true { return "not a regular file" }
        if let status = values.ubiquitousItemDownloadingStatus, status != .current { return "iCloud placeholder" }
        return nil
    }

    /// Reason a file of this name is ignored, whatever it is, or nil when its name lets it be processed. The app's own
    /// files are Markdown named with the managed-file prefix (`_documents.md`, history files), and so are those earlier
    /// versions left in folders; no document is given a name this refuses (`FilenameBuilder`).
    func ignoreReason(name: String) -> String? {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        if name.hasPrefix(watcher.managedFilePrefix), fileExtension == watcher.managedFileExtension { return "managed file" }
        if watcher.ignoredNames.contains(name) { return "ignored name" }
        if let p = watcher.ignoredNamePrefixes.first(where: { name.hasPrefix($0) }) { return "prefix \(p)" }
        if watcher.ignoredExtensions.contains(fileExtension) { return "temporary extension" }
        if let s = watcher.ignoredNameSubstrings.first(where: { name.contains($0) }) { return "contains \(s)" }
        return nil
    }

    /// True if `url` is inside any path component below `root` that is itself ignored (e.g. a hidden directory). Both
    /// are spelled alike, as the watcher spells them.
    public func isInsideIgnoredDirectory(_ url: URL, root: URL) -> Bool {
        url.pathComponents.dropFirst(root.pathComponents.count).dropLast().contains(where: isIgnoredDirectory(named:))
    }

    /// True if a directory of this name, and all it holds, is ignored.
    public func isIgnoredDirectory(named name: String) -> Bool {
        watcher.ignoredNamePrefixes.contains { name.hasPrefix($0) }
    }
}
