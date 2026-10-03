import Foundation

public enum IngestError: Error, LocalizedError, Equatable {
    case documentNotPersisted
    case documentNotFound(Int64)
    case sourceMissing(String)
    case contentUnavailable(Int64)
    /// A job came to filing the document without what the model read of it.
    case analysisMissing(Int64)
    /// Only a document in the archive can be confirmed as filed: one left in Incoming is in none.
    case notInArchive(Int64)
    /// The Trash would not take the file at the path, for the reason given.
    case notTrashed(String, reason: String)
    /// A document was given a name it cannot have: one that leaves nothing a file name may hold once cleaned, as one of
    /// nothing but spaces, or one the app keeps for its own files (`FilenameBuilder.bounded`).
    case unusableFileName(String)
    /// A file named to be filed is one the Incoming watcher never takes in, for the reason given (`SkipRules`).
    case notTaken(String, reason: String)
    /// The worker no longer holds the job it had in hand (`JobStore.update`): it was cancelled, or taken by a request that
    /// does more, so nothing more of it is saved.
    case claimLost(Int64)
    /// What a job was queued with cannot be read, as a payload an earlier version wrote that this one cannot decode.
    case unreadablePayload(Int64, reason: String)
    /// Reading the file was given up on, and that reading has still not ended after this many seconds
    /// (`ingest.abandonedWorkSeconds`), as a parse that never ends: the file is not read again beside it.
    case workLeftRunning(seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .documentNotPersisted: "Document has not been saved yet"
        case let .documentNotFound(id): "Document \(id) does not exist"
        case let .sourceMissing(p): "File is gone: \(p)"
        case let .contentUnavailable(id): "Extracted content for document \(id) is unavailable"
        case let .analysisMissing(id): "What the model read of document \(id) is missing"
        case let .notInArchive(id): "Document \(id) is not in the archive; only a document in the archive can be confirmed"
        case let .notTrashed(path, reason): "Could not move \(path) to the Trash: \(reason)"
        case let .notTaken(path, reason): "\(path) is not taken in: \(reason)"
        case let .claimLost(id): "Job \(id) is no longer this worker's: it was cancelled or taken over"
        case let .unreadablePayload(id, reason): "What job \(id) was queued with cannot be read, so it is not worked on: \(reason)"
        case let .workLeftRunning(seconds):
            "Reading it was given up on and still had not ended after \(Int(seconds)) seconds (ingest.abandonedWorkSeconds), so it is not read again"
        case let .unusableFileName(name) where name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            "A document needs a name; it cannot be blank"
        case let .unusableFileName(name):
            "“\(name)” cannot be a document's name: nothing a file name may hold is left of it, or it is a name Arrumator keeps for its own files"
        }
    }
}
