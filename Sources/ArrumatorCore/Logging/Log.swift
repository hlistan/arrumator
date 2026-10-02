import Foundation
import os
import Synchronization

public enum LogCategory: String, Sendable, Codable, CaseIterable {
    case app, watch, ingest, extract, classify, fileops, ollama, index, search, ui, cli, db, power
}

public struct LogEntry: Sendable, Codable, Identifiable, Hashable {
    public var id: UInt64
    public var ts: Date
    public var level: LogLevel
    public var cat: LogCategory
    public var msg: String
    public var fields: [String: String]

    public var job: String? { fields["job"] }
    public var doc: String? { fields["doc"] }
    public var trace: String? { fields["trace"] }

    /// The fields a diagnostics export keeps of a line without the user's consent (`DiagnosticsExporter`): identifiers
    /// of the app's own records, counts of them, stages, durations, models, versions and the like, none of which ever
    /// comes from a document. Every other field, a path, a file name, tags, an error's description, may hold what a
    /// document says or is called, and stays out. It is an allow-list: a field added at a call site stays out of the
    /// export until it is shown here to come from no document. The unified log keeps a line the same way, its message
    /// public and its fields private (`Log.log`), and a message is a `StaticString`, so it is always a constant.
    public static let shareableFields: Set<String> = [
        "job", "doc", "trace", "task", "turn", "attempt", "stage", "event", "check", "action", "endpoint", "model", "engine",
        "version", "type", "ms", "waited", "delay", "documents", "queued", "missing", "adopted", "files", "events", "count",
        "steps", "tasks", "questions", "sources", "rows", "dim", "fts", "semantic", "pid", "status", "resume", "window",
        "visible", "x", "width", "screen",
    ]
}

/// Structured logging: os_log + daily-rotated JSONL files + in-memory ring buffer for the Logs tab.
public final class Log: Sendable {
    public static let shared = Log()

    private struct State {
        var directory: URL?
        var handle: FileHandle?
        var currentDay: String = ""
        var buffer: [LogEntry] = []
        var nextID: UInt64 = 1
        var minLevel: LogLevel = .info
        var subscribers: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
        var echoToStderr = false
        var bufferLimit = 1
    }

    private let state = Mutex(State())
    private static let subsystem = "dev.arrumator"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        return e
    }()

    /// Enables on-disk JSONL logging into `directory` (one file per day).
    public func configure(directory: URL, minLevel: LogLevel, config: LoggingConfig, echoToStderr: Bool) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        state.withLock {
            $0.bufferLimit = config.bufferLimit
            $0.directory = directory
            $0.minLevel = minLevel
            $0.echoToStderr = echoToStderr
            try? $0.handle?.close()
            $0.handle = nil
            $0.currentDay = ""
        }
    }

    public func setMinLevel(_ level: LogLevel) { state.withLock { $0.minLevel = level } }

    /// Logs `message` with `fields`. The message is a `StaticString`, so the compiler refuses one built at run time: it is
    /// public in the unified log and kept whole by a diagnostics export, while what varies goes in the fields, which are
    /// private there and kept by allow-list (`LogEntry.shareableFields`).
    public func log(_ level: LogLevel, _ cat: LogCategory, _ message: StaticString, _ fields: [String: String] = [:]) {
        let msg = message.description
        let logger = Logger(subsystem: Self.subsystem, category: cat.rawValue)
        let fieldText = fields.isEmpty ? "" : " " + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        switch level {
        case .error: logger.error("\(msg, privacy: .public)\(fieldText, privacy: .private)")
        case .warning: logger.warning("\(msg, privacy: .public)\(fieldText, privacy: .private)")
        case .info: logger.info("\(msg, privacy: .public)\(fieldText, privacy: .private)")
        case .debug, .trace: logger.debug("\(msg, privacy: .public)\(fieldText, privacy: .private)")
        }
        let encoder = lineEncoder
        state.withLock { s in
            guard level <= s.minLevel else { return }
            let entry = LogEntry(id: s.nextID, ts: Date(), level: level, cat: cat, msg: msg, fields: fields)
            s.nextID += 1
            s.buffer.append(entry)
            if s.buffer.count > s.bufferLimit { s.buffer.removeFirst(s.buffer.count - s.bufferLimit) }
            for c in s.subscribers.values { c.yield(entry) }
            if s.echoToStderr {
                FileHandle.standardError.write(Data("[\(level.rawValue)] \(cat.rawValue): \(msg)\(fieldText)\n".utf8))
            }
            guard let dir = s.directory else { return }
            let day = Log.dayFormatter.string(from: entry.ts)
            if day != s.currentDay || s.handle == nil {
                try? s.handle?.close()
                let url = dir.appendingPathComponent("arrumator-\(day).jsonl")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                s.handle = try? FileHandle(forWritingTo: url)
                _ = try? s.handle?.seekToEnd()
                s.currentDay = day
            }
            if var data = try? encoder.encode(entry) {
                data.append(0x0A)
                try? s.handle?.write(contentsOf: data)
            }
        }
    }

    public func recent(limit: Int? = nil) -> [LogEntry] {
        state.withLock { s in limit.map { Array(s.buffer.suffix($0)) } ?? s.buffer }
    }

    public func stream() -> AsyncStream<LogEntry> {
        let id = UUID()
        let limit = state.withLock { $0.bufferLimit }
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream(bufferingPolicy: .bufferingNewest(limit))
        state.withLock { $0.subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    public var logDirectory: URL? { state.withLock { $0.directory } }

    /// Deletes JSONL files older than `days` before `now` or beyond `maxBytes` total (oldest first).
    public func prune(_ config: LoggingConfig, now: Date) {
        let days = config.keepDays
        let maxBytes = config.maxBytes
        guard let dir = logDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                .filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * Units.secondsPerDay)
        var total: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            total += Int64(values?.fileSize ?? 0)
            // A file whose date cannot be read is kept unless the size limit says otherwise.
            if values?.contentModificationDate.map({ $0 < cutoff }) == true || total > maxBytes {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: Convenience

    public static func error(_ cat: LogCategory, _ msg: StaticString, _ fields: [String: String] = [:]) { shared.log(.error, cat, msg, fields) }
    public static func warning(_ cat: LogCategory, _ msg: StaticString, _ fields: [String: String] = [:]) { shared.log(.warning, cat, msg, fields) }
    public static func info(_ cat: LogCategory, _ msg: StaticString, _ fields: [String: String] = [:]) { shared.log(.info, cat, msg, fields) }
    public static func debug(_ cat: LogCategory, _ msg: StaticString, _ fields: [String: String] = [:]) { shared.log(.debug, cat, msg, fields) }
    public static func trace(_ cat: LogCategory, _ msg: StaticString, _ fields: [String: String] = [:]) { shared.log(.trace, cat, msg, fields) }
}
