import ArrumatorCore
import Foundation
import Synchronization

/// Result of one external tool invocation.
struct ShellResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String
    var stdoutTruncated: Bool
    var timedOut: Bool
    var durationMs: Double
}

enum ShellError: Error, Sendable, CustomStringConvertible {
    case launchFailed(executable: String, underlying: String)

    var description: String {
        switch self {
        case let .launchFailed(executable, underlying): "Cannot launch \(executable): \(underlying)"
        }
    }
}

/// Runs command-line tools (`/usr/bin/textutil`) with a timeout and an output cap. Both pipes are drained
/// concurrently from the moment the process starts, so a chatty child can never block on a full pipe while we
/// wait for it. On timeout the child gets SIGTERM, then SIGKILL after a grace period.
public actor ShellRunner {
    private let time: any TimeSource

    public init(time: any TimeSource) { self.time = time }

    func run(_ executable: URL, arguments: [String], timeout: Double, killGrace: Double,
             outputCap: Int) async throws -> ShellResult {
        let started = Date()
        let time = time
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exit = OneShot<Int32>()
        process.terminationHandler = { exit.fire($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(executable: executable.path, underlying: error.localizedDescription)
        }

        let pid = process.processIdentifier
        async let stdout = Self.drain(stdoutPipe.fileHandleForReading, cap: outputCap)
        async let stderr = Self.drain(stderrPipe.fileHandleForReading, cap: outputCap)
        let timedOut = Flag()
        let watchdog = Task {
            try await time.sleep(seconds: timeout)
            timedOut.raise()
            kill(pid, SIGTERM)
            try await time.sleep(seconds: killGrace)
            kill(pid, SIGKILL)
        }
        let status = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            kill(pid, SIGKILL)
        }
        watchdog.cancel()
        let (out, err) = await (stdout, stderr)
        return ShellResult(status: status, stdout: out.data,
                           stderr: String(decoding: err.data, as: UTF8.self),
                           stdoutTruncated: out.truncated, timedOut: timedOut.isRaised,
                           durationMs: started.elapsedMs)
    }

    /// Reads `handle` to EOF on a background thread, keeping at most `cap` bytes (the rest is discarded so the
    /// child never blocks).
    private static func drain(_ handle: FileHandle, cap: Int) async -> (data: Data, truncated: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var data = Data()
                var truncated = false
                while let chunk = try? handle.read(upToCount: readChunkBytes), !chunk.isEmpty {
                    let room = cap - data.count
                    if chunk.count <= room {
                        data.append(chunk)
                    } else {
                        if room > 0 { data.append(chunk.prefix(room)) }
                        truncated = true
                    }
                }
                continuation.resume(returning: (data, truncated))
            }
        }
    }

    /// Pipe read size; matches the kernel pipe buffer so each read drains it in one call.
    private static let readChunkBytes = 64 * 1024

    /// Thread-safe boolean shared with the watchdog task.
    private final class Flag: Sendable {
        private let storage = Atomic<Bool>(false)
        func raise() { storage.store(true, ordering: .relaxed) }
        var isRaised: Bool { storage.load(ordering: .relaxed) }
    }
}
