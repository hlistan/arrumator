import Foundation

/// Looking at the disk for the archive watcher, away from its actor: in chunks, giving way between them, and ending when
/// the task is cancelled, so that a stop is never held behind a walk of the archive or a poll of many files.
extension ArchiveWatcher {
    struct Walked: Sendable {
        var files: [(path: String, sight: FileSight)] = []
        var holdsRecords = false
    }

    /// What `folder` holds, at any depth: each file and package, as `scope` names it, and how it is seen, but those the
    /// index has where they are with the same inode (`recorded`), and whether it holds a record file. Looked through in
    /// chunks, giving way between them; nil when its task is cancelled.
    static func walk(_ folder: URL, scope: ArchiveScope, recorded: [String: Int64]) async -> Walked? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return Walked() }
        var walked = Walked()
        var seen = 0
        while let item = walker.nextObject() as? URL {
            seen += 1
            if seen.isMultiple(of: Packages.chunk) {
                guard !Task.isCancelled else { return nil }
                await Task.yield()
            }
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard let path = scope.path(of: item.path) else {
                // Named outside the archive, as a listing need not name it.
                if values?.isDirectory == true { walker.skipDescendants() }
                continue
            }
            let url = URL(fileURLWithPath: path)
            if values?.isDirectory == true, values?.isPackage != true {
                if scope.skip.isIgnoredDirectory(named: url.lastPathComponent) { walker.skipDescendants() }
            } else if scope.isRecordFile(url.lastPathComponent) {
                walked.holdsRecords = true
            } else if values?.isRegularFile == true || values?.isPackage == true, scope.skip.ignoreReason(url) == nil {
                let sight = FileSight(url, packageItems: scope.config.maxPackageItems)
                guard !Task.isCancelled else { return nil }
                // Gone while the folder was looked through: the event that took it says so.
                if sight == .gone { continue }
                if case let .seen(fingerprint, _) = sight, let inode = recorded[path], inode == fingerprint.inode { continue }
                walked.files.append((path, sight))
            }
        }
        return Task.isCancelled ? nil : walked
    }

    /// How each of `paths` is seen now (`FileSight`), one not there under its name gone, in chunks, giving way between
    /// them; nil when its task is cancelled.
    static func measure(_ paths: [String], scope: ArchiveScope) async -> [String: FileSight]? {
        var measured: [String: FileSight] = [:]
        for (index, path) in paths.enumerated() {
            if index.isMultiple(of: Packages.chunk) {
                guard !Task.isCancelled else { return nil }
                await Task.yield()
            }
            let url = URL(fileURLWithPath: path)
            measured[path] = scope.isThere(url) ? FileSight(url, packageItems: scope.config.maxPackageItems) : .gone
        }
        return Task.isCancelled ? nil : measured
    }
}

/// What the archive watcher watches: the archive, as the settings name it, which is how the index's paths begin, and as
/// the disk names it. A value, so the disk is looked at away from the actor.
struct ArchiveScope: Sendable {
    let root: URL
    /// The archive as the disk names it: links resolved, in the case the disk has; nil when it cannot be told.
    let rootOnDisk: String?
    let skip: SkipRules
    let config: WatcherConfig

    /// `named`, a path in the archive as FSEvents or a listing names it, as the index's paths are written: under the
    /// archive as the settings name it. Whether it is in the archive is told as `URL.holds` tells it, by the ways a path
    /// under the archive may begin (`URL.spellings`): FSEvents names it as the disk does (`URL.folderOnDisk`), links
    /// resolved and in the case the disk has, and a listing of a folder in `/var` names it in `/private/var`. Nil for one
    /// outside the archive.
    func path(of named: String) -> String? {
        let given = URL(fileURLWithPath: named).standardizedFileURL.path
        for top in root.spellings where named.hasPrefix(top + "/") || given.hasPrefix(top + "/") {
            let suffix = named.hasPrefix(top + "/") ? named.dropFirst(top.count) : given.dropFirst(top.count)
            return root.path + suffix
        }
        return nil
    }

    /// The folder to look at again when events were lost under `named`: the archive itself for its own path or one
    /// above it.
    func folder(lostIn named: String) -> URL {
        path(of: named).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root
    }

    /// The app's own Markdown: the record files.
    func isRecordFile(_ name: String) -> Bool {
        name.hasPrefix(config.managedFilePrefix) && name.hasSuffix("." + config.managedFileExtension)
    }

    /// Whether what `url` names is there under that very name (`FileOnDisk.isThere`).
    func isThere(_ url: URL) -> Bool {
        FileOnDisk.isThere(url, inside: root, rootOnDisk: rootOnDisk)
    }
}
