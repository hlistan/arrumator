import Darwin
import Foundation

/// Why the lock on the settings could not be taken.
public enum SettingsLockError: Error, LocalizedError, Equatable {
    /// Another process held it for all of `seconds`: it is changing the settings, or it was stopped while it did.
    case held(path: String, seconds: Double)
    /// The file the lock is taken on could not be opened or made, for `reason`.
    case unopenable(path: String, reason: String)

    static let millisecondsPerSecond = 1_000.0

    public var errorDescription: String? {
        switch self {
        case let .held(path, seconds):
            "Another process is changing the settings: it held \(path) for \(Format.duration(seconds * Self.millisecondsPerSecond)); try again once it is done"
        case let .unopenable(path, reason): "The settings cannot be changed, as \(path) cannot be opened: \(reason)"
        }
    }
}

/// The lock every `SettingsStore`, in this process or another, holds while it reads, changes and saves the settings:
/// an exclusive `flock(2)` on a file beside them (`settings.json.lock`), so a change made by `arrumatorcli` while the app
/// runs is never read before another is saved and then saved over. The lock is advisory: only stores take it, and the
/// system lets it go when the process ends, however it ends.
struct SettingsLock: Sendable {
    private let descriptor: Int32

    /// What is added to the settings file's name to name the file the lock is taken on.
    static let fileExtension = "lock"

    /// Takes the lock on the file beside `settings`, asking without waiting (`LOCK_NB`) and again every
    /// `config.pollInterval` seconds of `time` while another holds it, for at most `config.timeout` seconds: a
    /// holder that is stopped, as by a debugger, never keeps a change waiting for ever. Cancelling the task stops the
    /// wait. The file is opened for reading alone, which `flock` needs no more than, so one the user cannot write, as one
    /// a run as root left, still serves.
    static func take(beside settings: URL, config: SettingsLockConfig, time: any TimeSource) async throws -> SettingsLock {
        let path = settings.appendingPathExtension(fileExtension).path
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw SettingsLockError.unopenable(path: path, reason: String(cString: strerror(errno))) }
        let deadline = time.now().addingTimeInterval(config.timeout)
        do {
            while true {
                try Task.checkCancellation()
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return SettingsLock(descriptor: descriptor) }
                let failure = errno
                guard failure == EWOULDBLOCK || failure == EINTR else {
                    throw SettingsLockError.unopenable(path: path, reason: String(cString: strerror(failure)))
                }
                guard time.now() < deadline else { throw SettingsLockError.held(path: path, seconds: config.timeout) }
                try await time.sleep(seconds: config.pollInterval)
            }
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Lets the lock go, for the next change in any process.
    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
