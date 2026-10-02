import Foundation

public enum IngestError: Error, LocalizedError {
    case documentNotPersisted
    case documentNotFound(Int64)
    case sourceMissing(String)
    case contentUnavailable(Int64)
    case invalidState(String)
    /// The Trash would not take the file at the path, for the reason given.
    case notTrashed(String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .documentNotPersisted: "Document has not been saved yet"
        case let .documentNotFound(id): "Document \(id) does not exist"
        case let .sourceMissing(p): "File is gone: \(p)"
        case let .contentUnavailable(id): "Extracted content for document \(id) is unavailable"
        case let .invalidState(why): why
        case let .notTrashed(path, reason): "Could not move \(path) to the Trash: \(reason)"
        }
    }
}
