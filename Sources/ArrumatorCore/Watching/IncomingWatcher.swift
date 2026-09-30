import Foundation

/// Watches the Incoming folder and emits files once they have stopped changing.
public actor IncomingWatcher {
    private let config: WatcherConfig
    private let skip: SkipRules
    private let time: any TimeSource
    private var root: URL?
    private var stream: FSEventStream?
    private var pumpTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var candidates: [String: Candidate] = [:]
    private let output: AsyncStream<URL>.Continuation
    public nonisolated let stableFiles: AsyncStream<URL>

    private struct Candidate {
        var fingerprint: FileFingerprint
        var stablePolls: Int
        var firstSeen: Date
    }

    public init(config: WatcherConfig, skip: SkipRules, time: any TimeSource) {
        self.config = config
        self.skip = skip
        self.time = time
        (stableFiles, output) = AsyncStream<URL>.makeStream(bufferingPolicy: .unbounded)
    }

    public func start(root: URL) throws {
        stop()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.standardizedFileURL
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
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var found = 0
        for case let url as URL in enumerator {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true || v?.isPackage == true else { continue }
            consider(url)
            found += 1
        }
        Log.debug(.watch, "Rescanned Incoming", ["files": String(found)])
    }

    private func handle(_ batch: [FSEvent]) {
        guard let root else { return }
        if batch.contains(where: \.needsRescan) {
            Log.info(.watch, "FSEvents requested rescan", ["events": String(batch.count)])
            rescan()
            return
        }
        for event in batch where event.isFile || event.isRenamed || event.isCreated {
            let url = URL(fileURLWithPath: event.path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { continue }
            Log.trace(.watch, "FSEvent", ["path": event.path, "flags": String(event.flags, radix: 16)])
            consider(url)
        }
    }

    private func consider(_ url: URL) {
        guard let root else { return }
        if let reason = skip.ignoreReason(url) {
            Log.trace(.watch, "Skipped", ["path": url.path, "reason": reason])
            return
        }
        if skip.isInsideIgnoredDirectory(url, root: root) { return }
        guard let fp = try? FileFingerprint.of(url) else {
            candidates[url.path] = nil
            return
        }
        if candidates[url.path] == nil {
            candidates[url.path] = Candidate(fingerprint: fp, stablePolls: 0, firstSeen: time.now())
            Log.debug(.watch, "Candidate", ["path": url.path, "size": String(fp.size)])
        }
        schedulePolling()
    }

    private func schedulePolling() {
        guard pollTask == nil, !candidates.isEmpty else { return }
        let interval = config.stabilityPollInterval
        let time = time
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await time.sleep(seconds: interval) } catch { break }
                guard let self, await self.poll() else { break }
            }
        }
    }

    /// One stability pass. Returns false when nothing is left to watch.
    private func poll() -> Bool {
        let now = time.now()
        for (path, candidate) in candidates {
            let url = URL(fileURLWithPath: path)
            guard let fp = try? FileFingerprint.of(url) else {
                candidates[path] = nil
                continue
            }
            var c = candidate
            if fp == c.fingerprint, canOpen(url) {
                c.stablePolls += 1
            } else {
                c.fingerprint = fp
                c.stablePolls = 0
            }
            let zeroByteWaitOver = fp.size == 0 && now.timeIntervalSince(c.firstSeen) >= config.zeroByteWaitSeconds
            if (fp.size > 0 && c.stablePolls >= config.stabilityRequiredPolls) || zeroByteWaitOver {
                candidates[path] = nil
                Log.info(.watch, "File is stable", ["path": path, "size": String(fp.size),
                                                    "waited": String(format: "%.1f", now.timeIntervalSince(c.firstSeen))])
                output.yield(url)
            } else {
                candidates[path] = c
            }
        }
        if candidates.isEmpty {
            pollTask = nil
            return false
        }
        return true
    }

    private func canOpen(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }
}
