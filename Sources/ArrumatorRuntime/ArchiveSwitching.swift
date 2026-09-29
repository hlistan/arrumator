import Foundation

/// The archive a runtime is open on: where it is, where its index is kept, and its logic.
public struct ArchiveSummary: Sendable, Codable, Hashable {
    public var archive: String
    public var index: String
    /// The file the archive keeps its logic in, once written.
    public var logicFile: String?
    /// `LogicStore.version` of the logic.
    public var logicVersion: String
    /// The logic is the built-in text, unchanged, and follows new versions of the app.
    public var logicFollowsBuiltin: Bool
}

public enum ArchiveSwitchError: Error, LocalizedError {
    case alreadyOpen(String)
    case notAFolder(String)
    case insideIncoming(archive: String, incoming: String)
    case rethinkApplying

    public var errorDescription: String? {
        switch self {
        case let .alreadyOpen(path): "\(path) is already the archive"
        case let .notAFolder(path): "\(path) is a file, not a folder"
        case let .insideIncoming(archive, incoming):
            "\(archive) is inside the Incoming folder \(incoming); everything in it would be filed again"
        case .rethinkApplying: "A rethink is moving documents in this archive; switch once it has finished"
        }
    }
}
