@testable import ArrumatorCore
@testable import ArrumatorRuntime
import ArrumatorTesting
import Foundation
import Testing

/// The app makes an archive's folder only when the user sets an archive up: at the end of onboarding, or on a switch to
/// a folder that is not there. At any other time an archive whose folder is not there is away, as on a disk not
/// connected or a folder renamed or moved: it is said so, naming the folder, nothing is made, read, written or filed in
/// its place, and the app can still change a setting or switch to another (docs/storage.md, One index per archive).
@Suite struct ArchiveFolderTests {
    /// Expects `open` to say the archive's folder, at `folder`, is not there.
    private func expectAway(_ folder: URL, _ comment: Comment, _ open: () async throws -> Void) async {
        await #expect(comment) {
            try await open()
        } throws: { error in
            guard case let RecordsError.archiveNotThere(path) = error else { return false }
            return path == folder.path
        }
    }

    /// An archive with a document in it, opened once: its index holds the document.
    private func archiveWithADocument(_ home: RuntimeHome) async throws {
        let archive = home.folder("First")
        try home.writeList(TestRecordFiles.list(of: Self.note), in: archive)
        try Data(Self.note.utf8).write(to: archive.appendingPathComponent(Self.note))
        let first = try await home.open()
        try #require(try await first.services.documents.list(DocumentFilter(), limit: 10).count == 1, "the index holds the document")
        await first.stop()
    }

    @Test func onboardingMakesTheFolderOfTheArchiveTheUserSetsUp() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let archive = home.folder("New")
        try await SettingsStore.opened(paths: home.paths).update { $0.archivePath = archive.path }
        let runtime = try await home.bootstrap()
        #expect(!FileManager.default.fileExists(atPath: archive.path), "the app makes no folder when it starts")
        try await runtime.finishOnboarding()
        #expect(FileManager.default.fileExists(atPath: archive.path), "it makes the archive's folder as the user sets it up")
        try await runtime.openArchive()
        #expect(try await runtime.database.pendingRebuild() == nil, "a new archive, complete as it is")
        #expect(await runtime.settings.current.onboardingCompleted, "and onboarding is done")
    }

    @Test func aSwitchToAFolderThatIsNotThereMakesItForANewArchive() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let next = try await home.open().switchArchive(to: home.folder("New").path).runtime
        #expect(FileManager.default.fileExists(atPath: home.folder("New").path), "the folder the user switches to is made")
        try await next.openArchive()
        #expect(try await next.database.pendingRebuild() == nil, "for a new archive, complete as it is")
    }

    @Test func aSwitchToAnArchiveThatIsAwayIsRefusedAndMakesNoFolderWhereItWas() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await archiveWithADocument(home)
        let second = try await home.open().switchArchive(to: home.folder("Second").path).runtime
        try FileManager.default.moveItem(at: home.folder("First"), to: home.folder("Away"))
        await expectAway(home.folder("First"), "the switch back is refused before anything stops, naming the folder") {
            _ = try await second.switchArchive(to: home.folder("First").path)
        }
        #expect(await second.settings.current.archiveURL == home.folder("Second"), "the app stays on the archive it has")
        #expect(!FileManager.default.fileExists(atPath: home.folder("First").path), "and no empty archive is made in place of the one away")
    }

    @Test func anArchiveTheUserHadThatIsNotThereWhenItIsOpenedIsSaidToBeAway() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        let runtime = try await home.bootstrap()
        // Gone before onboarding opens it, as a disk taken out or a cloud folder not connected.
        try FileManager.default.removeItem(at: home.folder("First"))
        await expectAway(home.folder("First"), "what it holds is not known, so its index is not taken for an empty archive's") {
            try await runtime.openArchive()
        }
        #expect(try await runtime.database.pendingRebuild() == .unread, "the index stays to be rebuilt")
        #expect(!FileManager.default.fileExists(atPath: home.folder("First").path), "and nothing is made where the archive was")
    }

    @Test func settingsAppliedWhileTheArchiveIsAwayMakeNoFolderWhereItWas() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await archiveWithADocument(home)
        let runtime = try await home.open()
        await runtime.start()
        // The user renames the archive's folder while the app runs, and a setting is applied.
        try FileManager.default.moveItem(at: home.folder("First"), to: home.folder("Renamed"))
        await runtime.apply(await runtime.settings.current)
        #expect(!FileManager.default.fileExists(atPath: home.folder("First").path), "no empty folder is made where the archive was")
        await runtime.stop()
        #expect(!FileManager.default.fileExists(atPath: home.folder("First").path), "nor when the app stops and writes its record files")
    }

    @Test func aLaunchWhileTheArchiveIsAwayMakesNoFolderWhereItWasAndGoesOnByItselfOnceItIsBack() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try home.watchQuickly()
        try await archiveWithADocument(home)
        // The disk the archive is on is not connected when the app starts.
        try FileManager.default.moveItem(at: home.folder("First"), to: home.folder("Away"))
        let runtime = try await home.bootstrap()
        let follower = WorkFollower()
        let updates = await runtime.workUpdates()
        let following = Task { for await work in updates { await follower.add(work) } }
        defer { following.cancel() }
        #expect(!FileManager.default.fileExists(atPath: home.folder("First").path), "the app makes no new, empty archive in its place")
        let starting = Task { try await runtime.openAndStart() }
        #expect(await Patience.until { await follower.received.last == .away }, "the app is told the archive is away")
        #expect(await !runtime.tasks.isWorking, "and nothing is filed into an archive that is not there")
        try await runtime.settingsActions.change(TestSettingChange.make)
        #expect(!FileManager.default.fileExists(atPath: home.folder("First").path), "still nothing is made where it was")
        // The disk connected again: the work starts by itself, with no new launch.
        try FileManager.default.moveItem(at: home.folder("Away"), to: home.folder("First"))
        try await starting.value
        #expect(await Patience.until { await follower.received.last == .running }, "once its folder is back, the work starts by itself")
        await runtime.stop()
    }

    @Test func theArchiveGoingWhileTheAppRunsIsAwayUntilItIsBack() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try home.watchQuickly()
        try await archiveWithADocument(home)
        let runtime = try await home.open()
        let follower = WorkFollower()
        let updates = await runtime.workUpdates()
        let following = Task { for await work in updates { await follower.add(work) } }
        defer { following.cancel() }
        await runtime.start()
        try #require(await Patience.until { await follower.received.last == .running }, "the work runs")
        try FileManager.default.moveItem(at: home.folder("First"), to: home.folder("Away"))
        #expect(await Patience.until { await follower.received.last == .away }, "its folder gone, as a disk taken out, the archive is away")
        try FileManager.default.moveItem(at: home.folder("Away"), to: home.folder("First"))
        #expect(await Patience.until { await follower.received.last == .running }, "and back, the work goes on by itself")
        let documents = try await runtime.services.documents.list(DocumentFilter(), limit: 10)
        #expect(documents.map(\.status) == [.filed], "nothing in it was taken for missing")
        await runtime.stop()
    }

    @Test func aFileInIncomingWaitsUnreadWhileTheArchiveGoneDuringTheRunIsAway() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try home.watchQuickly()
        let runtime = try await home.open()
        let follower = WorkFollower()
        let updates = await runtime.workUpdates()
        let following = Task { for await work in updates { await follower.add(work) } }
        defer { following.cancel() }
        await runtime.start()
        try #require(await Patience.until { await follower.received.last == .running }, "the work runs")
        try FileManager.default.moveItem(at: home.folder("First"), to: home.folder("Away"))
        try #require(await Patience.until { await follower.received.last == .away }, "its folder gone, the archive is away")
        let bill = home.folder("Incoming").appendingPathComponent("bill.txt")
        try Data("EDP electricity".utf8).write(to: bill)
        let jobs = { try await runtime.database.reader.read { db in try JobRecord.fetchAll(db) } }
        try #require(await Patience.until { (try? await jobs().count) == 1 }, "the file is queued")
        // Queued, the file is counted and rings the worker in one step of the coordinator, so a wait seen once the count
        // is is one begun since: the worker has looked at the queue holding the file and taken nothing.
        try #require(await Patience.until {
            guard await runtime.coordinator.status.queued == 1 else { return false }
            return await runtime.coordinator.waits
        },
                     "the worker has looked at the queue holding the file, and waits")
        #expect(try await jobs().map(\.state) == [.pending], "and waits unread while the archive is away: Incoming waits")
        #expect(await runtime.coordinator.archiveAway, "as the worker is paused, so a file it has in hand is not read on either")
        try FileManager.default.moveItem(at: home.folder("Away"), to: home.folder("First"))
        #expect(await Patience.until { (try? await jobs().first?.state) != .pending }, "once it is back, the file is read")
        #expect(await !runtime.coordinator.archiveAway, "the worker going on")
        await runtime.stop()
    }

    @Test func anArchiveAwayAtLaunchIsOpenedAtOnceWhenTheUserTriesAgainOnceItIsBack() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try home.lookForTheArchiveOnlyWhenAsked()
        try await archiveWithADocument(home)
        try FileManager.default.moveItem(at: home.folder("First"), to: home.folder("Away"))
        let runtime = try await home.bootstrap()
        let follower = WorkFollower()
        let updates = await runtime.workUpdates()
        let following = Task { for await work in updates { await follower.add(work) } }
        defer { following.cancel() }
        // The start waits for the archive rather than failing, so it is followed from a task of its own.
        let starting = Task { try await runtime.openAndStart() }
        #expect(await Patience.until { await follower.received.last == .away }, "the app starts, and is told the archive is away")
        // The disk is connected again, and the user presses Try Again, which opens the archive as at launch.
        try FileManager.default.moveItem(at: home.folder("Away"), to: home.folder("First"))
        let tryingAgain = Task { try await runtime.openAndStart() }
        try #require(await Patience.until { await follower.received.last == .running },
                     "the work runs at once, not when the archive would next have been looked for")
        try await tryingAgain.value
        try await starting.value
        #expect(try await runtime.services.documents.list(DocumentFilter(), limit: 10).count == 1, "on the archive it had")
        await runtime.stop()
    }

    static let note = "note.txt"

    @Test func aNewIndexOfAnArchiveThatIsAwayIsNeitherMadeAnewNorTakenForEmpty() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        do {
            let first = try await home.open()
            try await first.services.history.record(.paused, summary: Self.inTheArchive)
            try await first.records.flush()
        }
        // A new Mac, or the app installed again, that kept the settings but not the index, while the disk is not connected.
        try FileManager.default.removeItem(at: home.paths.indexesDirectory)
        try FileManager.default.moveItem(at: home.folder("First"), to: home.folder("Away"))
        let runtime = try await home.bootstrap()
        #expect(!FileManager.default.fileExists(atPath: home.folder("First").path), "no folder is made in place of the archive")
        await expectAway(home.folder("First"), "and opening it says it is not there") { try await runtime.openArchive() }
        #expect(try await runtime.database.pendingRebuild() == .unread, "its index is not taken for an empty archive's")

        try FileManager.default.moveItem(at: home.folder("Away"), to: home.folder("First"))
        try await runtime.openArchive()
        #expect(try await runtime.services.history.events(limit: 10, kinds: [.rebuilt]).count == 1, "once it is back, it is rebuilt from")
        #expect(try await runtime.services.history.events(limit: 10, kinds: [.paused]).map(\.summary) == [Self.inTheArchive],
                "with the history it holds")
    }

    @Test func anIndexWithHistoryAndRulesButNoDocumentOfAnArchiveThatIsAwayIsNotMadeAnew() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        do {
            let first = try await home.open()
            try await first.services.history.record(.paused, summary: Self.inTheArchive)
            _ = try await first.labels.ignore(DocumentLabel(kind: .topic, value: "electricity"))
            try await first.records.flush()
        }
        try FileManager.default.moveItem(at: home.folder("First"), to: home.folder("Away"))
        let runtime = try await home.bootstrap()
        let follower = WorkFollower()
        let updates = await runtime.workUpdates()
        let following = Task { for await work in updates { await follower.add(work) } }
        defer { following.cancel() }
        let starting = Task { try await runtime.openAndStart() }
        #expect(await Patience.until { await follower.received.last == .away }, "the archive is said to be away, though its index holds no document")
        #expect(await !runtime.tasks.isWorking, "nothing is started on it, nor filed into it")
        await runtime.stop()
        await #expect(throws: CancellationError.self, "the app quitting ends the wait for it") { try await starting.value }
        #expect(!FileManager.default.fileExists(atPath: home.folder("First").path), "and nothing is made or written where it was")
    }

    @Test(.folderModesKeepOut) func anArchiveOnADiskThatIsNotConnectedIsSaidToBeAwayRatherThanFailingTheStart() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        // The mount point of disks, which the user cannot write in, with the disk the archive is on not connected.
        let volumes = home.folder("Volumes")
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        try home.setWritable(false, volumes, withFoldersInIt: false)
        defer { try? home.setWritable(true, volumes, withFoldersInIt: false) }
        let archive = volumes.appendingPathComponent("Disk/Archive", isDirectory: true).standardizedFileURL
        try await SettingsStore.opened(paths: home.paths).update { $0.archivePath = archive.path }
        let runtime = try await home.bootstrap()
        // Onboarding cannot make its folder there: no permission error is the user's to read for it.
        try await runtime.finishOnboarding()
        await expectAway(archive, "the app starts, and says the archive is away") { try await runtime.openArchive() }
        let other = try await runtime.switchArchive(to: home.folder("Other").path).runtime
        #expect(other.archive == home.folder("Other"), "and the user can switch to another")
    }

    static let inTheArchive = "In the archive"
}
