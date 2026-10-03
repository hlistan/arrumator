import Foundation

extension ArchiveRecords {
    // MARK: Finding record files

    /// Why a folder the file system gives no listing of at all is not read.
    static let notListed = "it cannot be listed"
    /// Why an archive whose folder is not there is not read: what it holds is not known, as on a disk that is not
    /// mounted or a cloud folder not connected, so it is neither taken for an archive without records nor written into.
    static let notThere = "no folder is there"

    /// What walking the archive found.
    struct ArchiveWalk {
        /// Every document in it, regular files and packages, a package as one (`Packages`), hidden files aside.
        var files: [URL] = []
        /// The record files among them, with the kind each holds.
        var records: [(RecordKind, URL)] = []
        /// The folders that are there but cannot be listed, each with why: what they hold is not known to be absent.
        var unlisted: [UnreadableRecordFile] = []
        /// The folders not looked into: those the watcher ignores. Incoming is never inside the archive
        /// (`AppSettings.problems`).
        var skipped: [String] = []
        /// Record files' staged text a crash left behind (`StagedRecordFile`).
        var staged: [URL] = []

        /// Whether `path` is in a folder that was not, or could not be, looked into.
        func hides(_ path: String) -> Bool {
            (skipped + unlisted.map(\.path)).contains { path.hasPrefix($0 + "/") }
        }
    }

    /// Walks the archive at `root`, leaving out the folders `skip` ignores, as nothing in them is a document of the archive
    /// or a record file.
    static func walk(_ root: URL, skip: SkipRules) -> ArchiveWalk {
        var walk = ArchiveWalk()
        // The archive itself not there is no archive without record files, unlike a folder gone while it is walked.
        guard isFolder(root) else {
            walk.unlisted = [UnreadableRecordFile(path: root.standardizedFileURL.path, reason: notThere)]
            return walk
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isHiddenKey]
        // Hidden items are left out here rather than by the enumerator, so a record file's staged text is seen.
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                    options: [.skipsPackageDescendants]) { url, error in
            // One gone while the folder is walked is simply not there.
            if (error as? CocoaError)?.code != .fileReadNoSuchFile {
                walk.unlisted.append(UnreadableRecordFile(path: url.standardizedFileURL.path, reason: error.localizedDescription))
            }
            return true
        }
        guard let walker else {
            walk.unlisted = [UnreadableRecordFile(path: root.standardizedFileURL.path, reason: notListed)]
            return walk
        }
        for case let url as URL in walker {
            // Listings resolve /var to /private/var; standardizing gives the paths the index stores.
            let url = url.standardizedFileURL
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isHidden == true {
                if values?.isDirectory == true {
                    walker.skipDescendants()
                } else if StagedRecordFile.isStaged(url.lastPathComponent, watcher: skip.watcher) {
                    walk.staged.append(url)
                }
            } else if values?.isDirectory == true, skip.isIgnoredDirectory(named: url.lastPathComponent) {
                walker.skipDescendants()
                walk.skipped.append(url.path)
            } else if values?.isRegularFile == true || values?.isPackage == true {
                walk.files.append(url)
            }
        }
        return walk
    }

    /// Removes record files' staged text a crash left between its writing and its rename (`StagedRecordFile`): it holds
    /// nothing the index lacks. Only one last written more than `records.stagedLeftoverMinutes` before now, by the file's
    /// own date: one younger may be another process's, as `arrumatorcli` flushing beside the app, about to take its record
    /// file's place, and one whose date cannot be read is left too. One that cannot be removed is logged and left.
    func removeStaged(_ staged: [URL]) {
        let oldest = time.now().addingTimeInterval(-config.records.stagedLeftoverMinutes * Units.secondsPerMinute)
        for url in staged {
            guard let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  written < oldest else { continue }
            do { try FileManager.default.removeItem(at: url) } catch {
                Log.warning(.db, "Could not remove a record file's staged text left behind", ["path": url.path, "error": error.localizedDescription])
                continue
            }
            Log.info(.db, "Removed a record file's staged text left behind", ["path": url.path])
        }
    }

    /// Whether the archive's folder is there: an archive whose folder is not is neither read nor written, nor filed into.
    public nonisolated var archiveIsThere: Bool { Self.isFolder(archive) }

    /// Whether a folder is at `url`.
    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The archive walked, with every record file in it and the kind it holds: the lists of documents first, and the
    /// search tasks before the conversations about them, as each refers to those before it. Files of a kind are read in
    /// the order of their paths, the shallower first, whatever order the disk lists them in: of two lists that name one
    /// document, as a folder and its copy made in Finder do, the first read has it when nothing else tells which holds
    /// its file (`ParsedRecords.upsert`), so a rebuild of a lost index gives it to the folder rather than to its copy,
    /// which Finder names after it, one level down or beside it.
    func recordFiles() async -> ArchiveWalk {
        var walk = Self.walk(archive, skip: SkipRules(watcher: config.watcher))
        walk.records = walk.files.compactMap { url in kind(of: url).map { ($0, url) } }
            .sorted { a, b in
                (Self.readingOrder(a.0), a.1.pathComponents.count, a.1.path) < (Self.readingOrder(b.0), b.1.pathComponents.count, b.1.path)
            }
        return walk
    }

    private static func readingOrder(_ kind: RecordKind) -> Int {
        switch kind {
        case .documents: 0
        case .history: 1
        case .labelRules: 2
        case .searchTasks: 3
        case .conversation: 4
        }
    }

    /// The kind of record file at `url` from where it is, or nil for a file that is none.
    func kind(of url: URL) -> RecordKind? {
        let url = url.standardizedFileURL
        if url.lastPathComponent == config.records.documentsFileName { return .documents(directory: url.deletingLastPathComponent().path) }
        if url.path == layout.labelRules.standardizedFileURL.path { return .labelRules }
        if url.path == layout.searchTasks.standardizedFileURL.path { return .searchTasks }
        if url.deletingLastPathComponent().path == layout.conversations.standardizedFileURL.path {
            return layout.task(ofConversationFile: url.lastPathComponent).map { .conversation(task: $0) }
        }
        guard url.deletingLastPathComponent().path == layout.history.standardizedFileURL.path else { return nil }
        return layout.month(ofHistoryFile: url.lastPathComponent).map { .history(month: $0) }
    }
}
