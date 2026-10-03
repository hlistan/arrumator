import Foundation

/// What the Incoming watcher finds: a file that has stopped changing, to be queued, or one it has stopped waiting for
/// after `watcher.unopenableWaitSeconds`, and why.
public enum IncomingArrival: Sendable, Hashable {
    case stable(URL)
    case unopenable(URL, Unopenable)
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
    private var unopenable: [String: Sight] = [:]
    /// Who is sent what the watcher finds, each by a stream of its own (`arrivals()`).
    private var subscribers: [UUID: AsyncStream<IncomingArrival>.Continuation] = [:]

    /// What one look at a file finds, in one walk of it for a package: it is gone; it is there but cannot be weighed,
    /// as a package one of whose folders cannot be listed; it is a package of more items than may be listed; or it is
    /// as `FileFingerprint` says, and can be opened or not. Nothing it does can be held up: a file is opened without
    /// waiting (`O_NONBLOCK`), and what a package holds is not opened at all, its permissions are asked.
    private enum Sight: Equatable {
        case gone, unreadable
        case tooManyItems(limit: Int)
        case seen(FileFingerprint, opens: Bool)

        init(_ url: URL, packageItems limit: Int) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                self = FileManager.default.fileExists(atPath: url.path) ? .unreadable : .gone
                return
            }
            guard attrs[.type] as? FileAttributeType == .typeDirectory else {
                self = .seen(FileFingerprint(size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, modified: attrs[.modificationDate] as? Date,
                                             inode: (attrs[.systemFileNumber] as? NSNumber)?.int64Value),
                             opens: attrs[.type] as? FileAttributeType == .typeRegular && Self.opens(url))
                return
            }
            do {
                let survey = try Packages.survey(url, limit: limit)
                self = .seen(survey.fingerprint, opens: survey.isReadable)
            } catch let FileOperationError.tooManyItems(_, limit) {
                self = .tooManyItems(limit: limit)
            } catch {
                self = .unreadable
            }
        }

        /// Whether the regular file at `file` opens for reading, asked so it cannot wait, as on a pipe with no writer.
        private static func opens(_ file: URL) -> Bool {
            let descriptor = file.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) } ?? -1 }
            guard descriptor >= 0 else { return false }
            close(descriptor)
            return true
        }

        /// Its size, when it could be weighed.
        var size: Int64? {
            if case let .seen(fingerprint, _) = self { fingerprint.size } else { nil }
        }

        /// Why it is not waited for any longer, when it has not stopped being unopenable.
        var unopenable: Unopenable {
            if case let .tooManyItems(limit) = self { .tooManyItems(limit: limit) } else { .unreadable }
        }
    }

    private struct Candidate {
        var sight: Sight
        var stablePolls: Int
        var firstSeen: Date
        /// Since when it has been unchanged but could not be opened.
        var unopenableSince: Date?
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

    /// Watches `root`, made when it is not there, leaving out what is in `excluding` (the archive when it is kept inside
    /// Incoming), and takes in what is there already.
    public func start(root: URL, excluding: [URL]) throws {
        stop()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        let sight = Sight(url, packageItems: config.maxPackageItems)
        guard sight != .gone else {
            unopenable[url.path] = nil
            return
        }
        if let then = unopenable[url.path] {
            // Still as it was when it was left: nothing has happened to it.
            guard sight != then else { return }
            unopenable[url.path] = nil
        }
        candidates[url.path] = Candidate(sight: sight, stablePolls: 0, firstSeen: time.now())
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
    /// `watcher.maxPackageItems` items, is waited for `watcher.unopenableWaitSeconds`, and then left. What it sends, in
    /// the order sent.
    @discardableResult
    func poll() -> [IncomingArrival] {
        let now = time.now()
        var sent: [IncomingArrival] = []
        for (path, candidate) in candidates {
            let url = URL(fileURLWithPath: path)
            let sight = Sight(url, packageItems: config.maxPackageItems)
            guard sight != .gone else {
                candidates[path] = nil
                continue
            }
            var c = candidate
            if sight != c.sight {
                c.sight = sight
                c.stablePolls = 0
                c.unopenableSince = nil
            } else if case .seen(_, opens: true) = sight {
                c.stablePolls += 1
                c.unopenableSince = nil
            } else {
                c.stablePolls = 0
                c.unopenableSince = c.unopenableSince ?? now
            }
            let size = sight.size ?? 0
            let zeroByteWaitOver = sight.size == 0 && now.timeIntervalSince(c.firstSeen) >= config.zeroByteWaitSeconds
            if (size > 0 && c.stablePolls >= config.stabilityRequiredPolls) || zeroByteWaitOver {
                candidates[path] = nil
                Log.info(.watch, "File is stable", ["path": path, "size": String(size),
                                                    "waited": String(format: "%.1f", now.timeIntervalSince(c.firstSeen))])
                sent.append(.stable(url))
            } else if let since = c.unopenableSince, now.timeIntervalSince(since) >= config.unopenableWaitSeconds {
                candidates[path] = nil
                unopenable[path] = sight
                Log.warning(.watch, "File cannot be taken in; no longer waited for", ["path": path])
                sent.append(.unopenable(url, sight.unopenable))
            } else {
                candidates[path] = c
            }
        }
        for arrival in sent {
            for subscriber in subscribers.values { subscriber.yield(arrival) }
        }
        return sent
    }
}
