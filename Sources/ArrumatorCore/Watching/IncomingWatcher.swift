import Foundation

/// What the Incoming watcher finds: a file that has stopped changing, to be queued, or one it has stopped waiting for
/// after `watcher.unopenableWaitSeconds`, and why.
public enum IncomingArrival: Sendable, Hashable {
    case stable(URL)
    case unopenable(URL, Unopenable)
    /// It has not stopped changing in `watcher.stabilityMaxWaitSeconds`; it is waited for still.
    case stillChanging(URL)
}

/// Why the Incoming watcher stopped waiting for a file.
public enum Unopenable: Sendable, Hashable {
    /// It, or a file or folder in the package it is, cannot be read, as when its permissions keep the app out.
    case unreadable
    /// It is a package holding more items than `watcher.maxPackageItems`, the limit given here: too many for one
    /// document, as a photo library or an app is.
    case tooManyItems(limit: Int)
}

/// Watches the Incoming folder and emits files once they have stopped changing, at any depth: a folder that comes into
/// Incoming is looked through, as macOS reports a folder moved in whole, not what is in it. A package is one document
/// (`Packages`): a change to what it holds is the package changing, and it is emitted whole once nothing in it changes.
/// Nothing in a folder it is told to leave out, the archive when it is kept inside Incoming, is ever taken in.
public actor IncomingWatcher {
    private let config: WatcherConfig
    private let skip: SkipRules
    private let time: any TimeSource
    /// Incoming, spelled as the file system spells it (`URL.folderOnDisk`): links resolved and letters in their case on
    /// disk, as FSEvents reports the paths of what changes in it. Every path the watcher handles is spelled so.
    private var root: URL?
    /// The folders left out, spelled as `root` is, each with its closing separator.
    private var excluded: [String] = []
    private var stream: FSEventStream?
    private var pumpTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var candidates: [String: Candidate] = [:]
    /// The files the watcher stopped waiting for, as they could not be opened, each as it was seen then. One is taken
    /// up again once it can be opened or it changes; kept through a stop and a start, so a rescan does not wait for it
    /// and report it again.
    private var unopenable: [String: FileSight] = [:]
    /// Who is sent what the watcher finds, each by a stream of its own (`arrivals()`).
    private var subscribers: [UUID: AsyncStream<IncomingArrival>.Continuation] = [:]

    /// A file that came or changed, until it has stopped changing (`Settling`).
    private struct Candidate {
        var settling: Settling
    }

    public init(config: WatcherConfig, skip: SkipRules, time: any TimeSource) {
        self.config = config
        self.skip = skip
        self.time = time
    }

    /// Each file once it has stopped changing, and each it stopped waiting for, from now on, for as long as the caller
    /// listens, through every stop and start of the watcher. Every caller is given a stream of its own: a stream ends
    /// when the task listening to it is cancelled, as stopping the app cancels it, and one shared stream would then be
    /// ended for every later listener too. Everything is kept until it is read, as nothing may be missed.
    public func arrivals() -> AsyncStream<IncomingArrival> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<IncomingArrival>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// Watches `root`, leaving out what is in `excluding` (the archive when it is kept inside Incoming), and takes in what
    /// is there already. `root` is made when it is not there, but only in a folder that is: no folder above it is made,
    /// as one on a disk not connected, or the archive's folder while it is away when Incoming is kept inside it. Throws
    /// then, and the start is made again when the settings are next applied.
    public func start(root: URL, excluding: [URL]) throws {
        stop()
        var isFolder: ObjCBool = false
        if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        } else if !isFolder.boolValue {
            // A file where Incoming is to be: it can be neither made nor watched.
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: root.path])
        }
        let root = root.folderOnDisk
        self.root = root
        excluded = excluding.map { $0.folderOnDisk.path + "/" }
        guard let s = FSEventStream(paths: [root.path], since: nil, latency: config.fsEventsLatency), s.start() else {
            Log.error(.watch, "Could not start FSEvents for Incoming", ["path": root.path])
            return
        }
        stream = s
        pumpTask = Task { [weak self] in
            for await batch in s.events {
                await self?.handle(batch)
            }
        }
        rescan()
        Log.info(.watch, "Watching Incoming", ["path": root.path])
    }

    public func stop() {
        stream?.stop()
        stream = nil
        pumpTask?.cancel()
        pollTask?.cancel()
        pumpTask = nil
        pollTask = nil
        candidates.removeAll()
    }

    /// Full scan, used at start, after wake and when FSEvents reports dropped events.
    public func rescan() {
        guard let root else { return }
        Log.debug(.watch, "Rescanned Incoming", ["files": String(scan(root))])
    }

    /// Whether `path` is a folder left out, or in one.
    private func isExcluded(_ path: String) -> Bool {
        excluded.contains { (path + "/").hasPrefix($0) }
    }

    /// Considers every file and package in `directory`, at any depth, hidden files, what is inside packages and the
    /// folders left out aside; how many there were.
    @discardableResult
    private func scan(_ directory: URL) -> Int {
        guard !isExcluded(directory.path) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var found = 0
        for case let url as URL in enumerator {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true, isExcluded(url.path) {
                enumerator.skipDescendants()
                continue
            }
            guard v?.isRegularFile == true || v?.isPackage == true else { continue }
            consider(url)
            found += 1
        }
        return found
    }

    /// Takes in what a batch of FSEvents reports: each file that came or changed, the package that holds one when it is
    /// in a package, and everything in a folder that came, which macOS reports alone when a folder is moved in whole.
    /// FSEvents reports paths as the file system spells them, as `root` is spelled.
    func handle(_ batch: [FSEvent]) {
        guard let root else { return }
        if batch.contains(where: \.needsRescan) {
            Log.info(.watch, "FSEvents requested rescan", ["events": String(batch.count)])
            rescan()
            return
        }
        for event in batch where event.isFile || event.isRenamed || event.isCreated {
            let url = URL(fileURLWithPath: event.path)
            guard url.path.hasPrefix(root.path + "/"), !isExcluded(url.path) else { continue }
            Log.trace(.watch, "FSEvent", ["path": event.path, "flags": String(event.flags, radix: 16)])
            let document = Packages.document(holding: url, under: root)
            guard document.path == url.path else {
                consider(document)
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
            // What is in a folder the rules ignore, such as a hidden one, is skipped file by file (`consider`).
            if event.isDirectory, values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true {
                Log.debug(.watch, "Folder came into Incoming", ["path": url.path, "files": String(scan(url))])
            } else {
                consider(url)
            }
        }
    }

    private func consider(_ url: URL) {
        guard let root, !isExcluded(url.path) else { return }
        if let reason = skip.ignoreReason(url) {
            Log.trace(.watch, "Skipped", ["path": url.path, "reason": reason])
            return
        }
        if skip.isInsideIgnoredDirectory(url, root: root) { return }
        // One already watched is looked at by the next pass: an event for each file written into a package is no walk
        // of the package each.
        guard candidates[url.path] == nil else {
            schedulePolling()
            return
        }
        let sight = FileSight(url, packageItems: config.maxPackageItems)
        guard sight != .gone else {
            unopenable[url.path] = nil
            return
        }
        if let then = unopenable[url.path] {
            // Still as it was when it was left: nothing has happened to it.
            guard sight != then else { return }
            unopenable[url.path] = nil
        }
        candidates[url.path] = Candidate(settling: Settling(sight, at: time.now()))
        Log.debug(.watch, "Candidate", ["path": url.path, "size": sight.size.map(String.init) ?? "-"])
        schedulePolling()
    }

    private func schedulePolling() {
        guard pollTask == nil, !candidates.isEmpty else { return }
        let interval = config.stabilityPollInterval
        let time = time
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await time.sleep(seconds: interval) } catch { break }
                guard let self, await self.pollAndGoOn() else { break }
            }
        }
    }

    /// One stability pass, as the polling task makes it; whether anything is left to watch, which ends the task when
    /// nothing is, in the same step, so a file considered meanwhile starts a task of its own. A task stopped meanwhile
    /// (`stop()`) makes no pass and leaves `pollTask` alone, as it may be the task of a start since.
    private func pollAndGoOn() -> Bool {
        guard !Task.isCancelled else { return false }
        poll()
        guard candidates.isEmpty else { return true }
        pollTask = nil
        return false
    }

    /// One stability pass, one look at each candidate: a candidate unchanged since the last pass, and that can be
    /// opened, has stopped changing once unchanged for `watcher.stabilityRequiredPolls` passes, and one that changed
    /// starts counting again. One unchanged but that cannot be opened or weighed, or a package of more than
    /// `watcher.maxPackageItems` items, is waited for `watcher.unopenableWaitSeconds`, and then left. One still changing
    /// after `watcher.stabilityMaxWaitSeconds` is said to be once, and waited for still, looked at every
    /// `watcher.awayPollSeconds` from then on (`Settling.isDue`). What it sends, in the order sent.
    @discardableResult
    func poll() -> [IncomingArrival] {
        let now = time.now()
        var sent: [IncomingArrival] = []
        for (path, candidate) in candidates where candidate.settling.isDue(at: now, config: config) {
            let url = URL(fileURLWithPath: path)
            let sight = FileSight(url, packageItems: config.maxPackageItems)
            guard sight != .gone else {
                candidates[path] = nil
                continue
            }
            var c = candidate
            switch c.settling.poll(sight, now: now, config: config) {
            case .settled:
                candidates[path] = nil
                Log.info(.watch, "File is stable", ["path": path, "size": String(sight.size ?? 0),
                                                    "waited": String(format: "%.1f", now.timeIntervalSince(c.settling.firstSeen))])
                sent.append(.stable(url))
            case let .unopenable(why):
                candidates[path] = nil
                unopenable[path] = sight
                Log.warning(.watch, "File cannot be taken in; no longer waited for", ["path": path])
                sent.append(.unopenable(url, why))
            case .stillChanging:
                // Kept: this poll may have seen its last change, whose event is spent, and nothing else would take it up.
                candidates[path] = c
                Log.warning(.watch, "A file in Incoming has not stopped changing; it is waited for still", ["path": path])
                sent.append(.stillChanging(url))
            case .waiting:
                candidates[path] = c
            }
        }
        for arrival in sent {
            for subscriber in subscribers.values { subscriber.yield(arrival) }
        }
        return sent
    }
}
