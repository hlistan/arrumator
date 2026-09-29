import Foundation

/// Paths the app is about to change itself, so archive events for them are not mistaken for user actions.
public actor SelfChangeRegistry {
    private var expected: [String: Date] = [:]
    private let ttl: Double

    /// - Parameter ttl: how long an expectation stays valid; must exceed the FSEvents latency.
    public init(ttl: Double) { self.ttl = ttl }

    public func expect(_ paths: [String]) {
        let until = Date().addingTimeInterval(ttl)
        for p in paths { expected[URL(fileURLWithPath: p).standardizedFileURL.path] = until }
    }

    public func isExpected(_ path: String) -> Bool {
        let now = Date()
        expected = expected.filter { $0.value > now }
        return expected[URL(fileURLWithPath: path).standardizedFileURL.path] != nil
    }
}

public enum ArchiveChange: Sendable, Hashable {
    /// A tracked document now lives at another path (moved or renamed by the user).
    case documentMoved(uid: String, newPath: String)
    /// A tracked document's path no longer exists.
    case documentMissing(path: String)
    /// A file the app does not know appeared inside a folder.
    case untrackedFile(path: String)
    /// Folders or `_about.md` changed; the taxonomy must be re-synced.
    case taxonomyChanged
    /// A record file (`_documents.md`, or a learned, logic or history file) was changed by something other than the
    /// app, such as an edit by hand or a copy synchronised from another Mac; the index reads it again.
    case recordsChanged
}

/// Watches the archive root and reports user-driven changes. Resumes from the last FSEvents id across launches.
public actor ArchiveWatcher {
    private let config: WatcherConfig
    private let taxonomyConfig: TaxonomyConfig
    private let skip: SkipRules
    private let registry: SelfChangeRegistry
    private let database: AppDatabase
    private var root: URL?
    private var excluded: [String] = []
    private var stream: FSEventStream?
    private var pumpTask: Task<Void, Never>?
    private let output: AsyncStream<[ArchiveChange]>.Continuation
    public nonisolated let changes: AsyncStream<[ArchiveChange]>
    static let lastEventKey = "archive_fsevents_last_id"
    static let deviceKey = "archive_fsevents_device"

    public init(config: WatcherConfig, taxonomy: TaxonomyConfig, skip: SkipRules, registry: SelfChangeRegistry,
                database: AppDatabase) {
        self.config = config
        taxonomyConfig = taxonomy
        self.skip = skip
        self.registry = registry
        self.database = database
        (changes, output) = AsyncStream<[ArchiveChange]>.makeStream(bufferingPolicy: .unbounded)
    }

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
        if since == nil { output.yield([.taxonomyChanged]) }
        Log.info(.watch, "Watching archive", ["path": root.path, "resume": since.map(String.init) ?? "now"])
    }

    public func stop() {
        stream?.stop()
        stream = nil
        pumpTask?.cancel()
        pumpTask = nil
    }

    private func handle(_ batch: [FSEvent]) async {
        guard let root else { return }
        var result: [ArchiveChange] = []
        var taxonomyChanged = false
        var recordsChanged = false
        var missing: [String] = []
        var seenPaths = Set<String>()
        for event in batch {
            if event.needsRescan {
                Log.info(.watch, "Archive FSEvents requested rescan", ["flags": String(event.flags, radix: 16)])
                taxonomyChanged = true
                continue
            }
            if event.isHistoryDone { continue }
            let path = URL(fileURLWithPath: event.path).standardizedFileURL.path
            guard path.hasPrefix(root.path + "/"), !excluded.contains(where: { path.hasPrefix($0) }) else { continue }
            guard seenPaths.insert(path).inserted else { continue }
            if await registry.isExpected(path) { continue }
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            if event.isDirectory || name == taxonomyConfig.aboutFileName {
                taxonomyChanged = true
                continue
            }
            if isRecordFile(name) {
                recordsChanged = true
                continue
            }
            if name == taxonomyConfig.indexFileName || (skip.ignoreReason(url) != nil && FileManager.default.fileExists(atPath: path)) {
                continue
            }
            if FileManager.default.fileExists(atPath: path) {
                if let uid = Xattr.get(Xattr.documentID, from: url) {
                    result.append(.documentMoved(uid: uid, newPath: path))
                } else if isInsideFolder(url, root: root) {
                    result.append(.untrackedFile(path: path))
                }
            } else if event.isFile {
                missing.append(path)
            }
        }
        result += missing.map { .documentMissing(path: $0) }
        if taxonomyChanged { result.append(.taxonomyChanged) }
        if recordsChanged { result.append(.recordsChanged) }
        if let last = batch.map(\.id).max() {
            do { try await database.setMeta(Self.lastEventKey, String(last)) } catch {
                Log.warning(.watch, "Could not persist FSEvents id", ["error": error.localizedDescription])
            }
        }
        if !result.isEmpty {
            Log.debug(.watch, "Archive changes", ["count": String(result.count)])
            output.yield(result)
        }
    }

    /// The app's own Markdown other than folder descriptions and the archive index: the record files.
    private func isRecordFile(_ name: String) -> Bool {
        name.hasPrefix(config.managedFilePrefix) && name.hasSuffix("." + config.managedFileExtension)
            && name != taxonomyConfig.aboutFileName && name != taxonomyConfig.indexFileName
    }

    /// Inside some folder of the archive rather than loose at its top; which folder, the reconciler decides.
    private func isInsideFolder(_ url: URL, root: URL) -> Bool {
        url.pathComponents.count - root.pathComponents.count >= 2
    }
}
