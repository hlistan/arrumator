import Foundation

public enum IngestError: Error, LocalizedError, Equatable {
    case documentNotPersisted
    case documentNotFound(Int64)
    case sourceMissing(String)
    case contentUnavailable(Int64)
    case invalidState(String)
    /// The Trash would not take the file at the path, for the reason given.
    case notTrashed(String, reason: String)
    /// A document was given a name it cannot have: one that leaves nothing a file name may hold once cleaned, as one of
    /// nothing but spaces, or one the app keeps for its own files (`FilenameBuilder.bounded`).
    case unusableFileName(String)
    /// A file named to be filed is one the Incoming watcher never takes in, for the reason given (`SkipRules`).
    case notTaken(String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .documentNotPersisted: "Document has not been saved yet"
        case let .documentNotFound(id): "Document \(id) does not exist"
        case let .sourceMissing(p): "File is gone: \(p)"
        case let .contentUnavailable(id): "Extracted content for document \(id) is unavailable"
        case let .invalidState(why): why
        case let .notTrashed(path, reason): "Could not move \(path) to the Trash: \(reason)"
        case let .notTaken(path, reason): "\(path) is not taken in: \(reason)"
        case let .unusableFileName(name) where name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            "A document needs a name; it cannot be blank"
        case let .unusableFileName(name):
            "“\(name)” cannot be a document's name: nothing a file name may hold is left of it, or it is a name Arrumator keeps for its own files"
        }
    }
}
