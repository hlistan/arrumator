import Foundation

/// What the ingest worker is doing, as the app shows it (`IngestCoordinator.statusUpdates()`): live state, not a record.
public struct IngestStatus: Sendable, Hashable {
    /// The job the worker has in hand: which, its file, the stage it is at now, and the tags the file is given
    /// (`JobRecord.tags`), as the queue shows them.
    public struct Current: Sendable, Hashable {
        public var job: Int64
        public var path: String
        public var stage: JobState
        public var tags: [DocumentLabel]

        public init(job: Int64, path: String, stage: JobState, tags: [DocumentLabel] = []) {
            self.job = job
            self.path = path
            self.stage = stage
            self.tags = tags
        }
    }

    /// Files waiting to be filed, the one in hand among them.
    public var queued: Int
    /// Filed documents waiting to have their text read again, after the index was rebuilt from the archive.
    public var reindexing: Int
    /// What the worker is working on now; nil while it works on nothing. Only this says a job is in hand: a job's stored
    /// stage says where it carries on, whether the worker has it now or it was stopped part way.
    public var current: Current?
    public var waitingForOllama: Bool
    public var powerPauseReason: String?

    public static let idle = IngestStatus(queued: 0, reindexing: 0, current: nil, waitingForOllama: false, powerPauseReason: nil)

    /// Where `job` is, as this status says: in the worker's hands, or waiting, and how; nil for a job no longer in the
    /// queue, whatever a list read before says of it. The Incoming page shows this.
    public func progress(of job: JobRecord) -> JobProgress? {
        if let current, current.job == job.id { return current.stage.isActive ? .working(current.stage) : nil }
        guard job.state.isActive else { return nil }
        if let error = job.lastError { return .retrying(error, at: job.nextRunAt) }
        return job.state == .pending ? .waiting : .resuming(job.state)
    }
}

/// Where a job in the queue is (`IngestStatus.progress(of:)`).
public enum JobProgress: Sendable, Hashable {
    /// The worker has it in hand, at this stage.
    case working(JobState)
    /// A stage failed with this error; it is tried again from that stage once its time has come.
    case retrying(String, at: Date?)
    /// It was stopped part way at this stage, as when the app quit, and carries on from there when its turn comes.
    case resuming(JobState)
    /// It waits for its turn, not begun.
    case waiting

    /// Whether the worker has it in hand now.
    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}
