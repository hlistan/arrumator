import AppKit
import Foundation

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
    private var monitorTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<OllamaState>.Continuation] = [:]
    public private(set) var state: OllamaState = .unknown {
        didSet {
            guard state != oldValue else { return }
            Log.info(.ollama, "State: \(state.summary)")
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

    /// Checks the server once and updates `state`.
    @discardableResult
    public func check() async -> OllamaState {
        do {
            let v = try await api.version()
            state = .ready(version: v)
        } catch {
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

    /// Makes sure the server runs, starting it according to the management mode.
    @discardableResult
    public func ensureRunning() async -> OllamaState {
        if await check().isReady { return state }
        guard management != .external else { return state }
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
                    return state
                }
            case .spawnServe:
                guard let binary = install.binaryURL else {
                    state = .notInstalled
                    return state
                }
                try spawnServe(binary)
            case .external:
                return state
            }
        } catch {
            state = .unhealthy(error.localizedDescription)
            return state
        }
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

    private func spawnServe(_ binary: URL) throws {
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
            let status = proc.terminationStatus
            Task { await self?.processExited(status: status) }
        }
        try p.run()
        process = p
        Log.info(.ollama, "Spawned ollama serve", ["binary": binary.path, "pid": String(p.processIdentifier)])
    }

    private func processExited(status: Int32) {
        Log.warning(.ollama, "ollama serve exited", ["status": String(status)])
        process = nil
        state = .stopped
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

    private func supervise() async {
        if await check().isReady || management == .external { return }
        let hourAgo = time.now().addingTimeInterval(-Units.secondsPerHour)
        restarts = restarts.filter { $0 > hourAgo }
        guard restarts.count < config.maxRestartsPerHour else {
            state = .unhealthy("gave up after \(restarts.count) restarts in the last hour")
            return
        }
        let delay = config.restartBackoff.clamped(restarts.count)
        restarts.append(time.now())
        Log.info(.ollama, "Restarting Ollama", ["attempt": String(restarts.count), "delay": String(delay)])
        do { try await time.sleep(seconds: delay) } catch { return }
        await ensureRunning()
    }

    public func shutdown() {
        monitorTask?.cancel()
        monitorTask = nil
        if let process, process.isRunning {
            process.terminate()
            Log.info(.ollama, "Stopped spawned ollama serve")
        }
        process = nil
    }
}
