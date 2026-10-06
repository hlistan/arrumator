@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// How a command ends: what it started stops with it, Ctrl-C included, and its exit code says whether every file it was
/// given came to something.
extension CommandLineTests {
    /// Starts the command and leaves it running, as a person at a terminal runs `run`, what it prints and says on
    /// standard error written into `standardOutput` and `standardError` in its home.
    func launch(_ home: Home, _ arguments: [String], environment: [String: String] = [:]) throws -> Process {
        let command = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("arrumatorcli")
        let process = Process()
        process.executableURL = command
        process.arguments = arguments
        process.environment = home.environment.merging(environment) { _, given in given }
        let printed = home.root.appendingPathComponent(Self.standardOutput)
        FileManager.default.createFile(atPath: printed.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: printed)
        let errors = home.root.appendingPathComponent(Self.standardError)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()
        return process
    }

    /// Settings under which the command starts Ollama itself, as `ollamaManagement` spawnServe does: a stand-in, never
    /// the user's, that does not answer, and is given up on at once.
    func spawningStandIn(_ home: Home) throws -> StandInServer {
        let server = try StandInServer(in: home.root)
        let settings: [String: String] = ["incomingPath": home.root.appendingPathComponent("Incoming").path, "archivePath": home.archive.path,
                                          "ollamaURL": Home.nowhere, "ollamaManagement": OllamaManagement.spawnServe.rawValue,
                                          "ollamaBinaryPath": server.executable.path]
        try JSONEncoder().encode(settings).write(to: home.support.appendingPathComponent("settings.json"))
        let pipeline: [String: [String: Double]] = ["ollama": ["startTimeout": Self.quickStart]]
        try JSONEncoder().encode(pipeline).write(to: home.support.appendingPathComponent("pipeline.json"))
        return server
    }

    /// A corpus of one fixture, and the `eval` of it, with an Ollama that is the stand-in, never the user's, given up on
    /// after `startTimeout` seconds.
    func evaluating(_ home: Home, startTimeout: Double) throws -> (server: StandInServer, arguments: [String], environment: [String: String]) {
        let run = home.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let server = try StandInServer(in: run)
        let corpus = run.appendingPathComponent("Corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        try Data("A note".utf8).write(to: corpus.appendingPathComponent("note.txt"))
        try Data(#"{"fixtures": [{"file": "note.txt", "lang": "en", "expected": {"status": "filed", "title_contains": []}}]}"#.utf8)
            .write(to: corpus.appendingPathComponent("expected.json"))
        // The Ollama app is looked for by an identifier no app has, and `ollama serve` only where the stand-in is.
        let pipeline = run.appendingPathComponent("pipeline.json")
        try JSONSerialization.data(withJSONObject: ["ollama": ["binarySearchPaths": [server.executable.path], "startTimeout": startTimeout,
                                                               "appBundleIdentifier": Self.noSuchApp]])
            .write(to: pipeline)
        return (server, ["eval", corpus.path], ["ARRUMATOR_OLLAMA_URL": Home.nowhere, "ARRUMATOR_PIPELINE_CONFIG": pipeline.path])
    }

    /// A bundle identifier no app has.
    static let noSuchApp = "dev.arrumator.tests.no-such-app"
    /// Seconds a start may take that no test waits out.
    static let longStart = 600.0
    /// What `eval` prints before the folder it runs in.
    static let evaluatingIn = " pass(es) in "

    /// The throw-away home `eval` said it runs in, once it has said so.
    func evalHome(_ home: Home) -> URL? {
        let printed = (try? String(contentsOf: home.root.appendingPathComponent(Self.standardOutput), encoding: .utf8)) ?? ""
        guard let line = printed.split(separator: "\n").first(where: { $0.contains(Self.evaluatingIn) }),
              let range = line.range(of: Self.evaluatingIn) else { return nil }
        return URL(fileURLWithPath: String(line[range.upperBound...]), isDirectory: true)
    }

    @Test func evalRemovesItsThrowAwayHomeHoweverItEnds() async throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let failing = try evaluating(home, startTimeout: Self.quickStart)
        defer { for pid in failing.server.started { kill(pid, SIGKILL) } }
        let failed = try launch(home, failing.arguments, environment: failing.environment)
        try #require(await Patience.until { !failed.isRunning }, "eval ends, as Ollama never answers")
        let said = (try? String(contentsOf: home.root.appendingPathComponent(Self.standardError), encoding: .utf8)) ?? ""
        #expect(failed.terminationStatus != 0, "and fails, as Ollama never answered: \(said)")
        let first = try #require(evalHome(home), "eval says where it runs")
        #expect(!FileManager.default.fileExists(atPath: first.path), "its throw-away home is removed when it fails: \(first.path)")

        let waiting = try evaluating(home, startTimeout: Self.longStart)
        defer { for pid in waiting.server.started { kill(pid, SIGKILL) } }
        let interrupted = try launch(home, waiting.arguments, environment: waiting.environment)
        defer { if interrupted.isRunning { interrupted.terminate() } }
        try #require(await Patience.until { !waiting.server.started.isEmpty }, "eval starts Ollama and waits for it")
        let second = try #require(evalHome(home), "eval says where it runs")
        #expect(FileManager.default.fileExists(atPath: second.path), "in a throw-away home of its own")
        kill(interrupted.processIdentifier, SIGINT)
        try #require(await Patience.until { !interrupted.isRunning }, "Ctrl-C ends it")
        #expect(interrupted.terminationReason == .exit && interrupted.terminationStatus == 128 + SIGINT, "having stopped")
        #expect(!FileManager.default.fileExists(atPath: second.path), "its throw-away home is removed when it is interrupted too")
        #expect(await Patience.until { waiting.server.started.allSatisfy { !StandInServer.runs($0) } },
                "and the server it started is stopped: it was sent its signal, and ends as soon as it takes it")
    }

    /// Where a launched command's standard output goes, in its home.
    static let standardOutput = "stdout.txt"

    /// Where a launched command's standard error goes, in its home.
    static let standardError = "stderr.txt"

    /// Seconds a command waits for the stand-in to answer, which it never does.
    static let quickStart = 0.2

    /// What the home's log files hold.
    func logged(_ home: Home) throws -> String {
        try logFiles(home).map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    private func logFiles(_ home: Home) throws -> [URL] {
        let logs = home.support.appendingPathComponent("Logs", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }

    /// The process number of every `ollama serve` the command spawned, in order, as its log records each the moment it
    /// is spawned: also one ended before it ran a line of its own, which the stand-in's list of starts never holds.
    func spawnedServers(_ home: Home) throws -> [pid_t] {
        try logFiles(home).flatMap { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(Logged.self, from: Data($0.utf8)) }
        }
        .filter { $0.msg == OllamaLifecycle.spawnedMessage.description }.compactMap { $0.fields[Self.pidField].flatMap { pid_t($0) } }
    }

    /// Of a line of the log (`LogEntry`), what says what happened.
    private struct Logged: Decodable {
        let msg: String
        let fields: [String: String]
    }

    /// The field of `OllamaLifecycle.spawnedMessage` that holds the server's process number.
    static let pidField = "pid"

    /// Every server the command started, by its log or by the stand-in's list, has ended: each was sent its signal, and
    /// a process ends as soon as it takes it, which is not at once.
    func allEnded(_ home: Home, _ server: StandInServer) async throws -> Bool {
        let started = Set(try spawnedServers(home) + server.started)
        return await Patience.until { started.allSatisfy { !StandInServer.runs($0) } }
    }

    @Test func ctrlCStopsRunAsTheAppStopsAndEndsTheOllamaServerItStarted() async throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let server = try spawningStandIn(home)
        defer { for pid in server.started { kill(pid, SIGKILL) } }
        let running = try launch(home, ["run"])
        defer { if running.isRunning { running.terminate() } }
        try #require(await Patience.until { !server.started.isEmpty }, "run starts its work, Ollama among it, as the settings say")
        kill(running.processIdentifier, SIGINT)
        try #require(await Patience.until { !running.isRunning }, "Ctrl-C ends it")
        let said = (try? String(contentsOf: home.root.appendingPathComponent(Self.standardError), encoding: .utf8)) ?? ""
        #expect(running.terminationReason == .exit && running.terminationStatus == 128 + SIGINT,
                "having stopped, it exits as a shell reports an interrupt: \(running.terminationReason.rawValue) \(running.terminationStatus) \(said)")
        #expect(try await allEnded(home, server), "the Ollama server it started does not outlive it")
        #expect(try logged(home).contains("Arrumator stopped"), "its work was stopped as the app stops its own, not cut off")
    }

    /// With Ollama away, `run` says when the file waiting for it is tried again (the second review of the fix of QA
    /// 2026-10-05, RA-1).
    @Test func runSaysWhenAFileWaitingForOllamaIsTriedAgain() async throws {
        // The file is taken once it has stopped changing, looked at closely, so the test waits for what `run` says, not
        // for the watcher's patience, on a loaded machine.
        let home = try Home.make(pipeline: ["watcher": ["stabilityPollInterval": 0.2]])
        defer { home.cleanup() }
        let incoming = home.root.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("Fatura de julho de Maria Exemplo".utf8).write(to: incoming.appendingPathComponent("fatura.txt"))
        let running = try launch(home, ["run"])
        defer { if running.isRunning { running.terminate() } }
        let output = home.root.appendingPathComponent(Self.standardOutput)
        let said = await Patience.until {
            ((try? String(contentsOf: output, encoding: .utf8)) ?? "").contains("Waiting for Ollama: it cannot be reached, and is tried again at ")
        }
        #expect(said, "it says, as it happens, when the file is tried again: \((try? String(contentsOf: output, encoding: .utf8)) ?? "")")
        kill(running.processIdentifier, SIGINT)
        try #require(await Patience.until { !running.isRunning }, "Ctrl-C ends it")
    }

    @Test func aSecondSignalEndsTheCommandAtOnceAndTheOllamaServerItStartedWithIt() async throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let server = try spawningStandIn(home)
        defer { for pid in server.started { kill(pid, SIGKILL) } }
        let running = try launch(home, ["run"])
        defer { if running.isRunning { running.terminate() } }
        try #require(await Patience.until { !server.started.isEmpty }, "run starts Ollama, as the settings say")
        // Two signals at once: the second comes while the first one's stop has hardly begun.
        kill(running.processIdentifier, SIGINT)
        kill(running.processIdentifier, SIGTERM)
        try #require(await Patience.until { !running.isRunning }, "the command ends")
        #expect(running.terminationReason == .exit && [128 + SIGINT, 128 + SIGTERM].contains(running.terminationStatus),
                "with the status of a signal: \(running.terminationStatus)")
        #expect(try await allEnded(home, server),
                "and the server it spawned, in a process group of its own that no signal to the command reaches, ends with it")
    }

    @Test func aCommandStartsOllamaAsTheSettingsSayAndStopsItWhenItEnds() async throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let server = try spawningStandIn(home)
        defer { for pid in server.started { kill(pid, SIGKILL) } }
        let file = home.root.appendingPathComponent("note.txt")
        try Data("A note".utf8).write(to: file)
        let ingested = try run(home, ["ingest", "--json", file.path])
        #expect(ingested.status == 0, "the file waits for Ollama, which is no failure: \(ingested.stderr)")
        // Given up on after `quickStart`, the server may be stopped before it has run a line, so it is counted by the
        // command's log, never by what the stand-in wrote.
        let spawned = try spawnedServers(home)
        #expect(spawned.count == 1, "the command starts Ollama as the settings say, not only the app: \(spawned)")
        #expect(try await allEnded(home, server), "and stops it when it ends")
    }

    @Test func ingestShowsOneListAndExitsWithFailureWhenAFileCameToNothing() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let missing = ["gone.pdf", "lost.pdf"].map { home.root.appendingPathComponent($0).path }
        let previewed = try run(home, ["ingest", "--dry-run", "--json"] + missing)
        let previews = try JSONSerialization.jsonObject(with: previewed.stdout) as? [Any]
        #expect(previews?.isEmpty == true, "one JSON list for every file given, whatever came of each: \(previewed.text)")
        #expect(previewed.status == 1 && missing.allSatisfy(previewed.stderr.contains),
                "the exit code says files could not be read, and standard error says which: \(previewed.stderr)")
        let ingested = try run(home, ["ingest", "--json", missing[0]])
        #expect(try JSON.decoder.decode([DocumentRecord].self, from: ingested.stdout).isEmpty, "no document came of it: \(ingested.text)")
        #expect(ingested.status == 1 && ingested.stderr.contains(missing[0]),
                "which the exit code says, and standard error, naming the file: \(ingested.stderr)")
    }

    /// A file that fails before it becomes a document, as one that cannot be read, is named on standard error with why,
    /// and fails the command, though it is tried again later: it is never said to be queued, not read yet (the reviews of
    /// the fix of the final review of #17).
    @Test(.fileModesKeepOut) func ingestNamesAFileThatFailedWithWhy() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let locked = home.root.appendingPathComponent("locked.txt")
        try Data("Fatura de Maria Exemplo".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        let ingested = try run(home, ["ingest", "--json", locked.path])
        let queue = try DatabaseQueue(path: try index(home).path)
        defer { try? queue.close() }
        let why = try #require(try queue.read { db in
            try String.fetchOne(db, sql: "SELECT last_error FROM jobs WHERE source_path = ?", arguments: [locked.spelledOnDisk.path])
        }, "the attempt that failed is recorded with why")
        #expect(ingested.status == 1 && ingested.stderr.contains("\(locked.spelledOnDisk.path): \(why)"),
                "the file is named with why it failed: \(ingested.stderr)")
    }

    /// A file this command spends no attempt on is no failure: one that waits, as for the archive's folder when it was
    /// taken, one that failed before and waits now, each queued with why and when it is tried again, as Incoming says
    /// them, and one another process has in hand, whose time has come, with why it last stopped (the reviews of the fix
    /// of the final review of #17).
    @Test func ingestNamesAFileThatWaitsWithWhyAsNoFailure() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let files = ["waiting.txt", "earlier.txt", "held.txt"].map { home.root.appendingPathComponent($0) }
        for file in files { try Data("Fatura de Maria Exemplo \(file.lastPathComponent)".utf8).write(to: file) }
        #expect(try run(home, ["history", "--json"]).status == 0, "the archive's index is made")
        let queue = try DatabaseQueue(path: try index(home).path)
        let now = Date().timeIntervalSince1970.rounded()
        let app = try SystemProcesses().current.description
        try queue.write { db in
            for (file, attempt, due, claimedBy) in [(files[0], 0, now + 3_600, nil), (files[1], 1, now + 3_600, nil), (files[2], 1, now - 60, app)] {
                try db.execute(sql: """
                    INSERT INTO jobs (kind, source_path, state, attempt, last_error, next_run_at, created_at, updated_at, claim, claimed_by)
                    VALUES ('ingest', ?, 'hashing', ?, 'The archive is not there', ?, ?, ?, ?, ?)
                    """, arguments: [file.spelledOnDisk.path, attempt, due, now, now, claimedBy.map { _ in "in hand" }, claimedBy])
            }
        }
        try queue.close()
        let waited = try run(home, ["ingest", "--json"] + files.map(\.path))
        let later = Format.date(Date(timeIntervalSince1970: now + 3_600))
        let said = files.prefix(2).map { "\($0.spelledOnDisk.path): queued, not read yet: The archive is not there; tried again at \(later)\n" }
            + ["\(files[2].spelledOnDisk.path): queued, not read yet: The archive is not there; the app or `run` files it\n"]
        #expect(waited.status == 0 && said.allSatisfy(waited.stderr.contains),
                "a file that waits is no failure, though it failed before, and says why and until when, or who files it: \(waited.stderr)")
        let listed = try run(home, ["ingest", files[0].path])
        #expect(listed.status == 0 && listed.text.contains("queued      \(files[0].spelledOnDisk.path)\n            The archive is not there; tried again at \(later)\n"),
                "and so does the list: \(listed.text)")
    }

    /// A file another process, as the app, fails while this command runs is that process's failure, not the command's:
    /// it is queued, saying why (the review of the fix of the final review of #17).
    @Test func ingestLeavesAFileAnotherProcessFailsMeanwhileQueued() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let (mine, held) = (home.root.appendingPathComponent("mine.txt"), home.root.appendingPathComponent("held.txt"))
        for file in [mine, held] { try Data("Fatura de Maria Exemplo \(file.lastPathComponent)".utf8).write(to: file) }
        #expect(try run(home, ["history", "--json"]).status == 0, "the archive's index is made")
        let queue = try DatabaseQueue(path: try index(home).path)
        let now = Date().timeIntervalSince1970.rounded()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (kind, source_path, state, next_run_at, created_at, updated_at, claim, claimed_by)
                VALUES ('ingest', ?, 'hashing', ?, ?, ?, 'in hand', ?)
                """, arguments: [held.spelledOnDisk.path, now, now, now, try SystemProcesses().current.description])
            // The app fails its file while the command works on its own: what the app's worker writes of a failed attempt.
            // A trigger takes no arguments, so its values are written into it, quoted.
            let quoted = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
            try db.execute(sql: """
                CREATE TRIGGER app_fails AFTER UPDATE ON jobs WHEN NEW.source_path = \(quoted(mine.spelledOnDisk.path)) BEGIN
                  UPDATE jobs SET attempt = attempt + 1, last_error = 'The app could not read it', next_run_at = \(now + 3_600)
                  WHERE source_path = \(quoted(held.spelledOnDisk.path));
                END
                """)
        }
        try queue.close()
        let ingested = try run(home, ["ingest", "--json", mine.path, held.path])
        let later = Format.date(Date(timeIntervalSince1970: now + 3_600))
        #expect(ingested.status == 0 && ingested.stderr.contains("\(held.spelledOnDisk.path): queued, not read yet: The app could not read it; tried again at \(later)\n"),
                "the app's failure is no failure of the command: \(ingested.stderr)")
    }

    /// A file this command fails once it became a document, as when Ollama answers its reading with an error, fails the
    /// command, saying why, though it is tried again later (the review of the fix of the final review of #17).
    @Test func ingestFailsAFileWhoseReadingFailedHereOnceItBecameADocument() async throws {
        let ollama = try LoopbackOllama(chat: ("500 Internal Server Error", #"{"error":"model runner has unexpectedly stopped"}"#))
        defer { ollama.stop() }
        // The error is the server's, asked once: no time is spent asking it again, and the file is not due again before
        // the command ends.
        var once = LoopbackOllama.patient
        once["ollama"] = (once["ollama"] as? [String: Any] ?? [:]).merging(["retryDelays": [Int]()]) { $1 }
        once["ingest"] = ["retryDelays": [3_600]]
        let home = try Home.make(ollamaURL: ollama.address, pipeline: once)
        defer { home.cleanup() }
        let note = home.root.appendingPathComponent("note.txt")
        try Data("Fatura de Maria Exemplo".utf8).write(to: note)
        let ingested = try run(home, ["ingest", "--json", note.path])
        let queue = try DatabaseQueue(path: try index(home).path)
        defer { try? queue.close() }
        let job = try #require(try await queue.read { db -> (document: Int64?, attempt: Int, why: String?)? in
            try Row.fetchOne(db, sql: "SELECT doc_id, attempt, last_error FROM jobs WHERE source_path = ?", arguments: [note.spelledOnDisk.path])
                .map { ($0["doc_id"], $0["attempt"], $0["last_error"]) }
        }, "the file was queued")
        let why = try #require(job.why, "the failed attempt is recorded with why")
        #expect(job.document != nil && job.attempt == 1, "the file became a document, and its reading failed once")
        #expect(ingested.status == 1 && ingested.stderr.contains("\(note.spelledOnDisk.path): \(why)\n"),
                "the command fails it, saying why: \(ingested.stderr)")
    }

    /// The index of `home`'s archive, once a command has made it.
    func index(_ home: Home) throws -> URL {
        try #require(try FileManager.default.contentsOfDirectory(at: home.support.appendingPathComponent("Indexes"),
                                                                includingPropertiesForKeys: nil).first { $0.pathExtension == "sqlite" })
    }

    /// With Ollama away, the first file is read for its text and waits, and the rest are looked at, but not read: each
    /// is shown as the document it became, waiting, as no failure (QA 2026-10-05, RA-1; the reviews of its fix). A file
    /// another process has in hand before it is looked at, as the app may, is not begun: with `--json`, which lists
    /// documents alone, it is named on standard error as queued, as no failure.
    @Test func ingestWhileOllamaIsAwayShowsEveryFileAsItWaitsAndOneNotBegunAsQueued() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let notes = ["a.txt", "b.txt", "c.txt"].map { home.root.appendingPathComponent($0) }
        for (index, note) in notes.enumerated() { try Data("Fatura número \(index + 1) de Maria Exemplo".utf8).write(to: note) }
        let ingested = try run(home, ["ingest", "--json", notes[0].path, notes[1].path])
        #expect(try JSON.decoder.decode([DocumentRecord].self, from: ingested.stdout).map(\.originalFilename) == ["a.txt", "b.txt"],
                "the JSON lists the documents both files became, the second looked at but not read while the first waits for Ollama: \(ingested.text)")
        #expect(ingested.status == 0 && ingested.stderr.isEmpty, "and fails nothing: \(ingested.stderr)")
        // The app has the third file in hand, as this test's own process stands in for it, before it is looked at.
        let queue = try DatabaseQueue(path: try index(home).path)
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (kind, source_path, state, next_run_at, created_at, updated_at, claim, claimed_by)
                VALUES ('ingest', ?, 'pending', ?, ?, ?, 'in hand', ?)
                """, arguments: [notes[2].spelledOnDisk.path, now, now, now, try SystemProcesses().current.description])
        }
        try queue.close()
        let listed = try run(home, ["ingest", "--json", notes[2].path])
        #expect(listed.status == 0 && listed.stderr.contains("\(notes[2].spelledOnDisk.path): queued, not read yet: the app or `run` files it\n"),
                "a file not begun is named on standard error as queued, failing nothing: \(listed.text) \(listed.stderr)")
        let shown = try run(home, ["ingest", notes[2].path])
        #expect(shown.status == 0 && shown.text.contains("queued      \(notes[2].spelledOnDisk.path)\n            the app or `run` files it"),
                "and the list shows it so: \(shown.text)")
    }

    @Test func aDryRunOfSeveralFilesPrintsOneListNamingEachAndIngestShowsWhatCameOfTheRest() throws {
        let ollama = try LoopbackOllama()
        defer { ollama.stop() }
        let home = try Home.make(ollamaURL: ollama.address, pipeline: LoopbackOllama.patient)
        defer { home.cleanup() }
        let notes = ["one.txt", "two.txt"].map { home.root.appendingPathComponent($0) }
        for (index, note) in notes.enumerated() { try Data("Note number \(index + 1)".utf8).write(to: note) }
        let previewed = try run(home, ["ingest", "--dry-run", "--json"] + notes.map(\.path))
        let previews = try JSONSerialization.jsonObject(with: previewed.stdout) as? [[String: Any]]
        #expect(previews?.compactMap { ($0["file"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } } == notes.map(\.lastPathComponent),
                "two files read are one JSON list, an object for each, naming it: \(previewed.text) \(previewed.stderr)")
        #expect(previewed.status == 0, "and nothing failed: \(previewed.stderr)")

        let gone = home.root.appendingPathComponent("gone.txt").path
        let ingested = try run(home, ["ingest", "--json", notes[0].path, gone])
        let documents = try JSON.decoder.decode([DocumentRecord].self, from: ingested.stdout)
        #expect(documents.map(\.originalFilename) == [notes[0].lastPathComponent],
                "the file taken in is shown, as it waits for Ollama, in the one list: \(ingested.text)")
        #expect(ingested.status == 1 && ingested.stderr.contains(gone) && !ingested.stderr.contains(notes[0].path),
                "and the one that came to nothing makes the exit code a failure, naming it alone: \(ingested.stderr)")
    }

    @Test func evalRefusesFewerThanOnePass() throws {
        let home = try Home.make()
        defer { home.cleanup() }
        let result = try run(home, ["eval", home.root.path, "--passes", "0"])
        #expect(result.status == Self.usageError && result.stderr.contains("--passes"),
                "no pass over the corpus is refused as a usage error, before anything runs: \(result.status) \(result.stderr)")
    }

    /// The exit code ArgumentParser gives a command line it refuses (`EX_USAGE`).
    static let usageError: Int32 = 64
}
