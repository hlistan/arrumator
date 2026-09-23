import Foundation

/// Decides which paths are never ingested (temporary downloads, Office locks, app-managed files, …).
public struct SkipRules: Sendable {
    public let watcher: WatcherConfig
    public let managedNames: Set<String>

    public init(watcher: WatcherConfig, taxonomy: TaxonomyConfig) {
        self.watcher = watcher
        managedNames = [taxonomy.aboutFileName, taxonomy.documentsFileName, taxonomy.indexFileName]
    }

    /// Reason the file is ignored, or nil when it should be processed.
    public func ignoreReason(_ url: URL) -> String? {
        let name = url.lastPathComponent
        if managedNames.contains(name) { return "managed file" }
        if name.hasPrefix(watcher.managedFilePrefix), url.pathExtension.lowercased() == watcher.managedFileExtension {
            return "managed file"
        }
        if watcher.ignoredNames.contains(name) { return "ignored name" }
        if let p = watcher.ignoredNamePrefixes.first(where: { name.hasPrefix($0) }) { return "prefix \(p)" }
        if watcher.ignoredExtensions.contains(url.pathExtension.lowercased()) { return "temporary extension" }
        if let s = watcher.ignoredNameSubstrings.first(where: { name.contains($0) }) { return "contains \(s)" }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey,
                                                       .ubiquitousItemDownloadingStatusKey])
        if values?.isSymbolicLink == true { return "symbolic link" }
        if values?.isDirectory == true, values?.isPackage != true { return "directory" }
        if let status = values?.ubiquitousItemDownloadingStatus, status != .current { return "iCloud placeholder" }
        return nil
    }

    /// True if `url` is inside any path component that is itself ignored (e.g. a hidden directory).
    public func isInsideIgnoredDirectory(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents.count
        return url.standardizedFileURL.pathComponents.dropFirst(rootComponents).dropLast().contains { component in
            watcher.ignoredNamePrefixes.contains { component.hasPrefix($0) }
        }
    }
}
