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
///
/// Two locks, taken in one order, the file's and then the lines': a line is numbered and written to its file in turn, so
/// the file holds lines in the order of their numbers, while the lines in memory, which the Logs tab reads, are never
/// held behind the disk.
public final class Log: Sendable {
    public static let shared = Log()

    private struct State {
        var buffer: [LogEntry] = []
        var nextID: UInt64 = 1
        var minLevel: LogLevel = .info
        var subscribers: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
        var echoToStderr = false
        var bufferLimit = 1
    }

    /// The day's file being written, and where.
    private struct File {
        var directory: URL?
        var handle: FileHandle?
        var current: URL?
        var currentDay: String = ""
    }

    private let state = Mutex(State())
    private let file = Mutex(File())
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
        file.withLock { f in
            try? f.handle?.close()
            f = File(directory: directory)
            state.withLock {
                $0.bufferLimit = config.bufferLimit
                $0.minLevel = minLevel
                $0.echoToStderr = echoToStderr
            }
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
        file.withLock { f in
            let numbered: (entry: LogEntry, echo: Bool)? = state.withLock { s in
                guard level <= s.minLevel else { return nil }
                let entry = LogEntry(id: s.nextID, ts: Date(), level: level, cat: cat, msg: msg, fields: fields)
                s.nextID += 1
                s.buffer.append(entry)
                if s.buffer.count > s.bufferLimit { s.buffer.removeFirst(s.buffer.count - s.bufferLimit) }
                for c in s.subscribers.values { c.yield(entry) }
                return (entry, s.echoToStderr)
            }
            guard let (entry, echo) = numbered else { return }
            if echo {
                FileHandle.standardError.write(Data("[\(level.rawValue)] \(cat.rawValue): \(msg)\(fieldText)\n".utf8))
            }
            write(entry, to: &f)
        }
    }

    /// The name of the file of `day`, as `dayFormatter` writes it.
    static func fileName(day: String) -> String { "arrumator-\(day).jsonl" }

    /// Adds `entry` to the file of its day in the logs folder, opened when the day begins or the file was set aside.
    private func write(_ entry: LogEntry, to f: inout File) {
        guard let dir = f.directory else { return }
        let day = Log.dayFormatter.string(from: entry.ts)
        if day != f.currentDay || f.handle == nil {
            try? f.handle?.close()
            let url = dir.appendingPathComponent(Self.fileName(day: day))
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            f.handle = try? FileHandle(forWritingTo: url)
            _ = try? f.handle?.seekToEnd()
            f.current = url
            f.currentDay = day
        }
        if var data = try? lineEncoder.encode(entry) {
            data.append(0x0A)
            try? f.handle?.write(contentsOf: data)
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

    /// Deletes JSONL files older than `days` before `now` or beyond `maxBytes` total (oldest first), never the one being
    /// written, nor the day's, which the app or a command may be writing: their lines would go on into a file no longer
    /// there. Lines wait meanwhile, so none is written into a file as it goes.
    public func prune(_ config: LoggingConfig, now: Date) {
        let days = config.keepDays
        let maxBytes = config.maxBytes
        let today = Self.fileName(day: Self.dayFormatter.string(from: now))
        file.withLock { f in
            guard let dir = f.directory,
                  let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                    .filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            else { return }
            let cutoff = now.addingTimeInterval(-Double(days) * Units.secondsPerDay)
            var total: Int64 = 0
            for file in files {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                total += Int64(values?.fileSize ?? 0)
                guard file.lastPathComponent != today, file.lastPathComponent != f.current?.lastPathComponent else { continue }
                // A file whose date cannot be read is kept unless the size limit says otherwise.
                if values?.contentModificationDate.map({ $0 < cutoff }) == true || total > maxBytes {
                    try? FileManager.default.removeItem(at: file)
                }
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
