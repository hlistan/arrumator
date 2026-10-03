@testable import ArrumatorCore
import ArrumatorTesting
import Darwin
import Foundation
import Testing

/// The lock a change of the settings takes across processes (`SettingsLock`): a holder that never lets it go, as one
/// stopped in a debugger, keeps no change waiting for ever, and a lock file the user cannot write still serves.
@Suite struct SettingsLockTests {
    /// The lock file beside the settings, held as another process would hold it, until `release`.
    private func hold(_ env: TestEnvironment) throws -> Int32 {
        let path = env.paths.settingsURL.appendingPathExtension(SettingsLock.fileExtension).path
        let descriptor = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        try #require(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0, "the lock is held as another process holds it")
        return descriptor
    }

    @Test(.timeLimit(.minutes(1))) func aChangeWaitsForAnotherProcessOnlyAsLongAsTheConfigurationSays() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let config = try PipelineConfig.bundledDefaults().settingsLock
        let store = try SettingsStore(paths: env.paths, config: config, time: TestTime(.advances))
        let file = try Data(contentsOf: env.paths.settingsURL)
        let held = try hold(env)
        defer { close(held) }
        let path = env.paths.settingsURL.appendingPathExtension(SettingsLock.fileExtension).path
        await #expect(throws: SettingsLockError.held(path: path, seconds: config.timeout), "the change fails, saying another process holds it") {
            try await store.update { $0.renameFiles = false }
        }
        #expect(try Data(contentsOf: env.paths.settingsURL) == file, "and nothing is saved")
        flock(held, LOCK_UN)
        try await store.update { $0.renameFiles = false }
        #expect(await store.current.renameFiles == false, "once it is let go, a change is made")
    }

    @Test(.timeLimit(.minutes(1))) func aChangeWaitingForTheLockStopsWhenItsTaskIsCancelled() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let store = try SettingsStore(paths: env.paths, config: PipelineConfig.bundledDefaults().settingsLock, time: TestTime(.blocks))
        let held = try hold(env)
        defer { close(held) }
        let change = Task { try await store.update { $0.renameFiles = false } }
        #expect(await Patience.until { await store.waitsForAnotherChange }, "the change waits for the lock")
        change.cancel()
        await #expect(throws: CancellationError.self, "and stops when it is told to") { _ = try await change.value }
    }

    @Test func aLockFileTheUserCannotWriteStillServes() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let path = env.paths.settingsURL.appendingPathExtension(SettingsLock.fileExtension).path
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        try await env.settings.update { $0.renameFiles = false }
        #expect(try await SettingsStore.opened(paths: env.paths).current.renameFiles == false, "the change is made and saved")
    }
}
