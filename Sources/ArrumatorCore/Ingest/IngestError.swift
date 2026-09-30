import Foundation

public enum IngestError: Error, LocalizedError {
    case documentNotPersisted
    case documentNotFound(Int64)
    case sourceMissing(String)
    case contentUnavailable(Int64)
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .documentNotPersisted: "Document has not been saved yet"
        case let .documentNotFound(id): "Document \(id) does not exist"
        case let .sourceMissing(p): "File is gone: \(p)"
        case let .contentUnavailable(id): "Extracted content for document \(id) is unavailable"
        case let .invalidState(why): why
        }
    }
}
