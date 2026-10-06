@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// How the app starts, watches and stops an Ollama server of its own on this Mac (`OllamaLifecycle`): with a stand-in
/// for `ollama serve` and a double for its API, never the user's Ollama.
@Suite struct OllamaLifecycleTests {
    /// A server whose version is answered as `answers` says, call by call: the first call is 0. From call `holdingAt` on,
    /// if given, it answers nothing until the request is cancelled, and says it got there (`held`): where a test that
    /// counts calls (`count`) stops what makes them, rather than leave it looking as fast as test time lets it while it
    /// waits.
    final class ScriptedServer: OllamaAPI {
        private let calls = Mutex(0)
        private let answers: @Sendable (Int) -> Result<String, OllamaError>
        private let holdingAt: Int?
        let held = Signal()

        init(holdingAt: Int? = nil, _ answers: @escaping @Sendable (Int) -> Result<String, OllamaError>) {
            self.holdingAt = holdingAt
            self.answers = answers
        }

        var baseURL: URL { MockOllama.server }

        func version() async throws -> String {
            let call = calls.withLock { calls in
                defer { calls += 1 }
                return calls
            }
            if let holdingAt, call >= holdingAt {
                held.fire()
                try await TestTime(.blocks).sleep(seconds: 0)
            }
            return try answers(call).get()
        }

        /// How many times it was asked its version.
        var count: Int { calls.withLock { $0 } }

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

    @Test func noServerIsSpawnedOnceTheProcessIsEndingAtOnce() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try StandInServer(in: folder)
        defer { for pid in server.started { kill(pid, SIGKILL) } }
        let lifecycle = try lifecycle(ScriptedServer { _ in ScriptedServer.away }, spawning: server, time: TestTime(.blocks))
        // A second Ctrl-C ends the command at once, as a start is about to spawn the server.
        lifecycle.endSpawnedServerNow()
        // Followed from a task of its own: a server spawned would be waited for, on time that never passes, for ever.
        let starting = Task { await lifecycle.ensureRunning() }
        defer { starting.cancel() }
        let done = Signal()
        Task {
            _ = await starting.value
            done.fire()
        }
        try #require(await Patience.until { done.fired }, "the start ends at once, spawning nothing that would outlive the process")
        #expect(await starting.value == .unhealthy(CancellationError().localizedDescription), "and says it did not start")
        await lifecycle.shutdown()
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

    /// Supervision looks at the server again and again once it is started, each time after `healthPollSteady`, until the
    /// app stops.
    @Test func supervisionLooksAgainAndAgainUntilTheAppStops() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let api = ScriptedServer(holdingAt: 1) { _ in .success(ScriptedServer.version) }
        let time = TestTime(.advances)
        let lifecycle = try lifecycle(api, spawning: try StandInServer(in: folder), time: time)
        await lifecycle.startMonitoring()
        try #require(await Patience.until { api.held.fired }, "supervision looks again after its first look")
        let steady = try PipelineConfig.bundledDefaults().ollama.healthPollSteady
        #expect(time.now() == TestTime.start.addingTimeInterval(2 * steady), "each look after waiting its time")
        await lifecycle.shutdown()
        let supervision = await lifecycle.monitorTask
        let ended = Signal()
        Task {
            await supervision?.value
            ended.fire()
        }
        try #require(await Patience.until { ended.fired }, "supervision ends once the app stops")
        #expect(api.count == 2, "having looked no more")
    }

    /// Each look made here, one after another, rather than by supervision's own task, which a loaded Mac may leave
    /// waiting for its turn longer than a test waits.
    @Test func aRestartCountsOnlyWhenAServerWasStarted() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try StandInServer(in: folder)
        // Down whenever supervision looks, back by the time it would restart it: no restart is ever made, in more looks
        // than it may restart in an hour.
        let api = ScriptedServer { $0.isMultiple(of: 2) ? ScriptedServer.away : .success(ScriptedServer.version) }
        let lifecycle = try lifecycle(api, spawning: server, time: TestTime(.advances))
        for look in 0..<(try PipelineConfig.bundledDefaults().ollama.maxRestartsPerHour * 2) {
            await lifecycle.supervise()
            let state = await lifecycle.state
            #expect(state == .ready(version: ScriptedServer.version),
                    "look \(look): supervision never gives up on restarts it did not make: \(state)")
        }
        await lifecycle.shutdown()
        #expect(server.started.isEmpty, "no server was started, as each time it answered again before")
    }

    @Test func aReadyServerIsAwayOnlyOnceProbesInARowFindItSoNotAtOneSlowProbe() async throws {
        let late = OllamaError.timeout("api/version")
        let script: [Result<String, OllamaError>] = [.success(ScriptedServer.version), .failure(late), .success(ScriptedServer.version),
                                                     .failure(late), .failure(late), .failure(late)]
        var config = try PipelineConfig.bundledDefaults().ollama
        config.failedProbesBeforeAway = 3
        let lan = try #require(URL(string: "http://192.168.1.239:11434"))
        let lifecycle = OllamaLifecycle(api: ScriptedServer { script[$0] }, config: config, management: .external, binaryOverride: nil,
                                        address: lan, time: TestTime(.advances))
        var states: [OllamaState] = []
        for _ in script.indices { states.append(await lifecycle.check()) }
        let ready = OllamaState.ready(version: ScriptedServer.version)
        #expect(states == [ready, ready, ready, ready, ready, .unreachable("192.168.1.239")],
                "a server busy reading that answers one probe late stays ready; three probes in a row it does not answer make it away: \(states)")
        let first = OllamaLifecycle(api: ScriptedServer { _ in .failure(late) }, config: config, management: .external, binaryOverride: nil,
                                    address: lan, time: TestTime(.advances))
        #expect(await first.check() == .unreachable("192.168.1.239"), "one never seen ready is away at its first failed probe")
    }

    /// Only a probe answered late, as by a server busy reading, waits for more: a connection refused, as to a managed
    /// server that crashed, finds it away at once, so supervision starts it again without waiting out probes that could
    /// only say the same (second review of 2026-10-04, finding 5).
    @Test func aReadyServerThatRefusesTheConnectionIsAwayAtOnce() async throws {
        var config = try PipelineConfig.bundledDefaults().ollama
        config.failedProbesBeforeAway = 3
        let script: [Result<String, OllamaError>] = [.success(ScriptedServer.version), ScriptedServer.away]
        let lifecycle = OllamaLifecycle(api: ScriptedServer { script[$0] }, config: config, management: .external, binaryOverride: nil,
                                        address: MockOllama.server, time: TestTime(.advances))
        #expect(await lifecycle.check() == .ready(version: ScriptedServer.version), "ready first")
        let refused = await lifecycle.check()
        #expect(!refused.isReady && refused != .unknown, "one refused connection finds a ready server on this Mac away: \(refused)")
        let lan = try #require(URL(string: "http://192.168.1.239:11434"))
        let remote = OllamaLifecycle(api: ScriptedServer { script[$0] }, config: config, management: .external, binaryOverride: nil,
                                     address: lan, time: TestTime(.advances))
        _ = await remote.check()
        #expect(await remote.check() == .unreachable("192.168.1.239"), "and one on the network unreachable")
    }

    @Test func aServerStartedAgainIsAwayOnlyOnceProbesInARowFindItSoAgain() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try StandInServer(in: folder)
        // Away when first checked, ready once started, then one probe answered late.
        let script: [Result<String, OllamaError>] = [ScriptedServer.away, .success(ScriptedServer.version), .failure(.timeout("api/version"))]
        let lifecycle = try lifecycle(ScriptedServer { script[min($0, script.count - 1)] }, spawning: server, time: TestTime(.advances)) {
            $0.failedProbesBeforeAway = 2
        }
        let ready = OllamaState.ready(version: ScriptedServer.version)
        let started = await lifecycle.ensureRunning()
        #expect(started == ready, "the server away is started, and answers: \(started)")
        #expect(await Patience.until { server.started.count == 1 }, "once")
        #expect(await lifecycle.check() == ready,
                "one slow probe of the server started again is no server gone: the probe that found it away counts no more")
        await lifecycle.shutdown()
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
