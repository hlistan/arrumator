import Darwin
import Foundation

/// A process as the index names it: its id, and when it started, which tells it from a later process given the same id.
/// The app and each `arrumatorcli` command share one index, and a queue item one of them works on keeps its tag, so
/// another can tell an item in hand from one a process that ended left behind (`ProcessWatching`).
public struct ProcessTag: Sendable, Hashable, CustomStringConvertible {
    public let pid: Int32
    /// When it started, in microseconds since 1970, as the kernel keeps it (`kinfo_proc.kp_proc.p_starttime`).
    public let started: Int64

    public init(pid: Int32, started: Int64) {
        self.pid = pid
        self.started = started
    }

    /// The tag as the index keeps it: `<pid>:<started>`.
    public var description: String { "\(pid)\(Self.separator)\(started)" }

    /// The tag the index keeps as `text`; nil for text that is none.
    public init?(_ text: String) {
        let parts = text.split(separator: Self.separator, omittingEmptySubsequences: false)
        guard parts.count == 2, let pid = Int32(parts[0]), let started = Int64(parts[1]) else { return nil }
        self.init(pid: pid, started: started)
    }

    static let separator: Character = ":"
}

/// Which process this is, and whether another still runs.
public protocol ProcessWatching: Sendable {
    var current: ProcessTag { get }
    /// Whether the process `tag` names still runs: one that ended, or whose id a later process was given, does not.
    func isRunning(_ tag: ProcessTag) -> Bool
}

public enum ProcessError: Error, LocalizedError, Equatable {
    /// The kernel did not say when this process started, so it cannot be told from a later one with its id.
    case unknownStart(Int32)

    public var errorDescription: String? {
        switch self {
        case let .unknownStart(pid): "When process \(pid) started cannot be read"
        }
    }
}

/// The processes of this Mac, as the kernel lists them (`sysctl` with `KERN_PROC_PID`, Apple's `sys/sysctl.h`): a
/// process that ended is not listed, and one listed under the same id that started at another time is another.
public struct SystemProcesses: ProcessWatching {
    public let current: ProcessTag

    public init() throws {
        let pid = getpid()
        guard let started = Self.started(pid) else { throw ProcessError.unknownStart(pid) }
        current = ProcessTag(pid: pid, started: started)
    }

    public func isRunning(_ tag: ProcessTag) -> Bool {
        Self.started(tag.pid) == tag.started
    }

    /// When the process `pid` started, in microseconds since 1970; nil when no process has that id.
    static func started(_ pid: Int32) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Int64(started.tv_sec) * Self.microsecondsPerSecond + Int64(started.tv_usec)
    }

    static let microsecondsPerSecond: Int64 = 1_000_000
}
