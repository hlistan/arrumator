import AppKit
import Foundation
import Synchronization

public enum OllamaState: Sendable, Hashable, Codable {
    case unknown
    case notInstalled
    case stopped
    case starting
    case ready(version: String)
    case unhealthy(String)
    /// A server on another machine, by its host, that does not answer: whether it runs there is not known.
    case unreachable(String)

    public var isReady: Bool { if case .ready = self { true } else { false } }

    public var summary: String {
        switch self {
        case .unknown: "Checking Ollama…"
        case .notInstalled: "Ollama is not installed"
        case .stopped: "Ollama is not running"
        case .starting: "Starting Ollama…"
        case let .ready(v): "Ollama \(v) ready"
        case let .unhealthy(why): "Ollama problem: \(why)"
        case let .unreachable(host): "Ollama at \(host) cannot be reached"
        }
    }
}

public struct OllamaInstallation: Sendable, Hashable, Codable {
    public var appURL: URL?
    public var binaryURL: URL?
}

/// Detects, starts and supervises the local Ollama server.
public actor OllamaLifecycle {
    private let api: any OllamaAPI
    private let config: OllamaConfig
    private let time: any TimeSource
    private var management: OllamaManagement
    private var binaryOverride: String?
    /// Where the app talks to Ollama; a server it spawns listens there.
    private var address: URL
    private var process: Process?
    private var restarts: [Date] = []
    /// How many probes in a row have found no server answering in time since it was last ready (`check()`): a server
    /// that answers, whether a probe or a start found it so, has failed none.
    private var failedProbes = 0
    /// Supervision's task (`startMonitoring`), until it is stopped (`shutdown`).
    private(set) var monitorTask: Task<Void, Never>?
    /// The start under way (`ensureRunning()`), which every caller meanwhile waits for.
    private var starting: Task<Start, Never>?
    /// How many times `shutdown()` has run: a start begun before the last one starts nothing after it.
    private var shutdowns = 0
    /// The server the app spawned and has not seen end, by its process number, readable outside the actor, as a process
    /// that must end at once ends it (`endSpawnedServerNow()`), and whether one has: then no server is spawned again.
    /// A spawn runs under its lock, so an end at once either comes first and spawns nothing, or finds the server spawned.
    private let spawned = Mutex<(pid: pid_t?, endedNow: Bool)>((nil, false))
    /// What the log says when the app spawns `ollama serve`, with the server's process number in `pid`.
    public static let spawnedMessage: StaticString = "Spawned ollama serve"
    private var continuations: [UUID: AsyncStream<OllamaState>.Continuation] = [:]
    public private(set) var state: OllamaState = .unknown {
        didSet {
            if state.isReady { failedProbes = 0 }
            guard state != oldValue else { return }
            Log.info(.ollama, "Ollama's state changed", ["state": state.summary])
            for c in continuations.values { c.yield(state) }
        }
    }

    public init(api: any OllamaAPI, config: OllamaConfig, management: OllamaManagement, binaryOverride: String?, address: URL,
                time: any TimeSource) {
        self.api = api
        self.config = config
        self.management = management
        self.binaryOverride = binaryOverride
        self.address = address
        self.time = time
    }

    public func configure(management: OllamaManagement, binaryOverride: String?, address: URL) {
        self.management = management
        self.binaryOverride = binaryOverride
        self.address = address
    }

    /// The variable `ollama serve` reads the address it listens on from (Ollama's `envconfig`).
    static let hostVariable = "OLLAMA_HOST"

    /// `host:port` for `OLLAMA_HOST`: the address the app talks to, so the server it spawns is the one it asks.
    static func listenAddress(for url: URL) -> String? {
        guard let host = url.host(percentEncoded: false) else { return nil }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return url.port.map { "\(bracketed):\($0)" } ?? bracketed
    }

    public func states() -> AsyncStream<OllamaState> {
        let id = UUID()
        let (stream, c) = AsyncStream<OllamaState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(state)
        continuations[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    // MARK: Discovery

    public func discover() -> OllamaInstallation {
        let fm = FileManager.default
        if let override = binaryOverride?.expandingTilde, fm.isExecutableFile(atPath: override) {
            return OllamaInstallation(appURL: nil, binaryURL: URL(fileURLWithPath: override))
        }
        var app: URL?
        var binary: URL?
        for candidate in config.binarySearchPaths.map(\.expandingTilde) {
            if candidate.hasSuffix(".app") {
                let appBinary = URL(fileURLWithPath: candidate).appendingPathComponent(config.appBinarySubpath)
                if fm.isExecutableFile(atPath: appBinary.path) {
                    app = app ?? URL(fileURLWithPath: candidate)
                    binary = binary ?? appBinary
                }
            } else if fm.isExecutableFile(atPath: candidate) {
                binary = binary ?? URL(fileURLWithPath: candidate)
            }
        }
        if app == nil, let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.appBundleIdentifier) {
            app = found
            let appBinary = found.appendingPathComponent(config.appBinarySubpath)
            if fm.isExecutableFile(atPath: appBinary.path) { binary = binary ?? appBinary }
        }
        return OllamaInstallation(appURL: app, binaryURL: binary)
    }

    // MARK: Health

    /// Checks the server once and updates `state`. A server that does not answer this probe in time (`timedOut`: it
    /// answers nothing else either) is not running once `ollama.failedProbesBeforeAway` probes in a row have found it so
    /// when it was ready: one probe a server busy reading answers late is no server gone, which History would say, and
    /// say back a minute later. One that cannot be reached otherwise (`OllamaError.isAway`), as a connection refused when
    /// it has crashed, is not running at once, so supervision starts it again without waiting out probes that could only
    /// say the same. One that answers with a failure runs, unhealthy, and is never started again beside itself. Stopped
    /// meanwhile, it learns nothing, whatever failure the stop brought, and `state` stays as it was.
    @discardableResult
    public func check() async -> OllamaState {
        do {
            state = .ready(version: try await api.version())
        } catch where Cancellation.stops(error) {
            // Stopped while it asked: nothing was learnt of the server, not even that it failed.
        } catch let failure as OllamaError where !failure.isAway && !failure.timedOut {
            failedProbes = 0
            state = .unhealthy(failure.localizedDescription)
        } catch {
            failedProbes += 1
            if state.isReady, (error as? OllamaError)?.timedOut == true, failedProbes < config.failedProbesBeforeAway {
                Log.info(.ollama, "A probe of a ready server timed out; it is asked again before it is taken to be away",
                         ["failed": String(failedProbes), "error": error.localizedDescription])
                return state
            }
            if !OllamaEndpoint.isThisMac(address) {
                // What is installed on this Mac says nothing of a server on another machine.
                state = .unreachable(address.host(percentEncoded: false) ?? address.absoluteString)
            } else {
                let install = discover()
                state = (install.appURL == nil && install.binaryURL == nil) ? .notInstalled : .stopped
            }
        }
        return state
    }

    /// What a start came to: the state it left, and whether it launched or spawned a server to get there.
    struct Start: Sendable {
        let state: OllamaState
        let started: Bool
    }

    /// Makes sure the server runs, starting it according to the management mode. A start already under way is waited
    /// for rather than begun again beside it, so a server is started once however often this is asked meanwhile, as when
    /// the user presses Start while the app starts it. A caller stopped while it waits stops the start too: a start is
    /// the runtime's work, which its stop ends (`shutdown()`).
    @discardableResult
    public func ensureRunning() async -> OllamaState {
        await start().state
    }

    /// The start under way, or a new one.
    private func start() async -> Start {
        let start: Task<Start, Never>
        if let starting {
            start = starting
        } else {
            start = Task { await self.startOnce() }
            starting = start
        }
        let outcome = await withTaskCancellationHandler { await start.value } onCancel: { start.cancel() }
        if starting == start { starting = nil }
        return outcome
    }

    /// Checks the server, and starts it when it does not run on this Mac and the app may start it. A start stopped while
    /// it checks, or ended by `shutdown()` meanwhile, starts nothing: a server it spawned then would outlive the app.
    private func startOnce() async -> Start {
        let generation = shutdowns
        let checked = await check()
        guard !Task.isCancelled, generation == shutdowns, checked == .stopped, management != .external else {
            return Start(state: state, started: false)
        }
        let install = discover()
        state = .starting
        do {
            switch management {
            case .launchApp:
                if let app = install.appURL {
                    try await launchApp(app)
                } else if let binary = install.binaryURL {
                    try spawnServe(binary)
                } else {
                    state = .notInstalled
                    return Start(state: state, started: false)
                }
            case .spawnServe:
                guard let binary = install.binaryURL else {
                    state = .notInstalled
                    return Start(state: state, started: false)
                }
                try spawnServe(binary)
            case .external:
                return Start(state: state, started: false)
            }
        } catch {
            state = .unhealthy(error.localizedDescription)
            return Start(state: state, started: false)
        }
        return Start(state: await answered(), started: true)
    }

    /// Waits for a server just started to answer, at most `startTimeout`.
    private func answered() async -> OllamaState {
        let deadline = time.now().addingTimeInterval(config.startTimeout)
        while time.now() < deadline {
            do { try await time.sleep(seconds: config.healthPollStarting) } catch { return state }
            if let v = try? await api.version() {
                state = .ready(version: v)
                return state
            }
        }
        state = .unhealthy("did not answer within \(Int(config.startTimeout)) s")
        return state
    }

    private func launchApp(_ app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        Log.info(.ollama, "Launched Ollama app", ["app": app.path])
    }

    /// Starts `ollama serve` in place of the one the app started before, which, still running but not answering, is
    /// stopped first: the app keeps one server of its own, the one `shutdown()` stops.
    private func spawnServe(_ binary: URL) throws {
        stopSpawned()
        let p = Process()
        p.executableURL = binary
        p.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in config.serveEnvironment { env[k] = v }
        env[Self.hostVariable] = Self.listenAddress(for: address)
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let (id, status) = (ObjectIdentifier(proc), proc.terminationStatus)
            Task { await self?.processExited(id, status: status) }
        }
        try spawned.withLock { spawned in
            // The process is ending at once: a server spawned now would outlive it.
            guard !spawned.endedNow else { throw CancellationError() }
            try p.run()
            spawned.pid = p.processIdentifier
        }
        process = p
        Log.info(.ollama, Self.spawnedMessage, ["binary": binary.path, "pid": String(p.processIdentifier)])
    }

    /// The server the app started has ended: unless it is one the app has since replaced, none runs.
    private func processExited(_ id: ObjectIdentifier, status: Int32) {
        Log.warning(.ollama, "ollama serve exited", ["status": String(status)])
        guard let process, ObjectIdentifier(process) == id else { return }
        self.process = nil
        spawned.withLock { $0.pid = nil }
        state = .stopped
    }

    /// Stops the server the app started, if it still runs.
    private func stopSpawned() {
        if let process, process.isRunning {
            process.terminate()
            Log.info(.ollama, "Stopped spawned ollama serve")
        }
        process = nil
        spawned.withLock { $0.pid = nil }
    }

    /// Ends the server the app spawned at once, from outside the actor, as a command does when a second Ctrl-C ends it
    /// before its stop could: the server runs in a process group of its own, which no signal to the command reaches. A
    /// spawn under way is waited for, as it holds the lock, and none is spawned after it.
    public nonisolated func endSpawnedServerNow() {
        let pid = spawned.withLock { spawned in
            spawned.endedNow = true
            return spawned.pid
        }
        if let pid { kill(pid, SIGTERM) }
    }

    /// Supervises the server: periodic health checks and bounded restarts with backoff.
    public func startMonitoring() {
        monitorTask?.cancel()
        let steady = config.healthPollSteady
        let time = time
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await time.sleep(seconds: steady) } catch { return }
                await self?.supervise()
            }
        }
    }

    /// Restarts a server that stopped, after a backoff, at most `maxRestartsPerHour` times an hour. A restart counts
    /// only when one was made: not when the server answered again meanwhile, or none could be started. One look of
    /// supervision (`startMonitoring`).
    func supervise() async {
        if await check().isReady || management == .external || Task.isCancelled { return }
        let hourAgo = time.now().addingTimeInterval(-Units.secondsPerHour)
        restarts = restarts.filter { $0 > hourAgo }
        guard restarts.count < config.maxRestartsPerHour else {
            state = .unhealthy("gave up after \(restarts.count) restarts in the last hour")
            return
        }
        let delay = config.restartBackoff.clamped(restarts.count)
        do { try await time.sleep(seconds: delay) } catch { return }
        guard await start().started else { return }
        restarts.append(time.now())
        Log.info(.ollama, "Restarted Ollama", ["attempt": String(restarts.count), "delay": String(delay)])
    }

    /// Stops supervising, ends a start under way, and stops the server the app started. Supervision's task ends at once
    /// while it waits, or once the look under way is stopped, which is not waited for, so a stop that waits for nothing
    /// else is never held up by a look.
    public func shutdown() {
        monitorTask?.cancel()
        monitorTask = nil
        shutdowns += 1
        starting?.cancel()
        starting = nil
        stopSpawned()
    }
}
