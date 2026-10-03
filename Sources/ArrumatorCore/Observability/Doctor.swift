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
    /// The archive checked, whose index `database` is.
    public let archive: URL
    public let paths: AppPaths
    public let appVersion: String
    public let time: any TimeSource
    /// What a `.local` name of the server stands for is looked up with.
    public let resolver: any HostResolving

    public init(database: AppDatabase, archive: URL, paths: AppPaths, appVersion: String, time: any TimeSource,
                resolver: any HostResolving) {
        self.database = database
        self.archive = archive
        self.paths = paths
        self.appVersion = appVersion
        self.time = time
        self.resolver = resolver
    }

    /// - Parameters:
    ///   - ollamaURL: the server in use; one on another machine is the user's to install and run.
    ///   - unreadableRecords: the archive's record files that cannot be read (`ArchiveRecords.unreadableFiles`), each a
    ///     failed check, as the app neither reads nor writes them until the user corrects them.
    public func run(settings: AppSettings, config: PipelineConfig, lifecycle: OllamaLifecycle, models: ModelManager,
                    ollamaURL: URL, unreadableRecords: [UnreadableRecordFile]) async -> DoctorReport {
        var checks: [DoctorCheck] = []
        let fm = FileManager.default
        func add(_ name: String, _ ok: Bool, _ detail: String, warnOnly: Bool = false) {
            checks.append(DoctorCheck(name: name, status: ok ? .ok : (warnOnly ? .warning : .error), detail: detail))
        }
        var isDir: ObjCBool = false
        let archiveExists = fm.fileExists(atPath: archive.path, isDirectory: &isDir) && isDir.boolValue
        add("Archive folder", archiveExists && fm.isWritableFile(atPath: archive.path), archive.path)
        // Another folder than the one the index was kept for, put in its place: the app takes it as the archive at its next start.
        if let kept = try? await database.meta(ArchiveWatcher.folderKey), let now = try? ArchiveDisk.disk.identity(of: archive)?.stored, kept != now {
            add("Archive folder replaced", false, "another folder than the one the index was kept for; it is taken as the archive when Arrumator starts", warnOnly: true)
        }
        add("Incoming folder", fm.fileExists(atPath: settings.incomingURL.path), settings.incomingURL.path, warnOnly: true)
        do {
            let fts = try await database.reader.read { db in try Bool.fetchOne(db, sql: "SELECT sqlite_compileoption_used('ENABLE_FTS5')") }
            add("SQLite FTS5", fts ?? false, fts == true ? "available" : "missing")
            let documents = try await database.reader.read { db in try DocumentRecord.fetchCount(db) }
            add("Database", true, Format.count(documents, "document"))
        } catch {
            add("Database", false, error.localizedDescription)
        }
        if unreadableRecords.isEmpty { add("Record files", true, "none found that cannot be read") }
        for file in unreadableRecords { add("Record file", false, "\(file.path): \(file.reason)") }
        await checkTwoPlaces(add)
        let local = OllamaEndpoint.isThisMac(ollamaURL)
        await checkAddress(ollamaURL, within: config.ollama.timeouts.resolve, add)
        if local {
            let install = await lifecycle.discover()
            add("Ollama installed", install.binaryURL != nil || install.appURL != nil,
                install.appURL?.path ?? install.binaryURL?.path ?? "not found")
        }
        let state = await lifecycle.check()
        add("Ollama running", state.isReady,
            local ? state.summary : "\(state.summary) at \(ollamaURL.absoluteString), a machine on the local network", warnOnly: true)
        var modelStatus: [ModelStatus] = []
        if state.isReady {
            do {
                let profile = try settings.modelProfile()
                do {
                    modelStatus = try await models.status(for: profile)
                } catch {
                    // Which models the server has is not known, so none of them is known to be there.
                    add("Models", false, "Ollama did not list its models: \(error.localizedDescription)")
                }
                for m in modelStatus {
                    let detail = m.remoteHost.map { "\(m.name) runs at \($0), beyond this Mac and the local network, and is never read with" }
                        ?? (m.installed ? m.name : "\(m.name) is not installed")
                    add("Model \(m.role.rawValue)", m.installed && m.remoteHost == nil, detail)
                }
            } catch {
                add("Model profile", false, error.localizedDescription)
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
                                          "index": paths.indexURL(for: archive).path, "settings": paths.settingsURL.path],
                                  checks: checks, models: modelStatus, ollama: state.summary)
        for c in checks where c.status != .ok {
            Log.log(c.status == .error ? .error : .warning, .app, "A doctor check did not pass", ["check": c.name, "detail": c.detail])
        }
        return report
    }
}

extension Doctor {
    /// How the server at `url` is reached: a warning for each caution (`OllamaEndpoint.Caution`), and, for a `.local`
    /// name, what it stands for now: an error when that is beyond the local network, which no request is then sent to,
    /// and a warning when it does not resolve, as it is then trusted by its name alone.
    /// Warns of the documents in more than one place whose copies are still there (`DocumentInTwoPlaces`), by the folders
    /// they are in: the report is shared with a bug report, and a folder is named there, as a record file's path is,
    /// never a document's file.
    func checkTwoPlaces(_ add: (String, Bool, String, Bool) -> Void) async {
        do {
            var byFolders: [[String]: Int] = [:]
            for (uid, place) in try await database.reader.read({ db in try TwoPlaces.all(db) }) {
                let places = place.paths(stillCarrying: uid)
                guard places.count > 1 else { continue }
                byFolders[Set(places.map { ($0 as NSString).deletingLastPathComponent }).sorted(), default: 0] += 1
            }
            for (folders, count) in byFolders.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
                add("Document in two places", false, "\(Format.count(count, "document")) in each of \(folders.joined(separator: " and ")), "
                    + "and nothing tells which is the copy: remove the copy", true)
            }
        } catch {
            add("Documents in two places", false, error.localizedDescription, true)
        }
    }

    func checkAddress(_ url: URL, within seconds: Double, _ add: (String, Bool, String, Bool) -> Void) async {
        for caution in OllamaEndpoint.cautions(for: url) {
            switch caution {
            case .unencrypted: add("Ollama connection", false, caution.summary, true)
            case let .byName(host):
                do {
                    let addresses = try await OllamaEndpoint.resolved(url, by: resolver, within: seconds) ?? []
                    add("Ollama address", !addresses.isEmpty,
                        addresses.isEmpty ? "\(host) does not resolve now; \(caution.summary)"
                            : "\(host) is \(addresses.joined(separator: ", ")), on the local network", true)
                } catch {
                    add("Ollama address", false, error.localizedDescription, false)
                }
            }
        }
    }
}

extension Log {
    public static func log(_ level: LogLevel, _ cat: LogCategory, _ msg: StaticString, _ fields: [String: String] = [:]) {
        shared.log(level, cat, msg, fields)
    }
}
