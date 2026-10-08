import Foundation

/// Where things are in an archive. Documents are filed at its top, each directory holding documents lists them in
/// its `_documents.md`, and the app's own files sit in one system folder: the history, the user's rules for labels, the
/// user's search tasks and the conversations about their documents.
/// Nothing else is made: the archive has no folders of the app's making for documents.
public struct ArchiveLayout: Sendable, Hashable {
    public let root: URL
    public let records: RecordsConfig
    public let watcher: WatcherConfig

    public init(root: URL, records: RecordsConfig, watcher: WatcherConfig) {
        self.root = root.standardizedFileURL
        self.records = records
        self.watcher = watcher
    }

    public var system: URL { root.appendingPathComponent(records.systemFolderName, isDirectory: true) }
    public var history: URL { system.appendingPathComponent(records.historyFolderName, isDirectory: true) }
    public var labelRules: URL { system.appendingPathComponent(records.labelRulesFileName) }
    public var searchTasks: URL { system.appendingPathComponent(records.searchTasksFileName) }
    public var conversations: URL { system.appendingPathComponent(records.conversationsFolderName, isDirectory: true) }

    /// The conversation about one search task's documents, named with the managed-file prefix and the task's number so
    /// nothing ingests it.
    public func conversationFile(task: Int64) -> URL {
        conversations.appendingPathComponent("\(watcher.managedFilePrefix)\(task).\(watcher.managedFileExtension)")
    }

    /// The task a conversation file's name stands for, or nil for any other name.
    public func task(ofConversationFile name: String) -> Int64? {
        let prefix = watcher.managedFilePrefix
        let suffix = "." + watcher.managedFileExtension
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let number = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !number.isEmpty, number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber) else { return nil }
        return Int64(number)
    }

    /// The history of one month, `yyyy-MM`, named with the managed-file prefix so nothing ingests it.
    public func historyFile(month: String) -> URL {
        history.appendingPathComponent("\(watcher.managedFilePrefix)\(month).\(watcher.managedFileExtension)")
    }

    /// The month a history file's name stands for, or nil for any other name.
    public func month(ofHistoryFile name: String) -> String? {
        let prefix = watcher.managedFilePrefix
        let suffix = "." + watcher.managedFileExtension
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let month = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return month.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) == nil ? nil : month
    }

    /// The longest name a file may have on the Mac's volumes (`NAME_MAX`), in UTF-16 units of the name as it is written:
    /// so APFS counts it, and HFS+ in its decomposed form (measured on APFS: a name of 255 Cyrillic letters, 510 bytes of
    /// UTF-8, is one; 256 ASCII letters, or 200 accented letters written decomposed, are none).
    public static let nameMaxUnits = Int(NAME_MAX)

    /// Whether `name` is one a file may have, however it is written (`nameMaxUnits`): counted decomposed, as Foundation
    /// may write a name, which is never shorter.
    public static func fits(_ name: String) -> Bool {
        name.decomposedStringWithCanonicalMapping.utf16.count <= nameMaxUnits
    }

    /// Where the sidecar of the document at `path` is: beside it, named after it with `watcher.sidecarSuffix`. Nil when that
    /// name would be longer than a file's name may be (`fits`), as for a name of the user's own near the limit; the app
    /// gives none such (`FilenameBuilder.bounded`).
    public func sidecar(of path: String) -> URL? {
        let document = URL(fileURLWithPath: path)
        let name = document.lastPathComponent + watcher.sidecarSuffix
        guard Self.fits(name) else { return nil }
        return document.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Inside the system folder, which holds no documents.
    public func isSystem(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == system.path || path.hasPrefix(system.path + "/")
    }
}
