import Foundation

/// The text of a record file written beside it before it takes the file's place (`ArchiveRecords.write`): a hidden file
/// named `.<UUID>.<record file's name>`, as `.2F1C….._documents.md`. Not `._…`, which macOS keeps for AppleDouble files
/// and leaves out of a folder's listing (`FileManager.enumerator`), so a staged file so named would never be found. One
/// a crash left between its writing and the rename holds nothing the index lacks, and is removed when the archive is
/// read (`ArchiveRecords.reconcile`, a rebuild) once older than `records.stagedLeftoverMinutes`, as a younger one may
/// be another process's (`ArchiveRecords.removeStaged`); no other file is, as no file of the user's is named so. It is
/// never taken for a document, whatever the watcher is set to ignore (`SkipRules`).
enum StagedRecordFile {
    /// Where the new text of the record file at `url` is written before it takes its place: a name of its own.
    static func url(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(url.lastPathComponent)")
    }

    /// Whether `name` is the name of a staged record file: a dot, a UUID, a dot, and the name of a record file (the
    /// managed prefix and extension, as `_documents.md`).
    static func isStaged(_ name: String, watcher: WatcherConfig) -> Bool {
        let parts = name.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, UUID(uuidString: String(parts[1])) != nil else { return false }
        let record = String(parts[2])
        return record.hasPrefix(watcher.managedFilePrefix) && (record as NSString).pathExtension.lowercased() == watcher.managedFileExtension
    }
}
