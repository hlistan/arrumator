@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// How the app starts, watches and stops an Ollama server of its own on this Mac (`OllamaLifecycle`): with a stand-in
/// for `ollama serve` and a double for its API, never the user's Ollama.
@Suite struct OllamaLifecycleTests {
    /// A server whose version is answered as `answers` says, call by call: the first call is 0.
    final class ScriptedServer: OllamaAPI {
        private let calls = Mutex(0)
        private let answers: @Sendable (Int) -> Result<String, OllamaError>

        init(_ answers: @escaping @Sendable (Int) -> Result<String, OllamaError>) { self.answers = answers }

        var baseURL: URL { MockOllama.server }
        var versionCalls: Int { calls.withLock { $0 } }

        func version() async throws -> String {
            let call = calls.withLock { calls in
                defer { calls += 1 }
                return calls
            }
            return try answers(call).get()
        }

        func tags() async throws -> [OllamaModelInfo] { [] }
        func show(model: String) async throws -> OllamaShowResponse { MockOllama.shown(capabilities: [], thinking: nil) }
        func chat(_ request: OllamaChatRequest, partial: (@Sendable (OllamaChatResponse) async -> Void)?) async throws -> OllamaChatResponse {
            throw OllamaError.unreachable(Self.down)
        }
        func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse { throw OllamaError.unreachable(Self.down) }
        func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> { AsyncThrowingStream { $0.finish() } }

        static let down = "Could not connect to the server."
        static let version = "0.0.0-test"
        /// A server that is not running.
        static let away: Result<String, OllamaError> = .failure(.unreachable(down))
    }

    /// Everything a lifecycle publishes on `states()`, in order.
    actor StateLog {
        private(set) var states: [OllamaState] = []
        func add(_ state: OllamaState) { states.append(state) }
    }

    /// A folder of the test's own for the stand-in server.
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-ollama-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A lifecycle that spawns `server` as `ollama serve` on this Mac, never the user's: no other place is searched.
    private func lifecycle(_ api: any OllamaAPI, spawning server: StandInServer, time: TestTime,
                           tune: (inout OllamaConfig) -> Void = { _ in }) throws -> OllamaLifecycle {
        var config = try PipelineConfig.bundledDefaults().ollama
        config.binarySearchPaths = []
        tune(&config)
        return OllamaLifecycle(api: api, config: config, management: .spawnServe, binaryOverride: server.executable.path,
                               address: MockOllama.server, time: time)
    }

    @Test func aStartAskedForWhileOneIsUnderWayWaitsForItAndStartsNoSecondServer() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try StandInServer(in: folder)
        let api = ScriptedServer { _ in ScriptedServer.away }
        let lifecycle = try lifecycle(api, spawning: server, time: TestTime(.blocks))
        let first = Task { await lifecycle.ensureRunning() }
        defer { first.cancel() }
        try #require(await Patience.until { server.started.count == 1 }, "the app starts the server, and waits for it to answer")
        let pressed = Signal()
        let second = Task {
            let state = await lifecycle.ensureRunning()
            pressed.fire()
            return state
        }
        defer { second.cancel() }
        first.cancel()
        #expect(await Patience.until { pressed.fired }, "Start pressed meanwhile waits for the start under way, and ends with it")
        await lifecycle.shutdown()
        #expect(server.started.count == 1, "one server is started, not one more for each time Start is pressed: \(server.started)")
        #expect(await Patience.until { server.started.allSatisfy { !StandInServer.runs($0) } }, "and the one started is stopped")
    }

    @Test func aServerStartedAgainReplacesTheOneThatDidNotAnswerAndIsTheOneStopped() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try StandInServer(in: folder)
        let api = ScriptedServer { _ in ScriptedServer.away }
        let lifecycle = try lifecycle(api, spawning: server, time: TestTime(.advances))
        #expect(await lifecycle.ensureRunning() == .unhealthy("did not answer within \(Int(try PipelineConfig.bundledDefaults().ollama.startTimeout)) s"),
                "a server that never answers is unhealthy once the start's time is up")
        try #require(await Patience.until { server.started.count == 1 })
        let first = try #require(server.started.first)
        _ = await lifecycle.ensureRunning()
        try #require(await Patience.until { server.started.count == 2 }, "asked again, the app starts the server again")
        let second = server.started[1]
        #expect(await Patience.until { !StandInServer.runs(first) }, "after stopping the one that did not answer: one server of its own at a time")
        // The first one's end, which comes after the second started, leaves the second in hand.
        await lifecycle.shutdown()
        #expect(await Patience.until { !StandInServer.runs(second) }, "the server the app started last is the one it stops")
    }

    @Test func aRestartCountsOnlyWhenAServerWasStarted() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try StandInServer(in: folder)
        // Down whenever supervision looks, back by the time it would restart it: no restart is ever made.
        let api = ScriptedServer { $0.isMultiple(of: 2) ? ScriptedServer.away : .success(ScriptedServer.version) }
        let lifecycle = try lifecycle(api, spawning: server, time: TestTime(.advances))
        let log = StateLog()
        let states = await lifecycle.states()
        let following = Task { for await state in states { await log.add(state) } }
        defer { following.cancel() }
        await lifecycle.startMonitoring()
        let looks = try PipelineConfig.bundledDefaults().ollama.maxRestartsPerHour * 4
        try #require(await Patience.until { api.versionCalls >= looks }, "supervision looks again and again")
        await lifecycle.shutdown()
        #expect(server.started.isEmpty, "no server was started, as each time it answered again before")
        let seen = await log.states
        #expect(!seen.contains { if case .unhealthy = $0 { true } else { false } },
                "so supervision never gives up on restarts it did not make: \(seen)")
    }

    @Test func aServerThatAnswersWithAFailureIsUnhealthyAndNeverStartedBesideItself() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try StandInServer(in: folder)
        let failure = OllamaError.http(status: 500, body: "runner crashed")
        let api = ScriptedServer { _ in .failure(failure) }
        let lifecycle = try lifecycle(api, spawning: server, time: TestTime(.advances))
        #expect(await lifecycle.ensureRunning() == .unhealthy(failure.localizedDescription),
                "a server that answers runs, so it is said to be unhealthy, with what it answered")
        await lifecycle.shutdown()
        #expect(server.started.isEmpty, "and no second server is started on its address")
        let away = ScriptedServer { _ in .failure(.timeout("version")) }
        let timedOut = try self.lifecycle(away, spawning: server, time: TestTime(.advances)) { $0.startTimeout = 0 }
        _ = await timedOut.ensureRunning()
        #expect(await Patience.until { server.started.count == 1 }, "one that does not answer in time is away, and is started")
        await timedOut.shutdown()
    }

    /// A server asked for its version that answers only when the request is stopped, as a request URLSession is still
    /// waiting on: what a start is checking when the app quits.
    final class HangingServer: OllamaAPI {
        private let calls = Mutex(0)
        var baseURL: URL { MockOllama.server }
        var versionCalls: Int { calls.withLock { $0 } }

        func version() async throws -> String {
            calls.withLock { $0 += 1 }
            try await TestTime(.blocks).sleep(seconds: 1)
            throw OllamaError.unreachable(ScriptedServer.down)
        }

        func tags() async throws -> [OllamaModelInfo] { [] }
        func show(model: String) async throws -> OllamaShowResponse { MockOllama.shown(capabilities: [], thinking: nil) }
        func chat(_ request: OllamaChatRequest, partial: (@Sendable (OllamaChatResponse) async -> Void)?) async throws -> OllamaChatResponse {
            throw OllamaError.unreachable(ScriptedServer.down)
        }
        func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse { throw OllamaError.unreachable(ScriptedServer.down) }
        func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> { AsyncThrowingStream { $0.finish() } }
    }

    @Test func shutdownWhileTheStartChecksTheServerLeavesNoServerRunning() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try StandInServer(in: folder)
        defer { for pid in server.started { kill(pid, SIGKILL) } }
        let api = HangingServer()
        let lifecycle = try lifecycle(api, spawning: server, time: TestTime(.blocks))
        let start = Task { await lifecycle.ensureRunning() }
        try #require(await Patience.until { api.versionCalls == 1 }, "the start is checking the server")
        await lifecycle.shutdown()
        let state = await start.value
        #expect(state != .starting && state != .stopped,
                "the check the shutdown stopped learnt nothing of the server, and no start began on it: \(state)")
        await lifecycle.shutdown()
        #expect(server.started.isEmpty, "so no server was started to outlive the app: \(server.started)")
    }
}
