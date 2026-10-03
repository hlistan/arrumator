import CoreServices
import Foundation

public struct FSEvent: Sendable, Hashable {
    public var path: String
    public var flags: UInt32
    public var id: UInt64

    public func has(_ flag: Int) -> Bool { flags & UInt32(flag) != 0 }
    public var isFile: Bool { has(kFSEventStreamEventFlagItemIsFile) }
    public var isDirectory: Bool { has(kFSEventStreamEventFlagItemIsDir) }
    public var isRenamed: Bool { has(kFSEventStreamEventFlagItemRenamed) }
    public var isCreated: Bool { has(kFSEventStreamEventFlagItemCreated) }
    public var needsRescan: Bool {
        has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
            || has(kFSEventStreamEventFlagKernelDropped) || has(kFSEventStreamEventFlagEventIdsWrapped)
            || has(kFSEventStreamEventFlagRootChanged)
    }
    public var isHistoryDone: Bool { has(kFSEventStreamEventFlagHistoryDone) }
    /// The watched folder itself was renamed, removed, or made again, or its volume went or came.
    var isRootChanged: Bool { has(kFSEventStreamEventFlagRootChanged) }
    /// Events were lost anywhere under the watched folder, or their numbers began again: nothing that came before
    /// tells what is there now.
    var lostEverywhere: Bool {
        has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped) || has(kFSEventStreamEventFlagEventIdsWrapped)
    }
}

/// Thin wrapper over a file-level FSEvents stream delivering batches through an `AsyncStream`.
/// The C callback only forwards to the continuation; all interpretation happens in actors.
public final class FSEventStream: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let continuation: AsyncStream<[FSEvent]>.Continuation
        init(_ c: AsyncStream<[FSEvent]>.Continuation) { continuation = c }
    }

    public let events: AsyncStream<[FSEvent]>
    private let box: Box
    private let queue = DispatchQueue(label: "dev.arrumator.fsevents", qos: .utility)
    // Invariant: `stream` is only touched on `queue` or before `start()` returns.
    private var stream: FSEventStreamRef?

    public init?(paths: [String], since: UInt64?, latency: Double) {
        let (events, continuation) = AsyncStream<[FSEvent]>.makeStream(bufferingPolicy: .unbounded)
        self.events = events
        box = Box(continuation)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(rawPaths, to: NSArray.self)
            var batch: [FSEvent] = []
            batch.reserveCapacity(count)
            for i in 0..<count {
                let path = (array[i] as? NSDictionary)?[kFSEventStreamEventExtendedDataPathKey] as? String
                    ?? array[i] as? String ?? ""
                batch.append(FSEvent(path: path, flags: rawFlags[i], id: rawIDs[i]))
            }
            box.continuation.yield(batch)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                          since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            continuation.finish()
            return nil
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
    }

    public func start() -> Bool {
        guard let stream else { return false }
        return FSEventStreamStart(stream)
    }

    public func stop() {
        queue.sync {
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        box.continuation.finish()
    }

    /// The number of the last event of this Mac's file systems: a stream started after it reports what comes from now on.
    static func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    public static func deviceUUID(for path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    deinit { stop() }
}
