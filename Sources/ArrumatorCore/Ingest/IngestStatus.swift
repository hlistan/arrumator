import Foundation

/// What the ingest worker is doing, as the app shows it (`IngestCoordinator.statusUpdates()`): live state, not a record.
public struct IngestStatus: Sendable, Hashable {
    /// The job the worker has in hand: which, its file, the stage it is at now and since when, the model that reads it,
    /// and the tags the file is given (`JobRecord.tags`), as the queue shows them.
    public struct Current: Sendable, Hashable {
        public var job: Int64
        public var path: String
        public var stage: JobState
        /// When the worker began the stage it is at, on the pipeline's clock: how long the stage has taken so far counts
        /// from here, the time the model takes to load before it reads the first file included.
        public var since: Date
        /// The chat model of the profile in the settings the worker took the job with, which reads the file while it is
        /// analysed (`DocumentAnalyzer`); nil when that profile names none.
        public var reader: String?
        public var tags: [DocumentLabel]

        public init(job: Int64, path: String, stage: JobState, since: Date, reader: String?, tags: [DocumentLabel] = []) {
            self.job = job
            self.path = path
            self.stage = stage
            self.since = since
            self.reader = reader
            self.tags = tags
        }

        /// What is being done to the file now: its stage, since when, and the model at the stage a model reads it at.
        public var work: JobWork { JobWork(stage: stage, model: stage == .analysing ? reader : nil, since: since) }
    }

    /// Files waiting to be filed, the one in hand among them.
    public var queued: Int
    /// Filed documents waiting to have their text read again, after the index was rebuilt from the archive.
    public var reindexing: Int
    /// Documents of the archive waiting to be read again with the rest of it (`PipelineServices.queueReadingAllAgain`),
    /// the one in hand among them.
    public var readingAgain: Int
    /// What the worker is working on now; nil while it works on nothing. Only this says a job is in hand: a job's stored
    /// stage says where it carries on, whether the worker has it now or it was stopped part way.
    public var current: Current?
    public var waitingForOllama: Bool
    public var powerPauseReason: String?
    /// Until when the files queued wait for Ollama, as the one that found it away is tried again then and no other is
    /// taken meanwhile (`IngestCoordinator.ollamaRetryAt`); nil while it is not known to be away, and while that file is
    /// tried again, in hand.
    public var retryAt: Date?

    public static let idle = IngestStatus(queued: 0, reindexing: 0, readingAgain: 0, current: nil, waitingForOllama: false,
                                          powerPauseReason: nil)

    /// Where `job` is, as this status says: in the worker's hands, or waiting, and how; nil for a job no longer in the
    /// queue, whatever a list read before says of it. One left while Ollama is known to be away waits for it until the
    /// one that found it away is tried again. The Incoming page shows this.
    public func progress(of job: JobRecord) -> JobProgress? {
        if let current, current.job == job.id { return current.stage.isActive ? .working(current.work) : nil }
        guard job.state.isActive else { return nil }
        if let error = job.lastError { return .retrying(error, at: job.nextRunAt) }
        if waitingForOllama, let retryAt { return .waitingForOllama(until: retryAt) }
        return job.state == .pending ? .waiting : .resuming(job.state)
    }
}

/// What the worker is doing to the file in hand (`IngestStatus.Current.work`): the stage, the model that works on it at
/// that stage, as the model reads it while it is analysed, and since when, so how long it takes shows as it goes, as a
/// search task's reading shows by which model and for how long (`SearchTaskQueueStatus.Reading`).
public struct JobWork: Sendable, Hashable {
    public var stage: JobState
    /// The model working on the file at this stage; nil at a stage no model of the profile works at.
    public var model: String?
    /// When the stage began, on the pipeline's clock.
    public var since: Date

    public init(stage: JobState, model: String?, since: Date) {
        self.stage = stage
        self.model = model
        self.since = since
    }
}

/// Where a job in the queue is (`IngestStatus.progress(of:)`).
public enum JobProgress: Sendable, Hashable {
    /// The worker has it in hand, doing this.
    case working(JobWork)
    /// A stage failed with this error; it is tried again from that stage once its time has come.
    case retrying(String, at: Date?)
    /// It was stopped part way at this stage, as when the app quit, and carries on from there when its turn comes.
    case resuming(JobState)
    /// It waits for its turn, not begun.
    case waiting
    /// It waits for Ollama, which another file found away, until that file is tried again.
    case waitingForOllama(until: Date)

    /// Whether the worker has it in hand now.
    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}
