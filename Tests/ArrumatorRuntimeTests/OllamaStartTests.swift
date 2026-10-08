@testable import ArrumatorCore
@testable import ArrumatorRuntime
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// How the runtime starts Ollama when the user asks (`ArrumatorRuntime.startOllama()`): one task at a time, which a stop
/// ends, with the settings in force when its turn comes.
@Suite struct OllamaStartTests {
    /// A press while a check runs joins it: replaced, the first would be out of the stop's reach, and could start a server
    /// after the stop (second review of 2026-10-08, finding 3).
    @Test func aTaskAskedForAgainWhileItRunsIsJoinedAndAStopEndsIt() async throws {
        let tasks = BackgroundTasks()
        let runs = Mutex(0)
        let began = Signal()
        let body: @Sendable () async -> Void = {
            runs.withLock { $0 += 1 }
            began.fire()
            // Runs until it is stopped, as a start waiting for a server to answer does.
            try? await TestTime(.blocks).sleep(seconds: 0)
        }
        let first = try #require(await tasks.joining("asked", body), "a runtime not stopped begins the task")
        try #require(await Patience.until { began.fired }, "which runs")
        let second = await tasks.joining("asked", body)
        #expect(second == first && runs.withLock { $0 } == 1, "asked again while it runs, the same task is given, not a second begun")
        _ = await tasks.close(forGood: true)
        let ended = Signal()
        Task {
            await tasks.ended()
            ended.fire()
        }
        #expect(await Patience.until { ended.fired }, "a stop ends it and waits for it")
        #expect(await tasks.joining("asked", body) == nil, "and none begins once the runtime is stopped")
    }

    /// Settings read before another change of them are never applied after it (second review of 2026-10-08, finding 3):
    /// what the lifecycle is told is read when its turn comes, in the step that applies it.
    @Test func ollamaIsConfiguredWithTheSettingsInForceWhenItsTurnComes() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let runtime = try await home.bootstrap()
        let server = try home.standInServer()
        defer { for pid in server.started { kill(pid, SIGKILL) } }
        try await runtime.ollamaConfiguring.acquire()
        let configured = Signal()
        Task {
            await runtime.configureOllama()
            configured.fire()
        }
        try #require(await Patience.until { runtime.ollamaConfiguring.waiting == 1 }, "the configuring waits its turn")
        _ = try await runtime.settingsActions.change {
            $0.ollamaManagement = .spawnServe
            $0.ollamaBinaryPath = server.executable.path
        }
        runtime.ollamaConfiguring.release()
        try #require(await Patience.until { configured.fired }, "and is applied once its turn comes")
        let starting = Task { await runtime.lifecycle.ensureRunning() }
        defer { starting.cancel() }
        #expect(await Patience.until { !server.started.isEmpty },
                "with the settings in force then, which start the server, not those of when it was asked, which never do")
        await runtime.stop()
    }
}
