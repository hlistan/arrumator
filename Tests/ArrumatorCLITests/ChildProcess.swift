import Foundation
import Synchronization

/// A command run to its end, as the tests of `arrumatorcli` run it: both of its outputs are read at once, as one that
/// fills its pipe while the other is read would wait for good, and a command still running at `deadline` is stopped
/// and fails the test, rather than hang the whole run.
struct ChildProcess {
    struct Outcome {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    struct DidNotFinish: Error, CustomStringConvertible {
        let command: String
        let deadline: TimeInterval
        var description: String { "\(command) did not finish within \(deadline) seconds and was stopped" }
    }

    /// Far above what the slowest command the tests run takes, which is seconds: it only turns a hang into a failure.
    static let deadline: TimeInterval = 120

    /// A value shared with the work that runs beside the test.
    private final class Shared<Value: Sendable>: Sendable {
        private let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        func set(_ newValue: Value) { value.withLock { $0 = newValue } }
        func get() -> Value { value.withLock { $0 } }
    }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                    deadline: TimeInterval = deadline) throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Threads of their own, not Dispatch's or Swift's shared pools: the tests that wait here hold threads of those,
        // and work queued behind them might never run.
        let pid = process.processIdentifier
        let ended = DispatchSemaphore(value: 0)
        let stopped = Shared(false)
        Thread {
            if ended.wait(timeout: .now() + deadline) == .timedOut {
                stopped.set(true)
                kill(pid, SIGKILL)
            }
        }.start()

        let stderr = Shared(Data())
        let errors = err.fileHandleForReading
        let errorsRead = DispatchSemaphore(value: 0)
        Thread {
            stderr.set(errors.readDataToEndOfFile())
            errorsRead.signal()
        }.start()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        errorsRead.wait()
        process.waitUntilExit()
        ended.signal()

        if stopped.get() {
            throw DidNotFinish(command: ([executable.lastPathComponent] + arguments).joined(separator: " "), deadline: deadline)
        }
        return Outcome(status: process.terminationStatus, stdout: stdout, stderr: stderr.get())
    }
}
