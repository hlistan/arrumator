import Foundation

/// Which record file a change belongs to. Database triggers mark a kind dirty in the same transaction as the change
/// (see `AppDatabase.migrator`), and `ArchiveRecords` writes the file. The key is what the triggers store.
public enum RecordKind: Hashable, Sendable {
    /// The `_documents.md` of a directory, by its absolute path.
    case documents(directory: String)
    /// The history of one month, `yyyy-MM` in UTC.
    case history(month: String)
    /// The user's rules for labels.
    case labelRules
    /// The user's search tasks and their exports.
    case searchTasks
    /// The questions about one search task's documents and their answers, by the task's number.
    case conversation(task: Int64)
    /// The sidecar of one document, by its number: what the model read it as and its text, beside it
    /// (`ArchiveRecords.renderSidecar`). Written from the index, never read back.
    case sidecar(document: Int64)

    static let documentsPrefix = "documents:"
    static let historyPrefix = "history:"
    static let conversationPrefix = "conversation:"
    static let sidecarPrefix = "sidecar:"
    static let labelRulesKey = "labels"
    static let searchTasksKey = "tasks"

    /// Documents keys end with a slash, as SQL derives the directory from a path.
    public var key: String {
        switch self {
        case let .documents(directory): Self.documentsPrefix + directory + "/"
        case let .history(month): Self.historyPrefix + month
        case .labelRules: Self.labelRulesKey
        case .searchTasks: Self.searchTasksKey
        case let .conversation(task): Self.conversationPrefix + String(task)
        case let .sidecar(document): Self.sidecarPrefix + String(document)
        }
    }

    public init?(key: String) {
        if key == Self.labelRulesKey {
            self = .labelRules
        } else if key == Self.searchTasksKey {
            self = .searchTasks
        } else if key.hasPrefix(Self.documentsPrefix) {
            var directory = String(key.dropFirst(Self.documentsPrefix.count))
            if directory.hasSuffix("/") { directory.removeLast() }
            guard !directory.isEmpty else { return nil }
            self = .documents(directory: directory)
        } else if key.hasPrefix(Self.historyPrefix) {
            self = .history(month: String(key.dropFirst(Self.historyPrefix.count)))
        } else if key.hasPrefix(Self.conversationPrefix), let task = Int64(key.dropFirst(Self.conversationPrefix.count)) {
            self = .conversation(task: task)
        } else if key.hasPrefix(Self.sidecarPrefix), let document = Int64(key.dropFirst(Self.sidecarPrefix.count)) {
            self = .sidecar(document: document)
        } else {
            return nil
        }
    }

    /// The UTC `yyyy-MM` month of a date, as the history triggers compute it.
    public static func month(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
