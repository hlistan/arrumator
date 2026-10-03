import Foundation

/// Paths the app is about to change itself, so archive events for them are not mistaken for user actions.
public actor SelfChangeRegistry {
    private var expected: [String: Date] = [:]
    private let ttl: Double
    private let time: any TimeSource

    /// - Parameter ttl: how long an expectation stays valid; must exceed the FSEvents latency.
    public init(ttl: Double, time: any TimeSource) {
        self.ttl = ttl
        self.time = time
    }

    public func expect(_ paths: [String]) {
        let until = time.now().addingTimeInterval(ttl)
        for p in paths { expected[URL(fileURLWithPath: p).standardizedFileURL.path] = until }
    }

    public func isExpected(_ path: String) -> Bool {
        let now = time.now()
        expected = expected.filter { $0.value > now }
        return expected[URL(fileURLWithPath: path).standardizedFileURL.path] != nil
    }
}

public enum ArchiveChange: Sendable, Hashable {
    /// A tracked document now lives at another path (moved or renamed by the user).
    case documentMoved(uid: String, newPath: String)
    /// A tracked document's path no longer exists.
    case documentMissing(path: String)
    /// A file the app does not know appeared in the archive, outside its system folder.
    case untrackedFile(path: String)
    /// A record file (`_documents.md`, `_labels.md` or a history file) was changed by something other than the app,
    /// such as an edit by hand or a copy synchronised from another Mac, or events were lost; the index reads the
    /// record files that changed again.
    case recordsChanged
}

/// Watches the archive root and reports user-driven changes. Resumes from the last FSEvents id across launches.
public actor ArchiveWatcher {
    private let config: WatcherConfig
    private let records: RecordsConfig
    private let skip: SkipRules
    private let registry: SelfChangeRegistry
    private let database: AppDatabase
    private var root: URL?
    private var excluded: [String] = []
    private var stream: FSEventStream?
    private var pumpTask: Task<Void, Never>?
    /// Who is sent the changes, each by a stream of its own (`changes()`).
    private var subscribers: [UUID: AsyncStream<[ArchiveChange]>.Continuation] = [:]
    static let lastEventKey = "archive_fsevents_last_id"
    static let deviceKey = "archive_fsevents_device"

    public init(config: WatcherConfig, records: RecordsConfig, skip: SkipRules, registry: SelfChangeRegistry,
                database: AppDatabase) {
        self.config = config
        self.records = records
        self.skip = skip
        self.registry = registry
        self.database = database
    }

    /// The changes the user makes in the archive, from now on, for as long as the caller listens, through every stop and
    /// start of the watcher. Every caller is given a stream of its own, as `IncomingWatcher.arrivals()` is, and every
    /// change is kept until it is read.
    public func changes() -> AsyncStream<[ArchiveChange]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[ArchiveChange]>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// - Parameter excluding: subtrees handled elsewhere (the Incoming folder when it lives inside the archive).
    public func start(root: URL, excluding: [URL]) async throws {
        stop()
        let root = root.standardizedFileURL
        self.root = root
        excluded = excluding.map { $0.standardizedFileURL.path + "/" }
        let device = FSEventStream.deviceUUID(for: root.path)
        let storedDevice = try await database.meta(Self.deviceKey)
        let storedID = try await database.meta(Self.lastEventKey).flatMap(UInt64.init)
        let since = (device != nil && device == storedDevice) ? storedID : nil
        guard let s = FSEventStream(paths: [root.path], since: since, latency: config.fsEventsLatency), s.start() else {
            Log.error(.watch, "Could not start FSEvents for the archive", ["path": root.path])
            return
        }
        stream = s
        if let device { try await database.setMeta(Self.deviceKey, device) }
        pumpTask = Task { [weak self] in
            for await batch in s.events { await self?.handle(batch) }
        }
        Log.info(.watch, "Watching archive", ["path": root.path, "resume": since.map(String.init) ?? "now"])
    }

    public func stop() {
        stream?.stop()
        stream = nil
        pumpTask?.cancel()
        pumpTask = nil
    }

    func handle(_ batch: [FSEvent]) async {
        guard let root else { return }
        var result: [ArchiveChange] = []
        var recordsChanged = false
        let layout = ArchiveLayout(root: root, records: records, watcher: config)
        var missing: [String] = []
        var seenPaths = Set<String>()
        for event in batch {
            if event.needsRescan {
                Log.info(.watch, "Archive FSEvents requested rescan", ["flags": String(event.flags, radix: 16)])
                recordsChanged = true
                continue
            }
            if event.isHistoryDone { continue }
            let path = URL(fileURLWithPath: event.path).standardizedFileURL.path
            guard path.hasPrefix(root.path + "/"), !excluded.contains(where: { path.hasPrefix($0) }) else { continue }
            guard seenPaths.insert(path).inserted else { continue }
            if await registry.isExpected(path) { continue }
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            if event.isDirectory { continue }
            if isRecordFile(name) {
                recordsChanged = true
                continue
            }
            if skip.ignoreReason(url) != nil && FileManager.default.fileExists(atPath: path) { continue }
            if FileManager.default.fileExists(atPath: path) {
                if let uid = Xattr.get(Xattr.documentID, from: url) {
                    result.append(.documentMoved(uid: uid, newPath: path))
                } else if !layout.isSystem(url) {
                    result.append(.untrackedFile(path: path))
                }
            } else if event.isFile {
                missing.append(path)
            }
        }
        result += missing.map { .documentMissing(path: $0) }
        if recordsChanged { result.append(.recordsChanged) }
        if let last = batch.map(\.id).max() {
            do { try await database.setMeta(Self.lastEventKey, String(last)) } catch {
                Log.warning(.watch, "Could not persist FSEvents id", ["error": error.localizedDescription])
            }
        }
        if !result.isEmpty {
            Log.debug(.watch, "Archive changes", ["count": String(result.count)])
            for subscriber in subscribers.values { subscriber.yield(result) }
        }
    }

    /// The app's own Markdown: the record files.
    private func isRecordFile(_ name: String) -> Bool {
        name.hasPrefix(config.managedFilePrefix) && name.hasSuffix("." + config.managedFileExtension)
    }
}
