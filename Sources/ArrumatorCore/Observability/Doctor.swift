import Foundation
import GRDB

public struct DoctorCheck: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable { case ok, warning, error }
    public var name: String
    public var status: Status
    public var detail: String
}

public struct DoctorReport: Sendable, Codable, Hashable {
    public var generatedAt: Date
    public var appVersion: String
    public var macOS: String
    public var paths: [String: String]
    public var checks: [DoctorCheck]
    public var models: [ModelStatus]
    public var ollama: String

    public var hasErrors: Bool { checks.contains { $0.status == .error } }
}

/// Environment self-check, logged at startup and exported with diagnostics.
public struct Doctor: Sendable {
    public let database: AppDatabase
    public let paths: AppPaths
    public let appVersion: String
    public let time: any TimeSource

    public init(database: AppDatabase, paths: AppPaths, appVersion: String, time: any TimeSource) {
        self.database = database
        self.paths = paths
        self.appVersion = appVersion
        self.time = time
    }

    /// - Parameter ollamaURL: the server in use; one on another machine is the user's to install and run.
    public func run(settings: AppSettings, config: PipelineConfig, lifecycle: OllamaLifecycle, models: ModelManager,
                    ollamaURL: URL) async -> DoctorReport {
        var checks: [DoctorCheck] = []
        let fm = FileManager.default
        func add(_ name: String, _ ok: Bool, _ detail: String, warnOnly: Bool = false) {
            checks.append(DoctorCheck(name: name, status: ok ? .ok : (warnOnly ? .warning : .error), detail: detail))
        }
        var isDir: ObjCBool = false
        let archiveExists = fm.fileExists(atPath: settings.archiveURL.path, isDirectory: &isDir) && isDir.boolValue
        add("Archive folder", archiveExists && fm.isWritableFile(atPath: settings.archiveURL.path), settings.archiveURL.path)
        add("Incoming folder", fm.fileExists(atPath: settings.incomingURL.path), settings.incomingURL.path, warnOnly: true)
        let nested = settings.archiveURL.path.hasPrefix(settings.incomingURL.path + "/")
        add("Incoming is not above the archive", !nested, nested ? "The archive is inside Incoming" : "ok")
        do {
            let fts = try await database.reader.read { db in try Bool.fetchOne(db, sql: "SELECT sqlite_compileoption_used('ENABLE_FTS5')") }
            add("SQLite FTS5", fts ?? false, fts == true ? "available" : "missing")
            let documents = try await database.reader.read { db in try DocumentRecord.fetchCount(db) }
            add("Database", true, Format.count(documents, "document"))
        } catch {
            add("Database", false, error.localizedDescription)
        }
        let local = OllamaEndpoint.isThisMac(ollamaURL)
        if local {
            let install = await lifecycle.discover()
            add("Ollama installed", install.binaryURL != nil || install.appURL != nil,
                install.appURL?.path ?? install.binaryURL?.path ?? "not found")
        }
        let state = await lifecycle.check()
        add("Ollama running", state.isReady,
            local ? state.summary : "\(state.summary) at \(ollamaURL.absoluteString), a machine on the local network", warnOnly: true)
        var modelStatus: [ModelStatus] = []
        if state.isReady, let resolved = try? config.models(for: settings.models) {
            modelStatus = (try? await models.status(for: resolved)) ?? []
            for m in modelStatus {
                add("Model \(m.role.rawValue)", m.installed, m.installed ? m.name : "\(m.name) is not installed", warnOnly: m.role == .fast)
            }
        }
        if local, let values = try? fm.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            let gb = Double(free) / Units.bytesPerGigabyte
            add("Free disk", gb > config.ollama.requiredFreeDiskGBAfterPull, String(format: "%.1f GB", gb), warnOnly: true)
        }
        let violations = NetworkGuardProtocol.violations
        add("Network stays local", violations.isEmpty,
            violations.isEmpty ? "no blocked requests; Ollama at \(ollamaURL.absoluteString)" : violations.joined(separator: ", "))
        let report = DoctorReport(generatedAt: time.now(), appVersion: appVersion,
                                  macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                                  paths: ["support": paths.supportDirectory.path, "logs": paths.logsDirectory.path,
                                          "index": (try? paths.indexURL(for: settings.archiveURL))?.path ?? "none yet", "settings": paths.settingsURL.path],
                                  checks: checks, models: modelStatus, ollama: state.summary)
        for c in checks where c.status != .ok {
            Log.log(c.status == .error ? .error : .warning, .app, "Doctor: \(c.name)", ["detail": c.detail])
        }
        return report
    }
}

extension Log {
    public static func log(_ level: LogLevel, _ cat: LogCategory, _ msg: String, _ fields: [String: String] = [:]) {
        shared.log(level, cat, msg, fields)
    }
}
