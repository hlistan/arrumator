@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The app's log files, one a day (`Log`): kept within their days and bytes, and never lost while they are written.
@Suite struct LogTests {
    /// A day long before any test runs, whose file is past every limit of days.
    static let longAgo = "2000-01-01"

    @Test func pruningKeepsTheFileBeingWrittenWhateverItsSizeAndDeletesTheOldOnes() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let folder = env.paths.logsDirectory
        let log = Log()
        log.configure(directory: folder, minLevel: .info, config: env.config.logging, echoToStderr: false)
        let old = folder.appendingPathComponent(Log.fileName(day: Self.longAgo))
        try Data("{}\n".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        log.log(.info, .app, "Before pruning")
        var tight = env.config.logging
        tight.maxBytes = 0
        log.prune(tight, now: Date())
        log.log(.info, .app, "After pruning")
        #expect(!FileManager.default.fileExists(atPath: old.path), "a file past its days and the size limit is deleted")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        let written = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(files.count == 1 && written.contains("Before pruning") && written.contains("After pruning"),
                "the file being written stays, though alone it is over the limit, so no line goes into a file no longer there: \(files)")
    }

    /// The app and a command log into one day's file at once (QA run of 10 October 2026: a line of the app's written over
    /// by a command's, leaving a fragment and a blank line). Each writes its lines at the file's end as it is then.
    @Test func twoProcessesLoggingIntoOneDaysFileEachKeepEveryLineWhole() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let folder = env.paths.logsDirectory
        // Two logs, as two processes have, each with a handle of its own on the day's file.
        let (app, command) = (Log(), Log())
        for log in [app, command] { log.configure(directory: folder, minLevel: .info, config: env.config.logging, echoToStderr: false) }
        app.log(.info, .app, "Arrumator started")
        command.log(.info, .cli, "Command started")
        app.log(.info, .ingest, "Filed")
        command.log(.info, .app, "Arrumator stopped")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        let lines = try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) }
            .filter { !$0.isEmpty }
        let messages = lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))).flatMap { ($0 as? [String: Any])?["msg"] as? String }
        }
        #expect(messages == ["Arrumator started", "Command started", "Filed", "Arrumator stopped"] && messages.count == lines.count,
                "every line of both, whole and in the order written: \(lines)")
    }
}
