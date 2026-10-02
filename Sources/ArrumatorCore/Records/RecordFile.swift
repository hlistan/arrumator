import Foundation

/// A record file that is there but cannot be read: not text, not to be opened, or with front matter the app does not
/// read. What the user writes into a record file is theirs (AGENTS.md §4.2), so such a file is never written over or
/// removed, and is never taken for one that is not there: the app says which and why, and keeps what the index holds
/// for it until it reads again (docs/storage.md).
public struct UnreadableRecordFile: Sendable, Codable, Hashable {
    public var path: String
    /// Why, without quoting the file: where it breaks, or what keeps it from being opened.
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public enum RecordsError: Error, LocalizedError {
    case unreadable(String, String)
    case unwritable(String, String)
    case notWritten(String, String)
    /// A rebuild would drop what these record files, or folders of the archive, hold, as they cannot be read; it is not
    /// begun, and the index stays to be rebuilt.
    case unreadableFiles([UnreadableRecordFile])
    /// The index changed each of these times the archive was read for a rebuild, which was not done.
    case changedWhileRebuilding(Int)
    /// A change refused as the index has not been rebuilt from the archive yet, with the record files that kept its last
    /// rebuild from being done; none when it has not been tried.
    case notRebuilt([UnreadableRecordFile])

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, why): "Could not read the record file \(path): \(why)"
        case let .unwritable(path, why): "Could not write the record file \(path): \(why)"
        case let .notWritten(key, why): "The record file for \(key) was not written and will be tried again: \(why)"
        case let .unreadableFiles(files):
            "The index cannot be rebuilt from the archive: these record files or folders cannot be read, and a rebuild "
                + "without them would lose what they hold. " + Self.whatToDo + " " + Self.list(files)
        case let .changedWhileRebuilding(times):
            "The index was not rebuilt: it changed each of the \(times) times the archive was read for it, as the app or a "
                + "command kept recording. Try again."
        case let .notRebuilt(files) where files.isEmpty:
            "Nothing can be changed until the index is rebuilt from the archive, which is done when the archive is opened."
        case let .notRebuilt(files):
            "Nothing can be changed until the index is rebuilt from the archive, which these record files or folders keep "
                + "from being done, as they cannot be read. " + Self.whatToDo + " " + Self.list(files)
        }
    }

    /// What the user does about record files that keep the index from being rebuilt.
    private static let whatToDo = "Correct each, or move it out of the archive, then rebuild the index in Settings › Advanced, "
        + "open Arrumator again or run the command again."

    private static func list(_ files: [UnreadableRecordFile]) -> String {
        files.map { "\($0.path): \($0.reason)" }.joined(separator: "; ")
    }
}

/// Reading a record file from disk: the one place that tells a file that is not there from one that cannot be read.
enum RecordFile {
    /// Why a file of bytes that are not UTF-8 is not read, such as one an editor saved again as UTF-16.
    static let notUTF8 = "it is not UTF-8 text"

    /// The text of the record file at `url`, or nil when there is no such file. A file that is there but cannot be read
    /// throws `RecordsError.unreadable`, never nil: taking it for absent would have it written over.
    static func text(at url: URL) throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw RecordsError.unreadable(url.path, error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw RecordsError.unreadable(url.path, notUTF8) }
        return text
    }
}
