@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// The settings as the app and `arrumatorcli` keep them in one file: Incoming and the archive two folders, neither inside
/// the other, however they are given; a change another process made kept, not saved over; and a change saved only with
/// its record in History (AGENTS.md §4.4).
@Suite struct SettingsStoreTests {
    /// Two folders the settings could name, laid out under a scratch root: the first is Incoming, the second the archive.
    enum Folders: String, CaseIterable, Sendable {
        case archiveInsideIncoming, incomingInsideArchive, oneFolder, archiveInsideIncomingReachedThroughALink,
             archiveInsideIncomingSpelledInAnotherCase, archiveToBeMadeInsideIncomingReachedThroughALink, incomingToBeMadeInsideTheArchiveReachedThroughALink
        /// Controls: two folders side by side, and one whose name only begins with the other's.
        case sideBySide, oneNamedLikeTheStartOfTheOther

        var refused: Bool { ![.sideBySide, .oneNamedLikeTheStartOfTheOther].contains(self) }

        /// The paths of Incoming and the archive under `root`, with the folders and links that make them what they are.
        func paths(under root: URL) throws -> (incoming: String, archive: String) {
            let fm = FileManager.default
            let docs = root.appendingPathComponent("Docs", isDirectory: true)
            try fm.createDirectory(at: docs.appendingPathComponent("Archive"), withIntermediateDirectories: true)
            let link = root.appendingPathComponent("Link")
            try fm.createSymbolicLink(at: link, withDestinationURL: docs)
            switch self {
            case .archiveInsideIncoming: return (docs.path, docs.appendingPathComponent("Archive").path)
            case .incomingInsideArchive: return (docs.appendingPathComponent("Archive/Incoming").path, docs.appendingPathComponent("Archive").path)
            case .oneFolder: return (docs.path, docs.path + "/")
            case .archiveInsideIncomingReachedThroughALink: return (link.path, docs.appendingPathComponent("Archive").path)
            case .archiveInsideIncomingSpelledInAnotherCase:
                return (root.appendingPathComponent("DOCS").path, docs.appendingPathComponent("Archive").path)
            case .archiveToBeMadeInsideIncomingReachedThroughALink:
                return (docs.path, link.appendingPathComponent("Not made yet/Archive").path)
            case .incomingToBeMadeInsideTheArchiveReachedThroughALink:
                return (link.appendingPathComponent("Archive/Incoming").path, docs.appendingPathComponent("Archive").path)
            case .sideBySide: return (root.appendingPathComponent("Incoming").path, docs.appendingPathComponent("Archive").path)
            case .oneNamedLikeTheStartOfTheOther: return (docs.path, root.appendingPathComponent("Docs Archive").path)
            }
        }
    }

    /// Whether `error` is the store's refusal of the settings, naming both folders as written.
    private func namesBoth(_ error: any Error, _ incoming: String, _ archive: String) -> Bool {
        guard let refused = ConfigRefusal(error) else { return false }
        let (name, underlying) = (refused.name, refused.underlying)
        // A folder reached through a link is named with where it leads; one in a temporary folder is not named twice.
        return name == AppSettings.configurationName && underlying.contains("incomingPath “\(incoming)”")
            && underlying.components(separatedBy: "“/private").count <= 2
            && underlying.contains("archivePath “\(archive)”") && underlying.contains("neither inside the other")
    }

    @Test(arguments: Folders.allCases)
    func incomingAndTheArchiveAreTwoFoldersNeitherInsideTheOther(_ folders: Folders) async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let (incoming, archive) = try folders.paths(under: env.root)
        let file = try Data(contentsOf: env.paths.settingsURL)
        let actions = SettingsActions(store: env.settings, history: HistoryStore(database: env.database, time: env.time))
        guard folders.refused else {
            try await actions.change {
                $0.incomingPath = incoming
                $0.archivePath = archive
            }
            #expect(try await SettingsStore.opened(paths: env.paths).current.incomingPath == incoming, "\(folders): two folders apart are taken and saved")
            return
        }
        await #expect("\(folders): the change is refused, naming both folders, from the app and the command line alike") {
            try await actions.change {
                $0.incomingPath = incoming
                $0.archivePath = archive
            }
        } throws: { namesBoth($0, incoming, archive) }
        #expect(try Data(contentsOf: env.paths.settingsURL) == file, "\(folders): and nothing is saved")
        await #expect("\(folders): a switch of archives meets the same rule before it makes anything") {
            try await env.settings.checkSaving {
                $0.incomingPath = incoming
                $0.archivePath = archive
            }
        } throws: { namesBoth($0, incoming, archive) }
        let written = try JSON.encoder.encode(["incomingPath": incoming, "archivePath": archive])
        try written.write(to: env.paths.settingsURL)
        #expect("\(folders): and settings written by hand stop the app, naming both folders") {
            try SettingsStore.opened(paths: env.paths)
        } throws: { namesBoth($0, incoming, archive) }
        #expect(try Data(contentsOf: env.paths.settingsURL) == written, "\(folders): the file is left as the user wrote it")
    }

    @Test func aFolderOrProgramIsNamedByAFullPath() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let refused: [(String, @Sendable (inout AppSettings) -> Void)] = [
            ("incomingPath “”", { $0.incomingPath = "" }),
            ("archivePath “Archive”", { $0.archivePath = "Archive" }),
            ("ollamaBinaryPath “ollama”", { $0.ollamaBinaryPath = "ollama" }),
            ("traceRawRetentionDays must be from 1 to 3650 days", { $0.traceRawRetentionDays = 0 }),
            ("traceRawRetentionDays must be from 1 to 3650 days", { $0.traceRawRetentionDays = 3_651 }),
        ]
        for (problem, change) in refused {
            await #expect("\(problem): a folder found from wherever a process runs, or a retention the app does not offer, is refused") {
                try await env.settings.update(change)
            } throws: { error in
                guard let underlying = ConfigRefusal(error)?.underlying else { return false }
                return underlying.hasPrefix(problem)
            }
        }
        let home = try await env.settings.update {
            $0.incomingPath = "~/Incoming for a test"
            $0.ollamaBinaryPath = "~/bin/ollama"
            $0.traceRawRetentionDays = AppSettings.traceRawRetentionDaysRange.lowerBound
        }
        #expect(home.incomingURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path), "a path from ~ is a full path")
    }

    /// The app and `arrumatorcli` each keep a store over the one file, as they do while the app runs.
    @Test(.timeLimit(.minutes(1))) func aChangeMadeByAnotherProcessIsKeptAndHeardOf() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let app = env.settings
        let heard = await Collected.reading(await app.changes())
        try await SettingsStore.opened(paths: env.paths).update { $0.logLevel = .debug }
        try await app.update { $0.renameFiles = false }
        let saved = try await SettingsStore.opened(paths: env.paths).current
        #expect(saved.logLevel == .debug && !saved.renameFiles,
                "the app's change is saved over the file as it is now, keeping the command's: \(saved.logLevel), \(saved.renameFiles)")
        #expect(await app.current.logLevel == .debug, "and the app goes on with the command's change too")
        try #require(await Patience.until { await heard.all.count >= 2 }, "what the app follows hears of both changes")
        let (found, made) = (await heard.all[0], await heard.all[1])
        #expect(found.logLevel == .debug && found.renameFiles, "what the app follows hears of the change found in the file first")
        #expect(made.logLevel == .debug && !made.renameFiles, "and then of its own")
        await heard.stop()
    }

    /// A profile added or filing paused with `arrumatorcli` while the app runs is heard of when it is saved, not at the
    /// app's next change of its own (QA 2026-10-05, SET-4; AGENTS.md §4.6).
    @Test(.timeLimit(.minutes(1))) func aChangeAnotherProcessSavesIsHeardOfAtOnce() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let app = env.settings
        let heard = await Collected.reading(await app.changes())
        try await SettingsStore.opened(paths: env.paths).update { $0.paused = true }
        #expect(await Patience.until { await heard.all.last?.paused == true },
                "what the app follows hears of the command's change as it is saved, with no change of the app's own")
        #expect(await app.current.paused, "and the app goes on with it")
        await heard.stop()
    }

    @Test func aFileThatCannotBeReadIsNeverSavedOver() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let edited = Data(#"{"renameFiles": false, "duplicateAction": "leaveInIncoming"}"#.utf8)
        try edited.write(to: env.paths.settingsURL)
        await #expect("a change is refused, naming the key the app does not know") {
            try await env.settings.update { $0.logLevel = .debug }
        } throws: { error in
            guard let underlying = ConfigRefusal(error)?.underlying else { return false }
            return underlying == ConfigLoader.unknownKey("duplicateAction")
        }
        #expect(try Data(contentsOf: env.paths.settingsURL) == edited, "and the file is left as the user wrote it")
    }

    @Test func aChangeWhoseRecordIsRefusedIsNotSaved() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let history = HistoryStore(database: env.database, time: env.time)
        let actions = SettingsActions(store: env.settings, history: history)
        let file = try Data(contentsOf: env.paths.settingsURL)
        // History refuses every event, as an index that cannot be written does.
        try await env.database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_events BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        await #expect(throws: DatabaseError.self, "a change History cannot record fails") {
            try await actions.change { $0.renameFiles = false }
        }
        #expect(try Data(contentsOf: env.paths.settingsURL) == file, "so the setting is not saved")
        #expect(await env.settings.current.renameFiles, "and the settings in force are as they were")
    }

    @Test(.folderModesKeepOut) func aChangeWhoseSettingsCannotBeSavedIsNotRecorded() async throws {
        let recording = try await TestEnvironment.make()
        defer { recording.cleanup() }
        let recorded = SettingsActions(store: recording.settings, history: HistoryStore(database: recording.database, time: recording.time))
        let folder = recording.paths.supportDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        await #expect(throws: CocoaError.self, "a change whose settings cannot be written fails") {
            try await recorded.change { $0.renameFiles = false }
        }
        #expect(try await recorded.history.events(limit: 10).isEmpty, "and records nothing, as it was not made")
        #expect(await recording.settings.current.renameFiles, "and the settings in force are as they were")
    }

    /// Before the archive is opened, as during onboarding, the index holds nothing of it yet: a change is made, and its
    /// event held until the index holds the archive, then recorded once (`HistoryStore.insert`).
    @Test func aChangeMadeBeforeTheArchiveIsReadIsSavedAndRecordedOnceTheIndexHoldsIt() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        let (database, _) = try AppDatabase.open(at: env.root.appendingPathComponent("Indexes/archive.sqlite"), config: env.config.database,
                                                 setAsideSuffix: env.config.records.setAsideSuffix, time: env.time) { false }
        let history = HistoryStore(database: database, time: env.time)
        try await SettingsActions(store: env.settings, history: history).change(summary: "Files keep their names") { $0.renameFiles = false }
        #expect(try await SettingsStore.opened(paths: env.paths).current.renameFiles == false, "the change is saved")
        #expect(try await history.events(limit: 10).isEmpty, "its event held, not in the history the rebuild replaces")
        #expect(try await env.records(index: database).rebuildIfPending() == nil, "the archive holds nothing to rebuild from")
        #expect(try await history.events(limit: 10, kinds: [.settingsChanged]).map(\.summary) == ["Files keep their names"],
                "so the index is complete, and records the change once")
    }

    /// A record that fails after the settings were saved, as when its transaction cannot be committed: the file is put
    /// back as it was, or taken away when there was none, and the settings in force are as before.
    @Test(arguments: [true, false])
    func aChangeWhoseRecordFailsOnceItIsSavedIsPutBack(_ fileWasThere: Bool) async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        if !fileWasThere { try FileManager.default.removeItem(at: env.paths.settingsURL) }
        let store = try SettingsStore.opened(paths: env.paths)
        let (before, file) = (await store.current, try? Data(contentsOf: env.paths.settingsURL))
        let heard = await Collected.reading(await store.changes())
        let reading = Reading()
        await #expect(throws: CancellationError.self, "the change fails as its record does") {
            try await store.change({ $0.renameFiles = false }, recording: { _, save in
                try save()
                // A change another store said it saved is heard of now, while the file holds this one's, not recorded yet:
                // it is read once the change is over, under the lock it holds (the reviews of the fix of QA 2026-10-05,
                // SET-4).
                await reading.begin { await store.readOthersChange() }
                try #require(await Patience.until { await store.waitsToReadAnotherChange }, "the read waits for the change to be over")
                throw CancellationError()
            })
        }
        await reading.end()
        #expect((try? Data(contentsOf: env.paths.settingsURL)) == file,
                "the file is as it was\(fileWasThere ? "" : ": none"), so no change is in force without its record")
        #expect(await store.current == before, "and the settings in force are as before")
        let published = await heard.all
        let neverInForce = published.allSatisfy { $0.renameFiles }
        #expect(neverInForce, "and what was put back was never published as in force: \(published)")
        await heard.stop()
    }

    /// The app hears of a change `arrumatorcli` is making while it is saved and not yet recorded, as a late notification
    /// of an earlier one makes it read then: it reads the file once the change is over, so a change the command then
    /// puts back, as its record failed, is never in force in the app (the second review of the fix of QA 2026-10-05,
    /// SET-4).
    @Test(.timeLimit(.minutes(1))) func aChangeAnotherProcessPutsBackIsNeverInForceHere() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let (app, cli) = (try SettingsStore.opened(paths: env.paths), try SettingsStore.opened(paths: env.paths))
        let before = await app.current
        let heard = await Collected.reading(await app.changes())
        let reading = Reading()
        await #expect(throws: CancellationError.self, "the command's change fails as its record does") {
            try await cli.change({ $0.paused = true }, recording: { _, save in
                try save()
                await reading.begin { await app.readOthersChange() }
                try #require(await Patience.until {
                    let (waiting, current) = (await app.waitsToReadAnotherChange, await app.current)
                    return waiting || current.paused
                }, "the app reads, or waits to read, while the command's change is saved and not recorded")
                throw CancellationError()
            })
        }
        await reading.end()
        let published = await heard.all
        let neverInForce = published.allSatisfy { !$0.paused }
        let now = await app.current
        #expect(now == before && neverInForce, "the app goes on as before, and never published the change: \(published)")
        await heard.stop()
    }

    /// A reading begun in a change's record, to be waited for once the change is over.
    private actor Reading {
        private var task: Task<Void, Never>?
        func begin(_ work: @escaping @Sendable () async -> Void) { task = Task { await work() } }
        func end() async { await task?.value }
    }

    /// The app and `arrumatorcli` each change the settings, one of them while its change waits to be recorded: the other
    /// waits for it, rather than read the file before it is saved and save over it.
    @Test(.timeLimit(.minutes(1))) func twoProcessesChangeTheSettingsOneAfterTheOther() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let (app, cli) = (env.settings, try SettingsStore.opened(paths: env.paths))
        let (recording, letGo) = (Signal(), OneShot<Void>())
        let first = Task {
            try await app.change({ $0.renameFiles = false }, recording: { _, save in
                recording.fire()
                await letGo.wait()
                try save()
            })
        }
        #expect(await Patience.until { recording.fired }, "the app's change is being recorded")
        let second = Task { try await cli.update { $0.logLevel = .debug } }
        #expect(await Patience.until { await cli.waitsForAnotherChange }, "the command's change waits for the app's")
        letGo.fire(())
        _ = try await (first.value, second.value)
        let saved = try await SettingsStore.opened(paths: env.paths).current
        #expect(!saved.renameFiles && saved.logLevel == .debug, "neither change is saved over the other: \(saved.renameFiles), \(saved.logLevel)")
    }

    @Test func changesAreMadeOneAtATimeFromReadingTheFileToSavingIt() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let (recording, letGo) = (Signal(), OneShot<Void>())
        let first = Task {
            try await env.settings.change({ $0.renameFiles = false }, recording: { _, save in
                recording.fire()
                await letGo.wait()
                try save()
            })
        }
        #expect(await Patience.until { recording.fired }, "the first change is being recorded")
        let second = Task { try await env.settings.update { $0.logLevel = .debug } }
        #expect(await Patience.until { await env.settings.changesWaiting == 1 }, "a second change waits for its turn")
        letGo.fire(())
        _ = try await (first.value, second.value)
        let saved = try await SettingsStore.opened(paths: env.paths).current
        #expect(!saved.renameFiles && saved.logLevel == .debug, "so neither is saved over the other")
    }
}
