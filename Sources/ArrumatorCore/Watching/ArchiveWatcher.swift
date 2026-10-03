import Foundation

/// Paths the app is about to change itself, so the archive watcher does not take its own changes for the user's. The first
/// event for an expected path is the app's change and uses the expectation up, so a change after it is the user's, even a
/// moment later; an expectation no event comes for is forgotten after `ttl` seconds.
public actor SelfChangeRegistry {
    private var expected: [String: Date] = [:]
    private let ttl: Double
    private let time: any TimeSource

    /// - Parameter ttl: how long an expectation waits for its event; must exceed the FSEvents latency.
    public init(ttl: Double, time: any TimeSource) {
        self.ttl = ttl
        self.time = time
    }

    public func expect(_ paths: [String]) {
        let until = time.now().addingTimeInterval(ttl)
        for p in paths { expected[Self.key(p)] = until }
    }

    /// Whether the event for `path` is the app's own change, which it then no longer expects.
    func consume(_ path: String) -> Bool {
        let now = time.now()
        expected = expected.filter { $0.value > now }
        return expected.removeValue(forKey: Self.key(path)) != nil
    }

    private static func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
}

public enum ArchiveChange: Sendable, Hashable {
    /// A file or a package is at `path` and has stopped changing: a document moved, renamed, put back or changed, a copy
    /// of one, or a file new to the archive. Which, `ArchiveReconciler` tells by the identifier on it.
    case found(path: String)
    /// What was at `path`, a file, a package or a folder, may be gone: each document recorded at it or inside it whose
    /// file is not there is missing. The archive's own path stands for every document, when events were lost.
    case gone(path: String)
    /// A record file (`_documents.md`, `_labels.md` or a history file) was changed by something other than the app,
    /// such as an edit by hand or a copy synchronised from another Mac, or events were lost; the index reads the
    /// record files that changed again.
    case recordsChanged
}

/// What the archive reports at once: changes in the order they are applied, where a document went before where it was,
/// so a move is followed rather than taken for a removal.
public struct ArchiveChanges: Sendable, Hashable {
    public var changes: [ArchiveChange]
    /// The last FSEvents event these changes, and those reported before them, account for: once they are applied
    /// (`ArchiveWatcher.applied(_:)`), the next start resumes after it. Nil before any event.
    public var through: UInt64?
}

/// Watches the archive and reports the changes the user makes in it, each once it is complete. FSEvents are hints
/// ([Apple, Using the File System Events API](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)),
/// so what an event names is looked at on disk, under the very name it gives (`FileOnDisk.isThere`): a file or package
/// that came or changed is reported once it has stopped changing (`Settling`), as one copied in is written for a while,
/// and a path that went is held as long; what came waits for what went, so a move, and a copy made with it, are reported
/// together, where things went before where they were. A folder that came is looked through, as macOS reports a folder
/// moved in whole and not what is in it; what is inside a package is the package (`Packages`); and when events
/// were lost, the folder they were lost in is looked at again, what the index has unchanged where it has it left out.
/// The archive's folder renamed, removed or gone with its disk is not there: nothing in it is taken for gone until it is
/// back, the same folder even on a volume mounted again (`FolderIdentity`), and then the whole archive is looked at again;
/// another folder made at its path is taken as the archive, which History says once. The watcher resumes after the last
/// event whose changes were
/// applied, across launches, so a change the app stops or crashes before applying is reported again. Looking at the disk
/// is done away from the actor, in chunks, and ends when the watcher stops.
public actor ArchiveWatcher {
    private let config: WatcherConfig
    private let skip: SkipRules
    private let registry: SelfChangeRegistry
    private let database: AppDatabase
    private let time: any TimeSource
    /// What is watched; nil until watching begins.
    private var scope: ArchiveScope?
    /// What the disk is asked; a test gives another (`use(_:)`).
    private var disk = ArchiveDisk.disk
    /// The archive's folder as the same folder across mounts: the one the index was kept for (`folderKey`), or the one
    /// there when watching began.
    private var rootIdentity: FolderIdentity?
    private var archiveIsThere = false
    /// How many folders are being looked through: while one is, nothing that went counts as gone, as what the look
    /// finds may be where it went.
    private var walking = 0
    /// Called before a folder is looked through: what a test does there, holding it as a large folder takes long, is
    /// what could happen then. Set by tests only.
    private var beforeWalking: (@Sendable (URL) async -> Void)?
    /// Changed by every start, stop and loss of the archive's folder, so work that awaited across one acts on nothing.
    private var generation = 0
    private var stream: FSEventStream?
    private var pumpTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Files and packages that came or changed, by path, until they have stopped changing.
    private var arriving: [String: Arriving] = [:]
    /// Paths that went, by path, held as long as one that came.
    private var leaving: [String: Leaving] = [:]
    /// What has stopped changing and what went long enough ago, by path, with the event that reported each, held until
    /// nothing that went still waits.
    private var settled: [String: UInt64] = [:]
    private var left: [String: UInt64] = [:]
    /// The last event handled, the last reported as accounted for, and the last saved as applied.
    private var lastEvent: UInt64?
    private var reportedThrough: UInt64?
    private var savedThrough: UInt64?
    /// Who is sent the changes, each by a stream of its own (`changes()`).
    private var subscribers: [UUID: AsyncStream<ArchiveChanges>.Continuation] = [:]
    static let lastEventKey = "archive_fsevents_last_id"
    static let deviceKey = "archive_fsevents_device"
    /// The archive's folder the index was kept for (`FolderIdentity.stored`), and the one before it, when another took
    /// its place, so that its coming back is told as such.
    static let folderKey = "archive_folder"
    static let earlierFolderKey = "archive_folder_earlier"
    /// The paths of the files still changing after `watcher.stabilityMaxWaitSeconds` (a JSON list), whose events no
    /// longer hold back the one saved (`accountedFor`): looked at again at the next start, so one whose last write came
    /// before a stop is taken in all the same.
    static let takingLongKey = "archive_taking_long"
    /// The paths last kept under `takingLongKey`.
    private var keptTakingLong: Set<String> = []
    /// Who is told whether the archive's folder is there, each by a stream of its own (`presence()`).
    private var presenceFollowers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    /// Looks, while the archive's folder is not there, every `watcher.awayPollSeconds`, whether it is back: FSEvents need
    /// not say so, as when a disk is attached again.
    private var lookoutTask: Task<Void, Never>?

    private struct Arriving {
        var settling: Settling
        /// The event that first reported it.
        let event: UInt64
    }

    private struct Leaving {
        var polls: Int
        /// The event that first reported it.
        let event: UInt64
    }

    public init(config: WatcherConfig, skip: SkipRules, registry: SelfChangeRegistry, database: AppDatabase, time: any TimeSource) {
        self.config = config
        self.skip = skip
        self.registry = registry
        self.database = database
        self.time = time
    }

    /// The changes the user makes in the archive, from now on, for as long as the caller listens, through every stop and
    /// start of the watcher. Every caller is given a stream of its own, as `IncomingWatcher.arrivals()` is, and every
    /// change is kept until it is read.
    public func changes() -> AsyncStream<ArchiveChanges> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ArchiveChanges>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// Each time the archive's folder goes or comes back, whether it is there, for as long as the stream is read: the
    /// runtime says the archive is away while it is not (`RuntimeWork.away`).
    public func presence() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        presenceFollowers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unfollow(id) } }
        return stream
    }

    private func unfollow(_ id: UUID) { presenceFollowers[id] = nil }

    private func setThere(_ there: Bool) {
        guard there != archiveIsThere else { return }
        archiveIsThere = there
        for follower in presenceFollowers.values { follower.yield(there) }
    }

    func use(_ disk: ArchiveDisk) {
        self.disk = disk
    }

    func setBeforeWalking(_ hook: (@Sendable (URL) async -> Void)?) {
        beforeWalking = hook
    }

    /// Watches the archive at `root`, resuming after the last event whose changes were applied. On a volume it has not
    /// watched before, it watches from now on, and saves that at once, so what comes from then on and is not applied
    /// before a stop is reported again at the next start. Another folder than the one the index was kept for, put in its
    /// place while the app did not run, is taken as the archive (`takeFolder`). What is saved is saved before the stream
    /// starts, so nothing that can fail comes between starting it and reading it.
    /// The archive is watched whole: Incoming is never inside it (`AppSettings.problems`).
    public func start(root: URL) async throws {
        stop()
        let root = root.standardizedFileURL
        let device = FSEventStream.deviceUUID(for: root.path)
        let storedDevice = try await database.meta(Self.deviceKey)
        let storedID = try await database.meta(Self.lastEventKey).flatMap(UInt64.init)
        let kept = try await database.meta(Self.folderKey).flatMap(FolderIdentity.init(stored:))
        let resumed = (device != nil && device == storedDevice) ? storedID : nil
        let since = resumed ?? FSEventStream.currentEventID()
        watch(root, since: since)
        if let device { try await database.setMeta(Self.deviceKey, device) }
        if resumed == nil { try await database.setMeta(Self.lastEventKey, String(since)) }
        if let kept {
            rootIdentity = kept
        } else if let rootIdentity {
            try await database.setMeta(Self.folderKey, rootIdentity.stored)
        }
        await takeUpTakingLong(event: since)
        var lookedAgain: [ArchiveChange] = []
        if let scope { lookedAgain = await takeFolder(scope, event: since, changed: false) ?? [] }
        guard let s = FSEventStream(paths: [root.path], since: since, latency: config.fsEventsLatency), s.start() else {
            Log.error(.watch, "Could not start FSEvents for the archive", ["path": root.path])
            return
        }
        stream = s
        pumpTask = Task { [weak self] in
            for await batch in s.events { await self?.handle(batch) }
        }
        if !lookedAgain.isEmpty { report(lookedAgain) }
        schedulePolling()
        Log.info(.watch, "Watching archive", ["path": root.path, "resume": resumed.map(String.init) ?? "now"])
    }

    /// Takes the events of the archive at `root` from now on, resuming after event `since`: what `start` does but for
    /// FSEvents itself, which tests leave out to give batches of their own.
    func watch(_ root: URL, since: UInt64?) {
        forget()
        let root = root.standardizedFileURL
        scope = ArchiveScope(root: root, rootOnDisk: root.folderOnDisk.path, skip: skip, config: config)
        rootIdentity = disk.identity(of: root)
        setThere(rootIdentity != nil)
        if rootIdentity == nil { lookOut() }
        (lastEvent, reportedThrough, savedThrough) = (since, since, since)
    }

    /// Stops watching. What still waits to be reported is let go: the next start resumes before it, as nothing it
    /// came with was applied.
    public func stop() {
        stream?.stop()
        stream = nil
        pumpTask?.cancel()
        pumpTask = nil
        forget()
    }

    /// Lets go of everything that waits, and of work under way.
    private func forget() {
        generation += 1
        walking = 0
        lookoutTask?.cancel()
        lookoutTask = nil
        pollTask?.cancel()
        pollTask = nil
        arriving.removeAll()
        leaving.removeAll()
        settled.removeAll()
        left.removeAll()
    }

    /// Remembers that `changes` were applied: the next start resumes after the last event they account for.
    public func applied(_ changes: ArchiveChanges) async {
        guard let through = changes.through, through > savedThrough ?? 0 else { return }
        do {
            try await database.setMeta(Self.lastEventKey, String(through))
            savedThrough = max(savedThrough ?? 0, through)
        } catch {
            Log.warning(.watch, "Could not persist FSEvents id", ["error": error.localizedDescription])
        }
    }

    // MARK: The archive's folder

    /// Looks at the archive's folder: nil when it is not there, as it is then let go until it is back (`lose`); nothing
    /// when it is the one watched, and was there. When it came back, the same folder even on a volume mounted again, or
    /// another folder came in its place, which is taken as the archive (`replaced(by:)`), the whole archive is looked at
    /// again, as what happened meanwhile was not seen, and what to report of that is returned. `changed`: an event said
    /// the folder changed.
    private func takeFolder(_ scope: ArchiveScope, event: UInt64, changed: Bool) async -> [ArchiveChange]? {
        guard let identity = disk.identity(of: scope.root) else {
            lose()
            return nil
        }
        let same = rootIdentity.map { $0 == identity } ?? true
        guard !same || !archiveIsThere || changed else { return [] }
        if same {
            rootIdentity = identity
        } else {
            await replaced(by: identity, scope: scope)
        }
        lookoutTask?.cancel()
        lookoutTask = nil
        setThere(true)
        Log.info(.watch, "Looking at the whole archive again, as its folder changed", ["path": scope.root.path])
        await rescan(scope.root, event: event)
        return [.recordsChanged]
    }

    /// Another folder is at the archive's path, made again there or put in its place, or the earlier one is back: it is
    /// the archive from now on. What the index holds of the one before may not be in it, which the look that follows
    /// finds. What its record files hold is merged with the index, never taken over it: that a merge is owed is kept in
    /// the index in the one write that names the folder (`ArchiveRecords.mergeOwedKey`), so a stop before the merged read
    /// still has it done at the next start. History says so once.
    private func replaced(by identity: FolderIdentity, scope: ArchiveScope) async {
        let before = rootIdentity
        rootIdentity = identity
        Log.warning(.watch, "Another folder is at the archive's path; it is taken as the archive", ["path": scope.root.path])
        do {
            let earlier = try await database.meta(Self.earlierFolderKey).flatMap(FolderIdentity.init(stored:))
            try await database.writer.write { db in
                try AppDatabase.setMeta(db, Self.folderKey, identity.stored)
                if let before { try AppDatabase.setMeta(db, Self.earlierFolderKey, before.stored) }
                try AppDatabase.setMeta(db, ArchiveRecords.mergeOwedKey, ArchiveRecords.mergeOwed)
            }
            let said = earlier == identity
                ? "The archive's earlier folder at \(scope.root.path) is back."
                : "The archive's folder at \(scope.root.path) is another folder than before. It is taken as the archive."
            try await HistoryStore(database: database, time: time).record(
                .error, summary: said + " Everything in it is looked at again, a document whose file is not in it is missing, and what its "
                    + "record files hold is merged with what was kept meanwhile.", payload: ["path": scope.root.path])
        } catch {
            Log.error(.watch, "Could not record that the archive's folder was replaced", ["error": error.localizedDescription])
        }
    }

    /// History says once that the file at `path` in the archive has not stopped changing in
    /// `watcher.stabilityMaxWaitSeconds`; it is waited for still.
    private func recordTakingLong(_ path: String) async {
        let minutes = Format.count(Int((config.stabilityMaxWaitSeconds / 60).rounded(.up)), "minute")
        do {
            try await HistoryStore(database: database, time: time).record(
                .error, summary: "\(URL(fileURLWithPath: path).lastPathComponent) in the archive has not stopped changing in \(minutes); "
                    + "it is taken once it stops", payload: ["path": path])
        } catch {
            Log.error(.watch, "Could not record that a file in the archive is still changing", ["error": error.localizedDescription])
        }
    }

    /// The archive's folder is not there: nothing in it is the archive's until it is back, and nothing that waited is
    /// reported, as none of it can be told now. Whether it is back is looked at from then on (`lookOut`).
    private func lose() {
        guard archiveIsThere, let scope else { return }
        forget()
        setThere(false)
        lookOut()
        Log.warning(.watch, "The archive's folder is not there; nothing in it is taken for gone until it is back", ["path": scope.root.path])
    }

    /// Looks every `watcher.awayPollSeconds` whether the archive's folder is back, and takes it when it is, as FSEvents
    /// need not say so.
    private func lookOut() {
        guard lookoutTask == nil else { return }
        let (interval, time) = (config.awayPollSeconds, time)
        lookoutTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await time.sleep(seconds: interval) } catch { return }
                guard let self, await self.takeFolderIfThere() else { return }
            }
        }
    }

    /// Takes the archive's folder if it is there now, as `handle` does; whether to go on looking.
    private func takeFolderIfThere() async -> Bool {
        guard !archiveIsThere, let scope, disk.identity(of: scope.root) != nil else { return !archiveIsThere }
        lookoutTask = nil
        await handle([])
        return false
    }

    // MARK: Events

    /// Takes in a batch of FSEvents. Each file or package that came or changed, and each path that went, waits to be
    /// reported until it is complete (`poll`); a record file changed is reported at once. Stopped part way, it accounts
    /// for none of the batch's events, which the next start reports again.
    func handle(_ batch: [FSEvent]) async {
        guard let scope else { return }
        let generation = self.generation
        let rootChanged = batch.first(where: \.isRootChanged)
        guard let lookedAgain = await takeFolder(scope, event: rootChanged?.id ?? batch.map(\.id).min() ?? lastEvent ?? 0,
                                                 changed: rootChanged != nil) else { return }
        var recordsChanged = !lookedAgain.isEmpty
        var seen = Set<String>()
        for event in batch where !event.isRootChanged && !event.isHistoryDone {
            guard generation == self.generation, !Task.isCancelled else { return }
            if await take(event, scope: scope, seen: &seen, generation: generation) { recordsChanged = true }
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        if let last = batch.map(\.id).max() { lastEvent = max(lastEvent ?? 0, last) }
        report(recordsChanged ? [.recordsChanged] : [])
        schedulePolling()
    }

    /// Takes in what `event` names, once a batch (`seen`); whether that is a record file changed, or a folder holding one.
    private func take(_ event: FSEvent, scope: ArchiveScope, seen: inout Set<String>, generation: Int) async -> Bool {
        if event.needsRescan {
            Log.info(.watch, "Archive FSEvents lost events; looking at the folder again", ["flags": String(event.flags, radix: 16)])
            await rescan(event.lostEverywhere ? scope.root : scope.folder(lostIn: event.path), event: event.id)
            return true
        }
        guard let path = scope.path(of: event.path) else { return false }
        let url = Packages.document(holding: URL(fileURLWithPath: path), under: scope.root)
        guard seen.insert(url.path).inserted else { return false }
        if await registry.consume(url.path) { return false }
        guard generation == self.generation else { return false }
        if scope.isRecordFile(url.lastPathComponent) { return true }
        if skip.isInsideIgnoredDirectory(url, root: scope.root) { return false }
        // Gone, or there only under another name, as the old name of a rename that changed only case: it went, unless the
        // rules would never have taken it in. The disk tells nothing of a name that went, so one that still finds a file
        // under another name went whatever that file is.
        guard scope.isThere(url) else {
            if FileManager.default.fileExists(atPath: url.path) || skip.ignoreReason(url) == nil { leave(url.path, event: event.id) }
            return false
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        if values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true {
            // A folder that came, renamed, moved or copied in whole: macOS reports it, not what is in it.
            guard event.isCreated || event.isRenamed, !skip.isIgnoredDirectory(named: url.lastPathComponent) else { return false }
            return await lookThrough(url, event: event.id)
        }
        if skip.ignoreReason(url) == nil { arrive(url.path, event: event.id) }
        return false
    }

    /// Looks at `folder` again, as what happened in it was not seen: everything in it, and each document recorded in it,
    /// whose file is looked for (`ArchiveChange.gone`).
    private func rescan(_ folder: URL, event: UInt64) async {
        leave(folder.path, event: event)
        await lookThrough(folder, event: event)
    }

    /// Takes in everything in `folder`, at any depth, as it takes in what an event names, leaving out what the walk of
    /// the archive leaves out (`ArchiveRecords.walk`) and what the index has unchanged where it has it. Whether it holds a
    /// record file.
    @discardableResult
    private func lookThrough(_ folder: URL, event: UInt64) async -> Bool {
        guard let scope else { return false }
        let generation = self.generation
        walking += 1
        defer { if generation == self.generation { walking -= 1 } }
        await beforeWalking?(folder)
        guard generation == self.generation else { return false }
        let recorded: [String: Int64]
        do {
            recorded = try await DocumentStore(database: database, time: time).recordedInodes(atOrInside: folder.path)
        } catch is CancellationError {
            return false
        } catch {
            // Not known: everything in the folder waits until it has stopped changing, as anything new does.
            Log.warning(.watch, "Could not read what the index has in a folder of the archive", ["path": folder.path, "error": error.localizedDescription])
            recorded = [:]
        }
        guard let walked = await Self.walk(folder, scope: scope, recorded: recorded), generation == self.generation else { return false }
        let now = time.now()
        for (path, sight) in walked.files where arriving[path] == nil {
            arriving[path] = Arriving(settling: Settling(sight, at: now), event: event)
        }
        Log.debug(.watch, "Looked through a folder of the archive", ["path": folder.path, "files": String(walked.files.count)])
        return walked.holdsRecords
    }

    /// Takes up again the files kept as still changing (`takingLongKey`) when the watcher last ran: each still in the
    /// archive waits again, said to be taking long already, as event `event` reported it.
    private func takeUpTakingLong(event: UInt64) async {
        guard let scope else { return }
        do {
            let kept = try await database.meta(Self.takingLongKey).map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            let now = time.now()
            for path in kept where arriving[path] == nil && scope.path(of: path) == path {
                let sight = FileSight(URL(fileURLWithPath: path), packageItems: config.maxPackageItems)
                guard sight != .gone else { continue }
                arriving[path] = Arriving(settling: Settling(sight, at: now, takingLong: true), event: event)
            }
            keptTakingLong = Set(kept)
            await keepTakingLong()
        } catch {
            Log.error(.watch, "Could not read the files of the archive still changing when it was last watched", ["error": error.localizedDescription])
        }
    }

    /// Keeps the paths of the files still changing after the longest wait (`takingLongKey`), when they changed.
    private func keepTakingLong() async {
        let now = Set(arriving.filter(\.value.settling.isTakingLong).keys)
        guard now != keptTakingLong else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let list = String(decoding: try encoder.encode(now.sorted()), as: UTF8.self)
            try await database.writer.write { db in try AppDatabase.setMeta(db, Self.takingLongKey, now.isEmpty ? nil : list) }
            keptTakingLong = now
        } catch {
            Log.error(.watch, "Could not keep the files of the archive still changing", ["error": error.localizedDescription])
        }
    }

    /// `path` came or changed: it waits until it has stopped changing.
    private func arrive(_ path: String, event: UInt64) {
        guard arriving[path] == nil else { return }
        let sight = FileSight(URL(fileURLWithPath: path), packageItems: config.maxPackageItems)
        // Gone already: the event that took it says so.
        guard sight != .gone else { return }
        arriving[path] = Arriving(settling: Settling(sight, at: time.now()), event: event)
        Log.debug(.watch, "Archive candidate", ["path": path, "size": sight.size.map(String.init) ?? "-"])
    }

    /// `path` went: it waits as long as what came with it, and again as long for what came later.
    private func leave(_ path: String, event: UInt64) {
        leaving[path] = Leaving(polls: 0, event: leaving[path]?.event ?? event)
    }

    // MARK: Waiting until complete

    private func schedulePolling() {
        guard pollTask == nil, isWaiting else { return }
        let interval = config.stabilityPollInterval
        let time = time
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await time.sleep(seconds: interval) } catch { break }
                guard let self, await self.poll() else { break }
            }
        }
    }

    private var isWaiting: Bool { !arriving.isEmpty || !leaving.isEmpty || !settled.isEmpty || !left.isEmpty }

    /// One pass over what waits. Each file or package that has stopped changing, and each path that went as long ago, is
    /// reported once nothing that went still waits, where things went before where they were. Whether anything is left
    /// to wait for; false also when its task is cancelled, as stopping does, which ends it before it counts a poll.
    @discardableResult
    func poll() async -> Bool {
        guard let scope, archiveIsThere else { return false }
        let generation = self.generation
        guard let lookedAgain = await takeFolder(scope, event: lastEvent ?? 0, changed: false), generation == self.generation else { return false }
        if !lookedAgain.isEmpty { report(lookedAgain) }
        // While a folder is looked through, nothing that went counts: what the look finds may be where it went.
        let counted = walking == 0 ? Array(leaving.keys) : []
        // One taking long is looked at every watcher.awayPollSeconds (`Settling.isDue`).
        let due = time.now()
        let looked = arriving.filter { $0.value.settling.isDue(at: due, config: config) }.keys
        guard let measured = await Self.measure(Array(looked), scope: scope), generation == self.generation else { return false }
        let now = time.now()
        for (path, sight) in measured {
            guard var candidate = arriving[path] else { continue }
            // Gone, or renamed, before it stopped changing: the event that took it says so.
            guard sight != .gone else {
                arriving[path] = nil
                continue
            }
            switch candidate.settling.poll(sight, now: now, config: config) {
            case .waiting:
                arriving[path] = candidate
            case .settled:
                arriving[path] = nil
                settled[path] = candidate.event
            case .unopenable:
                // Unreadable, or a package of more than watcher.maxPackageItems items: no document of the archive.
                arriving[path] = nil
                Log.warning(.watch, "A file in the archive cannot be taken in; it is looked at again when it next changes", ["path": path])
            case .stillChanging:
                // Kept: this poll may have seen its last change, whose event is spent. It no longer holds back the event
                // saved as accounted for (`accountedFor`), so a file an app keeps open does not hold it for ever.
                arriving[path] = candidate
                Log.warning(.watch, "A file in the archive has not stopped changing; it is waited for still",
                            ["path": path, "waited": String(format: "%.0f", now.timeIntervalSince(candidate.settling.firstSeen))])
                await recordTakingLong(path)
            }
        }
        await keepTakingLong()
        guard generation == self.generation else { return false }
        for path in counted {
            guard var candidate = leaving[path] else { continue }
            candidate.polls += 1
            if candidate.polls >= config.stabilityRequiredPolls {
                leaving[path] = nil
                left[path] = candidate.event
            } else {
                leaving[path] = candidate
            }
        }
        // What came waits for what went: a copy, and a move of its original made meanwhile, are reported together, so the
        // original is told from its copy (`ArchiveReconciler`).
        var changes: [ArchiveChange] = []
        if leaving.isEmpty {
            changes = settled.keys.sorted().map { .found(path: $0) } + left.keys.sorted().map { .gone(path: $0) }
            settled.removeAll()
            left.removeAll()
        }
        report(changes)
        guard !isWaiting else { return true }
        pollTask?.cancel()
        pollTask = nil
        return false
    }

    // MARK: Reporting

    /// Sends `changes` to every subscriber, with the last event they, and what was sent before, account for: the event
    /// before the first of those whose changes still wait, or the last handled when none waits. Nothing is sent when
    /// there is no change and no event newly accounted for.
    private func report(_ changes: [ArchiveChange]) {
        let through = accountedFor
        guard !changes.isEmpty || (through ?? 0) > (reportedThrough ?? 0) else { return }
        if let through { reportedThrough = max(reportedThrough ?? 0, through) }
        if !changes.isEmpty { Log.debug(.watch, "Archive changes", ["count": String(changes.count)]) }
        let reported = ArchiveChanges(changes: changes, through: through)
        for subscriber in subscribers.values { subscriber.yield(reported) }
    }

    private var accountedFor: UInt64? {
        let waiting = arriving.values.filter { !$0.settling.isTakingLong }.map(\.event) + leaving.values.map(\.event)
            + Array(settled.values) + Array(left.values)
        guard let first = waiting.min() else { return lastEvent }
        return first > 0 ? first - 1 : nil
    }
}
