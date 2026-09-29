import Foundation

/// Which record file a change belongs to. Database triggers mark a kind dirty in the same transaction as the change
/// (see `AppDatabase.migrator`), and `ArchiveRecords` writes the file. The key is what the triggers store.
public enum RecordKind: Hashable, Sendable {
    /// The `_documents.md` of a directory, by its absolute path.
    case documents(directory: String)
    case senders
    /// The history of one month, `yyyy-MM` in UTC.
    case history(month: String)

    static let documentsPrefix = "documents:"
    static let historyPrefix = "history:"
    static let sendersKey = "senders"

    /// Documents keys end with a slash, as SQL derives the directory from a path.
    public var key: String {
        switch self {
        case let .documents(directory): Self.documentsPrefix + directory + "/"
        case .senders: Self.sendersKey
        case let .history(month): Self.historyPrefix + month
        }
    }

    public init?(key: String) {
        if key.hasPrefix(Self.documentsPrefix) {
            var directory = String(key.dropFirst(Self.documentsPrefix.count))
            if directory.hasSuffix("/") { directory.removeLast() }
            guard !directory.isEmpty else { return nil }
            self = .documents(directory: directory)
        } else if key.hasPrefix(Self.historyPrefix) {
            self = .history(month: String(key.dropFirst(Self.historyPrefix.count)))
        } else if key == Self.sendersKey {
            self = .senders
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
