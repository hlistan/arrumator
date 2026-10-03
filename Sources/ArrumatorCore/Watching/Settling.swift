import Foundation

/// What one look at a file finds, in one walk of it for a package: it is gone; it is there but cannot be weighed,
/// as a package one of whose folders cannot be listed; it is a package of more items than may be listed; or it is
/// as `FileFingerprint` says, and can be opened or not. Nothing it does can be held up: a file is opened without
/// waiting (`O_NONBLOCK`), and what a package holds is not opened at all, its permissions are asked.
enum FileSight: Sendable, Equatable {
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
        } catch is CancellationError {
            // Stopped part way: what is not known is not taken for changed; whoever looks sees the stop.
            self = .unreadable
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

/// Whether a document that came or changed, in Incoming or in the archive, has stopped changing, as it must have before it
/// is read: unchanged, and readable, for `watcher.stabilityRequiredPolls` polls in a row, `watcher.stabilityPollInterval`
/// seconds apart, and an empty one, which may still be written, once `watcher.zeroByteWaitSeconds` have passed since it
/// was first seen. One unchanged but not readable for `watcher.unopenableWaitSeconds`, or a package of more items than
/// `watcher.maxPackageItems`, is let go as unopenable, and waited for again when it next changes. One still changing
/// after `watcher.stabilityMaxWaitSeconds`, such as a file copied slowly or a library an app keeps open, is said once to
/// be taking long, and never let go: the poll that finds that may be the one that saw its last change, whose event is
/// spent, and no other would take it up. From then on it is looked at every `watcher.awayPollSeconds` rather than at
/// every poll (`isDue`), as one that never stops, such as a large package an app keeps open, would be surveyed for ever.
struct Settling: Sendable {
    /// What one poll found.
    enum Outcome: Sendable, Equatable {
        case waiting
        /// It has stopped changing.
        case settled
        /// It has not changed for `watcher.unopenableWaitSeconds`, and cannot be opened, or is too large a package.
        case unopenable(Unopenable)
        /// It has not stopped changing in `watcher.stabilityMaxWaitSeconds`: said once, and it is waited for still.
        case stillChanging
    }

    private(set) var sight: FileSight
    private var unchangedPolls = 0
    let firstSeen: Date
    /// Since when it has been unchanged but could not be opened.
    private var unopenableSince: Date?
    /// Whether it was said to be taking long (`Outcome.stillChanging`), which is said once.
    private(set) var isTakingLong = false
    /// When it was last looked at.
    private var lastLooked: Date

    /// `takingLong` for one already said to be taking long, as one kept across a stop (`ArchiveWatcher`), which is not
    /// said again.
    init(_ sight: FileSight, at now: Date, takingLong: Bool = false) {
        self.sight = sight
        firstSeen = now
        lastLooked = now
        isTakingLong = takingLong
    }

    /// Whether it is to be looked at by a poll at `now`: always, but once it is taking long, every
    /// `watcher.awayPollSeconds`.
    func isDue(at now: Date, config: WatcherConfig) -> Bool {
        !isTakingLong || now.timeIntervalSince(lastLooked) >= config.awayPollSeconds
    }

    /// One poll, given how it is seen now, which is not gone.
    mutating func poll(_ current: FileSight, now: Date, config: WatcherConfig) -> Outcome {
        lastLooked = now
        if current != sight {
            sight = current
            unchangedPolls = 0
            unopenableSince = nil
        } else if case .seen(_, opens: true) = current {
            unchangedPolls += 1
            unopenableSince = nil
        } else {
            unchangedPolls = 0
            unopenableSince = unopenableSince ?? now
        }
        let waited = now.timeIntervalSince(firstSeen)
        let size = current.size ?? 0
        let emptyWaitOver = current.size == 0 && waited >= config.zeroByteWaitSeconds
        if (size > 0 && unchangedPolls >= config.stabilityRequiredPolls) || emptyWaitOver { return .settled }
        if let since = unopenableSince, now.timeIntervalSince(since) >= config.unopenableWaitSeconds { return .unopenable(current.unopenable) }
        guard !isTakingLong, waited >= config.stabilityMaxWaitSeconds else { return .waiting }
        isTakingLong = true
        return .stillChanging
    }
}
