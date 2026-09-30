import Foundation

/// The archive a runtime is open on: where it is and where its index is kept.
public struct ArchiveSummary: Sendable, Codable, Hashable {
    public var archive: String
    public var index: String
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
