import ArrumatorCore
import Foundation
import Synchronization

/// The processes sharing an index, as a test sets them up: this one (`current`), and others it starts and ends, such as
/// the app and an `arrumatorcli` command killed part way.
public final class TestProcesses: ProcessWatching {
    public let current: ProcessTag
    private let running: Mutex<Set<ProcessTag>>

    /// This process, as `pid`, and the others running.
    public init(pid: Int32 = TestProcesses.thisPID, running others: Set<ProcessTag> = []) {
        current = ProcessTag(pid: pid, started: TestProcesses.started)
        running = Mutex(others.union([current]))
    }

    public func isRunning(_ tag: ProcessTag) -> Bool { running.withLock { $0.contains(tag) } }

    /// Another process, running from now on.
    public func start(pid: Int32) -> ProcessTag {
        let tag = ProcessTag(pid: pid, started: Self.started)
        running.withLock { _ = $0.insert(tag) }
        return tag
    }

    /// Ends `tag`, as a command killed part way.
    public func end(_ tag: ProcessTag) { running.withLock { _ = $0.remove(tag) } }

    public static let thisPID: Int32 = 100
    public static let otherPID: Int32 = 200
    static let started: Int64 = 1_000_000
}
