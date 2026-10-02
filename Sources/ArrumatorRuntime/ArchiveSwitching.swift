import Foundation

/// The archive a runtime is open on: where it is and where its index is kept.
public struct ArchiveSummary: Sendable, Codable, Hashable {
    public var archive: String
    public var index: String
}

/// What a switch of archives leaves: the runtime open on the archive switched to, and, when the record files of the
/// archive left could not be written, which archive that is and why. Its index keeps what they lack, and they are
/// written when that archive is next opened; the user is told so.
public struct ArchiveSwitch: Sendable {
    public let runtime: ArrumatorRuntime
    public let unwritten: UnwrittenRecords?
}

/// The record files of an archive that could not be written when the app switched away from it.
public struct UnwrittenRecords: Sendable, Hashable {
    public let archive: String
    public let reason: String

    /// What the user is told of it, in the app and by the command line.
    public var note: String {
        "The record files of the archive at \(archive) could not be written (\(reason)); they are written when it is next opened"
    }
}

public enum ArchiveSwitchError: Error, LocalizedError {
    case alreadyOpen(String)
    case notAFolder(String)
    case insideIncoming(archive: String, incoming: String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyOpen(path): "\(path) is already the archive"
        case let .notAFolder(path): "\(path) is a file, not a folder"
        case let .insideIncoming(archive, incoming):
            "\(archive) is inside the Incoming folder \(incoming); everything in it would be filed again"
        }
    }
}
