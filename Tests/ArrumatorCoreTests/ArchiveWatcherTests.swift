@testable import ArrumatorCore
import ArrumatorTesting
import CoreServices
import Foundation
import Synchronization
import Testing

/// What the archive watcher reports of what the user does in the archive, and when: each file once it is complete, a move
/// where it went before where it was, a folder looked through, a package as one document, the app's own changes left out,
/// everything again when events were lost, and the last event saved only once what it reported is applied. Batches of
/// events are given by the test, and each poll is the test's.
@Suite struct ArchiveWatcherTests {
    @Test func aFileThatCameIsReportedOnlyOnceItHasStoppedChanging() async throws {
        let w = try await WatchedArchive.make()
        let scan = try w.env.put("scan.pdf", text: "the first page")
        await w.watcher.handle([w.event(scan, .fileCreated, id: 1)])
        let required = w.env.config.watcher.stabilityRequiredPolls
        for _ in 1..<required { #expect(await w.watcher.poll(), "not unchanged for watcher.stabilityRequiredPolls polls yet") }
        try w.append(" and the second", to: scan)
        #expect(await w.watcher.poll(), "it changed between polls, as a file still being copied does: it waits again")
        for _ in 1..<required { #expect(await w.watcher.poll(), "unchanged since, but not yet for long enough") }
        #expect(await !w.watcher.poll(), "unchanged for watcher.stabilityRequiredPolls polls: reported, and nothing is left")
        #expect(await w.reported([.found(path: scan.path)]), "reported once, once complete, so it is never read half written")
        await w.cleanup()
    }

    @Test func aMoveIsReportedWhereTheFileWentBeforeWhereItWas() async throws {
        let w = try await WatchedArchive.make()
        let before = try w.env.put("bill.pdf", text: "an electricity bill")
        let after = w.env.archive.appendingPathComponent("Bills/bill.pdf").standardizedFileURL
        try FileManager.default.createDirectory(at: after.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: before, to: after)
        await w.watcher.handle([w.event(before, .fileRenamed, id: 1), w.event(after, .fileRenamed, id: 2)])
        await w.settle()
        #expect(await w.reported([.found(path: after.path), .gone(path: before.path)]),
                "one report, where it went first: a move is followed, never taken for a removal")
        #expect(await w.reports.batches.filter { !$0.changes.isEmpty }.count == 1, "both at once")
        await w.cleanup()
    }

    @Test func aFolderRenamedInTheArchiveIsLookedThroughAsTheWalkOfTheArchiveIs() async throws {
        let w = try await WatchedArchive.make()
        let records = w.env.config.records
        let scan = try w.env.put("Taxes 2024/scan.pdf", text: "a scan")
        let receipt = try w.env.put("Taxes 2024/Q1/receipt.pdf", text: "a receipt")
        _ = try w.env.put("Taxes 2024/\(records.documentsFileName)", text: "the folder's list of documents")
        _ = try w.env.put("Taxes 2024/.hidden.pdf", text: "hidden")
        _ = try w.env.put("Taxes 2024/.git/objects.pdf", text: "in a folder the watcher ignores")
        _ = try w.env.put("Taxes 2024/~$Contract.docx", text: "Office's lock file")
        let renamedFrom = w.env.archive.appendingPathComponent("Taxes", isDirectory: true)
        let folder = scan.deletingLastPathComponent()
        await w.watcher.handle([w.event(renamedFrom, .folderRenamed, id: 1), w.event(folder, .folderRenamed, id: 2)])
        #expect(await w.reported([.recordsChanged]), "the list of documents it holds is read at once")
        await w.settle()
        #expect(await w.reported([.recordsChanged, .found(path: receipt.path), .found(path: scan.path), .gone(path: renamedFrom.standardizedFileURL.path)]),
                "macOS reports the folder, not what is in it: each document in it is reported, at any depth, hidden files, ignored folders and lock files left out, and the folder's old name as gone")
        await w.cleanup()
    }

    @Test func aPackageIsOneDocumentReportedOnceItHasStoppedChanging() async throws {
        let w = try await WatchedArchive.make()
        let text = try w.env.put("Notes.rtfd/TXT.rtf", text: "{\\rtf1 notes}")
        let picture = try w.env.put("Notes.rtfd/picture.png", text: "png")
        let package = text.deletingLastPathComponent()
        await w.watcher.handle([w.event(text, .fileCreated, id: 1), w.event(picture, .fileCreated, id: 2), w.event(package, .folderCreated, id: 3)])
        #expect(await w.watcher.poll(), "the package waits as a file does")
        try w.append(" and more notes", to: text)
        #expect(await w.watcher.poll(), "a file in it still being written: the package is still changing")
        await w.settle()
        #expect(await w.reported([.found(path: package.path)]), "the package, once: what is inside it is part of it, never a document of its own")
        await w.cleanup()
    }

    @Test func lostEventsLookAtTheWholeArchiveAgain() async throws {
        let w = try await WatchedArchive.make()
        let loose = try w.env.put("loose.pdf", text: "put there while events were lost")
        let deep = try w.env.put("Old/2024/receipt.pdf", text: "a receipt")
        await w.watcher.handle([FSEvent(path: w.env.archive.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 4)])
        #expect(await w.reported([.recordsChanged]), "every record file that changed is read again at once")
        await w.settle()
        #expect(await w.reported([.recordsChanged, .found(path: deep.path), .found(path: loose.path), .gone(path: w.env.archive.standardizedFileURL.path)]),
                "every file of the archive is looked at, and every document whose file is not where it was is looked for")
        await w.cleanup()
    }

    @Test func theAppsOwnChangeIsLeftOutButTheUsersNextChangeIsNot() async throws {
        let w = try await WatchedArchive.make()
        let filed = try w.env.put("bill.pdf", text: "an electricity bill")
        await w.registry.expect([filed.path])
        await w.watcher.handle([w.event(filed, .fileCreated, id: 1)])
        #expect(await !w.watcher.poll(), "the app's own change, expected, waits for nothing")
        try FileManager.default.removeItem(at: filed)
        await w.watcher.handle([w.event(filed, .fileRemoved, id: 2)])
        await w.settle()
        #expect(await w.reported([.gone(path: filed.path)]),
                "the expectation was used up by the app's change: the user's removal a moment later is reported")
        await w.cleanup()
    }

    @Test func anExpectedChangeIsUsedUpOnceOrForgottenAfterItsTime() async throws {
        let time = TestTime(.blocks)
        let ttl = try PipelineConfig.bundledDefaults().watcher.selfChangeTTLSeconds
        let registry = SelfChangeRegistry(ttl: ttl, time: time)
        let path = "/Archive/bill.pdf"
        await registry.expect([path])
        #expect(await registry.consume("/Archive/./bill.pdf"), "the first event for the path, however spelled, is the app's")
        #expect(await !registry.consume(path), "a second one is the user's")
        await registry.expect([path])
        time.advance(by: ttl)
        #expect(await !registry.consume(path), "an expectation no event came for is forgotten after watcher.selfChangeTTLSeconds")
    }

    @Test func theLastEventIsSavedOnlyOnceWhatItReportedIsApplied() async throws {
        let w = try await WatchedArchive.make()
        let note = try w.env.put("note.txt", text: "a note")
        let filed = try w.env.put("filed.pdf", text: "the app's own")
        await w.registry.expect([filed.path])
        await w.watcher.handle([w.event(note, .fileCreated, id: 5)])
        await w.watcher.handle([w.event(filed, .fileCreated, id: 9)])
        await w.settle()
        #expect(await w.reported([.found(path: note.path)]), "reported once complete")
        #expect(await Patience.until { await w.reports.batches.map(\.through) == [4, 9] },
                "while a change waits, no event after it is accounted for, not even the app's own change that made nothing to report; once it is reported, every event is")
        let reported = try #require(await w.reports.batches.last)
        #expect(try await w.env.database.meta(ArchiveWatcher.lastEventKey) == nil,
                "not saved while the change is only reported: a stop or a crash now reports it again at the next start")
        await w.watcher.applied(reported)
        #expect(try await w.env.database.meta(ArchiveWatcher.lastEventKey) == "9", "saved once it is applied")
        await w.watcher.applied(ArchiveChanges(changes: [], through: 4))
        #expect(try await w.env.database.meta(ArchiveWatcher.lastEventKey) == "9", "and never taken back")
        await w.cleanup()
    }

    @Test func whatIsOutsideTheArchiveIsLeftAlone() async throws {
        let w = try await WatchedArchive.make()
        let outside = w.env.root.appendingPathComponent("elsewhere.pdf")
        try Data("not the archive's".utf8).write(to: outside)
        await w.watcher.handle([w.event(outside, .fileCreated, id: 3)])
        #expect(await !w.watcher.poll(), "nothing waits: what is not in the archive is not the archive's")
        await w.cleanup()
    }

    @Test func anArchiveReachedThroughALinkIsReportedAsTheSettingsNameIt() async throws {
        let w = try await WatchedArchive.make()
        let onDisk = w.env.root.appendingPathComponent("On Disk", isDirectory: true)
        try FileManager.default.createDirectory(at: onDisk, withIntermediateDirectories: true)
        let link = w.env.root.appendingPathComponent("Archive Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: onDisk)
        await w.watcher.watch(link, since: nil)
        let scan = onDisk.appendingPathComponent("scan.pdf")
        try Data("a scan".utf8).write(to: scan)
        // FSEvents names a path as it is on disk, links resolved.
        let named = try #require(onDisk.canonicalFolderPath) + "/scan.pdf"
        await w.watcher.handle([FSEvent(path: named, flags: WatchedArchive.Flags.fileCreated.bits, id: 1)])
        await w.settle()
        #expect(await w.reported([.found(path: link.standardizedFileURL.appendingPathComponent("scan.pdf").path)]),
                "the path the index knows the document by, under the archive as the settings name it")
        await w.cleanup()
    }

    @Test(.enabled(if: Volume.ignoresCase, Volume.needsCaseInsensitive))
    func aRenameThatChangesOnlyCaseIsReportedAsTheNameOnDiskCameAndTheOtherWent() async throws {
        let w = try await WatchedArchive.make()
        let lower = try w.env.put("bill.txt", text: "an electricity bill")
        let upper = lower.deletingLastPathComponent().appendingPathComponent("Bill.txt")
        try FileManager.default.moveItem(at: lower, to: upper)
        let folder = try w.env.put("bills/receipt.txt", text: "a receipt").deletingLastPathComponent()
        let renamed = folder.deletingLastPathComponent().appendingPathComponent("Bills", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        await w.watcher.handle([w.event(lower, .fileRenamed, id: 1), w.event(upper, .fileRenamed, id: 2),
                                w.event(folder, .folderRenamed, id: 3), w.event(renamed, .folderRenamed, id: 4)])
        await w.settle()
        #expect(await w.reported([.found(path: upper.path), .found(path: renamed.appendingPathComponent("receipt.txt").path),
                                  .gone(path: lower.path), .gone(path: folder.path)]),
                "the name that went still finds the file on a volume that ignores case, but nothing is there under it: it went")
        await w.cleanup()
    }

    @Test func anArchiveFolderRenamedAwayIsNotTakenForGoneAndIsLookedAtAgainWhenBack() async throws {
        let w = try await WatchedArchive.make()
        let scan = try w.env.put("scan.pdf", text: "a scan")
        let away = w.env.root.appendingPathComponent("Archive renamed", isDirectory: true)
        try FileManager.default.moveItem(at: w.env.archive, to: away)
        await w.watcher.handle([FSEvent(path: w.env.archive.path, flags: WatchedArchive.Flags.rootChanged.bits, id: 1),
                                w.event(scan, .fileRenamed, id: 2)])
        await w.settle()
        #expect(await w.reports.changes.isEmpty, "the archive is not there: nothing in it is reported gone, as nothing in it is missing")
        try FileManager.default.moveItem(at: away, to: w.env.archive)
        await w.watcher.handle([FSEvent(path: w.env.archive.path, flags: WatchedArchive.Flags.rootChanged.bits, id: 3)])
        await w.settle()
        #expect(await w.reported([.recordsChanged, .found(path: scan.path), .gone(path: w.env.archive.standardizedFileURL.path)]),
                "back, the whole archive is looked at again, for what changed while it was away")
        await w.cleanup()
    }

    @Test func aFolderBeingLookedThroughIsNotCountedGoneBeforeWhatIsInItIsRegistered() async throws {
        let w = try await WatchedArchive.make()
        let inside = try w.env.put("Old/sub/bill.pdf", text: "a document moved within the folder")
        let old = inside.deletingLastPathComponent().deletingLastPathComponent()
        let (reached, letGo) = (Signal(), OneShot<Void>())
        // Held as a folder of many files is, while the watcher is polled.
        await w.watcher.setBeforeWalking { _ in
            reached.fire()
            await letGo.wait()
        }
        let handling = Task {
            await w.watcher.handle([FSEvent(path: old.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 5)])
        }
        try #require(await Patience.until { reached.fired }, "the folder is being looked through")
        for _ in 0..<w.env.config.watcher.stabilityRequiredPolls + 1 { _ = await w.watcher.poll() }
        let meanwhile = await w.reports.changes
        #expect(meanwhile.isEmpty, "while it is looked through, the folder is not counted gone: \(meanwhile)")
        letGo.fire(())
        await handling.value
        await w.settle()
        #expect(await w.reported([.recordsChanged, .found(path: inside.path), .gone(path: old.path)]),
                "what is in it is reported with it, where it is before where it was, so a document moved inside it is followed")
        await w.cleanup()
    }

    @Test func whatCameWaitsForWhatWentSoACopyAndAMoveOfItsOriginalAreReportedTogether() async throws {
        let w = try await WatchedArchive.make()
        let original = try w.env.put("bill.pdf", text: "an electricity bill")
        let copy = w.env.archive.appendingPathComponent("A copy.pdf").standardizedFileURL
        try FileManager.default.copyItem(at: original, to: copy)
        await w.watcher.handle([w.event(copy, .fileCreated, id: 1)])
        #expect(await w.watcher.poll(), "the copy waits")
        let moved = w.env.archive.appendingPathComponent("Z/bill.pdf").standardizedFileURL
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)
        await w.watcher.handle([w.event(original, .fileRenamed, id: 2), w.event(moved, .fileRenamed, id: 3)])
        await w.settle()
        #expect(await w.reported([.found(path: copy.path), .found(path: moved.path), .gone(path: original.path)]),
                "the copy, complete first, waits for the move made after it, so the original is told from its copy in one batch")
        #expect(await w.reports.batches.filter { !$0.changes.isEmpty }.count == 1, "all at once")
        await w.cleanup()
    }

    @Test func lostEventsUnderAFolderLookThroughThatFolderAndWhatTheIndexHasThereUnchangedIsNotReported() async throws {
        let w = try await WatchedArchive.make()
        let known = try w.env.put("Old/known.pdf", text: "a document the index has")
        let new = try w.env.put("Old/new.pdf", text: "put there while events were lost")
        _ = try w.env.put("elsewhere.pdf", text: "outside the folder events were lost under")
        var record = DocumentRecord.arrived(path: known.path, sha256: "sha", size: 1, uttype: "com.adobe.pdf",
                                            inode: FileFingerprint.inode(of: known), modified: nil, now: TestTime.start)
        record.status = .filed
        _ = try await DocumentStore(database: w.env.database, time: w.env.time).save(record)
        await w.watcher.handle([FSEvent(path: known.deletingLastPathComponent().path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 5)])
        await w.settle()
        #expect(await w.reported([.recordsChanged, .found(path: new.path), .gone(path: known.deletingLastPathComponent().path)]),
                "only the folder named is looked at again, and a document already where the index has it needs no wait")
        await w.cleanup()
    }

    @Test func aFileStillChangingAfterTheLongestWaitIsKeptHoldsNoLaterEventBackAndIsFoundOnceItStops() async throws {
        let w = try await WatchedArchive.make()
        let growing = try w.env.put("library.log", text: "the first line")
        await w.watcher.handle([w.event(growing, .fileCreated, id: 3)])
        #expect(await w.watcher.poll(), "it waits")
        w.time.advance(by: w.env.config.watcher.stabilityMaxWaitSeconds)
        // Its last write just before the pass that finds it changing after the longest wait: its event is spent.
        try w.append(" and the last line", to: growing)
        await w.watcher.handle([w.event(growing, .fileCreated, id: 4)])
        #expect(await w.watcher.poll(), "still changing after watcher.stabilityMaxWaitSeconds, it is not let go")
        let released = await Patience.until { await w.reports.batches.last?.through == 4 }
        #expect(released, "and the events after it are no longer held back by it, so a file an app keeps open holds none for ever")
        let said = try await HistoryStore(database: w.env.database, time: w.env.time).events(limit: 5, kinds: [.error]).map(\.summary)
        #expect(said.count == 1 && said.first?.hasPrefix("library.log in the archive has not stopped changing in") == true,
                "History says once that it is taking long: \(said)")
        let watcher = w.env.config.watcher
        try #require(watcher.awayPollSeconds > watcher.stabilityPollInterval)
        for _ in 0..<watcher.stabilityRequiredPolls + 1 {
            w.time.advance(by: watcher.stabilityPollInterval)
            _ = await w.watcher.poll()
        }
        #expect(await w.reports.changes.isEmpty, "taking long, it is not looked at at every poll, but every watcher.awayPollSeconds")
        for _ in 0..<watcher.stabilityRequiredPolls {
            w.time.advance(by: watcher.awayPollSeconds)
            _ = await w.watcher.poll()
        }
        #expect(await w.reported([.found(path: growing.path)]), "it is found once it has stopped, with no event after its last write")
        await w.cleanup()
    }

    @Test func aFileStillChangingWhenTheWatcherStopsIsLookedAtAgainAtTheNextStart() async throws {
        let w = try await WatchedArchive.make()
        let growing = try w.env.put("library.log", text: "the first line")
        await w.watcher.handle([w.event(growing, .fileCreated, id: 3)])
        _ = await w.watcher.poll()
        w.time.advance(by: w.env.config.watcher.stabilityMaxWaitSeconds)
        try w.append(" and the last line", to: growing)
        await w.watcher.handle([w.event(growing, .fileCreated, id: 4)])
        _ = await w.watcher.poll()
        #expect(try await w.env.database.meta(ArchiveWatcher.takingLongKey) == "[\"\(growing.path)\"]", "it is kept as still changing")
        // The events after it are saved as applied, and the app stops before it has stopped changing.
        await w.watcher.applied(ArchiveChanges(changes: [], through: 4))
        await w.watcher.stop()
        try await w.watcher.start(root: w.env.archive)
        for _ in 0..<w.env.config.watcher.stabilityRequiredPolls {
            w.time.advance(by: w.env.config.watcher.awayPollSeconds)
            _ = await w.watcher.poll()
        }
        #expect(await w.reported([.found(path: growing.path)]), "it is looked at again at the next start, and found, with no event after its last write")
        #expect(try await w.env.database.meta(ArchiveWatcher.takingLongKey) == nil, "and kept no more once it has stopped")
        let said = try await HistoryStore(database: w.env.database, time: w.env.time).events(limit: 5, kinds: [.error])
        #expect(said.count == 1, "History said once that it was taking long, not again after the start")
        await w.cleanup()
    }

    @Test func aFileThatDoesNotSettleIsLetGoOnlyAfterItCouldHaveSettled() throws {
        var config = try PipelineConfig.bundledDefaults()
        config.watcher.stabilityMaxWaitSeconds = config.watcher.zeroByteWaitSeconds
        #expect(config.problems.contains { $0.hasPrefix("watcher.stabilityMaxWaitSeconds must be more than") },
                "a file would be let go before an empty one is waited for: the app stops with the reason, naming the key")
    }

    @Test func aPollOrALookThroughStoppedPartWayActsOnNothing() async throws {
        let w = try await WatchedArchive.make()
        let scan = try w.env.put("scan.pdf", text: "a scan")
        let folder = try w.env.put("Taxes 2024/receipt.pdf", text: "a receipt").deletingLastPathComponent()
        await w.watcher.handle([w.event(scan, .fileCreated, id: 1)])
        let polling = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await w.watcher.poll()
        }
        #expect(await polling.value == false, "a poll whose task is stopped, as the app's is when it quits, ends without counting")
        let looking = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await w.watcher.handle([w.event(folder, .folderCreated, id: 2)])
        }
        await looking.value
        await w.settle()
        #expect(await w.reported([.found(path: scan.path)]),
                "what waited is polled as before, and nothing of a folder looked through by a stopped task is taken in")
        #expect(await w.reports.batches.last?.through == 1, "nor is the event it stopped on accounted for")
        await w.cleanup()
    }

    @Test func anArchiveWatchedForTheFirstTimeIsResumedFromThenAtTheNextStart() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        let watcher = ArchiveWatcher(config: env.config.watcher, skip: SkipRules(watcher: env.config.watcher),
                                     registry: SelfChangeRegistry(ttl: env.config.watcher.selfChangeTTLSeconds, time: env.time),
                                     database: env.database, time: env.time)
        let before = FSEventStream.currentEventID()
        try await watcher.start(root: env.archive)
        await watcher.stop()
        let saved = try #require(try await env.database.meta(ArchiveWatcher.lastEventKey).flatMap(UInt64.init),
                                 "where it began is saved at once, before anything is reported")
        #expect(saved >= before, "so a change made from then on and not applied before a stop is reported again at the next start")
        #expect(try await env.database.meta(ArchiveWatcher.folderKey) == ArchiveDisk.disk.identity(of: env.archive)?.stored,
                "and the folder the index is kept for is the one there")
    }

    /// The app stops its watchers and the tasks that read them when it stops; started again, a new reader is sent what
    /// comes, though the one before it was cancelled.
    @Test func aChangeInTheArchiveAfterItsWatcherIsStoppedAndStartedAgainIsReported() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        let watcher = ArchiveWatcher(config: env.config.watcher, skip: SkipRules(watcher: env.config.watcher),
                                     registry: SelfChangeRegistry(ttl: env.config.watcher.selfChangeTTLSeconds, time: env.time),
                                     database: env.database, time: env.time)
        let first = await watcher.changes()
        let reading = Task { for await _ in first {} }
        try await watcher.start(root: env.archive)
        await watcher.stop()
        reading.cancel()
        await reading.value

        let reports = ArchiveReports()
        let again = await watcher.changes()
        let collecting = Task { for await reported in again { await reports.add(reported) } }
        try await watcher.start(root: env.archive)
        let note = try env.put("note.txt", text: "put there by the user")
        await watcher.handle([FSEvent(path: note.path, flags: WatchedArchive.Flags.fileCreated.bits, id: 1)])
        #expect(await Patience.until { await reports.changes.contains(.found(path: note.path)) },
                "a file the user puts in the archive once its watcher is started again is reported to the new reader")
        await watcher.stop()
        collecting.cancel()
    }
}

/// A volume that is mounted again when the test says, under another device number, as ejecting a disk and attaching it
/// again does, the volume's own identifier and its folders' inodes staying as they were.
final class Remounts: Sendable {
    private let mount = Mutex<Int32>(1)

    func again() { mount.withLock { $0 += 1 } }

    /// The device number the volume has now.
    var device: Int32 { mount.withLock { $0 } }

    var disk: ArchiveDisk {
        ArchiveDisk(file: { [self] url in FileOnDisk(url).map { FileOnDisk(device: device, inode: $0.inode) } },
                    volume: { _ in Self.volume }, volumeName: { _ in nil }, keepsFileIDs: { _ in true })
    }

    static let volume = "the volume mounted again"
}

/// The volume the tests' temporary folders are on.
enum Volume {
    /// Whether it ignores case, as APFS does unless formatted otherwise, so that `bill.txt` finds `Bill.txt`.
    static let ignoresCase: Bool = {
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-case-\(UUID().uuidString.lowercased())")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
        defer { try? FileManager.default.removeItem(at: probe) }
        return FileManager.default.fileExists(atPath: probe.deletingLastPathComponent().appendingPathComponent(probe.lastPathComponent.uppercased()).path)
    }()

    static let needsCaseInsensitive: Comment = "a rename that changes only case needs a volume that ignores case, as APFS does unless formatted otherwise"
}

/// Whether the archive's folder was there, each time the watcher said.
actor ArchivePresence {
    private(set) var values: [Bool] = []
    func add(_ there: Bool) { values.append(there) }
}

/// What the archive watcher reported, in the order it reported it.
actor ArchiveReports {
    private(set) var batches: [ArchiveChanges] = []
    var changes: [ArchiveChange] { batches.flatMap(\.changes) }
    func add(_ reported: ArchiveChanges) { batches.append(reported) }
}

/// An archive watcher over a test environment's archive, given batches of events by the test rather than by FSEvents, on
/// time that moves only when the test moves it, so each poll is the test's own (`ArchiveWatcher.poll()`).
struct WatchedArchive {
    let env: TestEnvironment
    let watcher: ArchiveWatcher
    let registry: SelfChangeRegistry
    /// The watcher's time, which moves only when the test moves it.
    let time: TestTime
    let reports: ArchiveReports
    private let collecting: Task<Void, Never>

    enum Flags {
        case fileCreated, fileRenamed, fileRemoved, folderCreated, folderRenamed, folderRemoved, rootChanged

        var bits: UInt32 {
            switch self {
            case .fileCreated: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)
            case .fileRenamed: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRenamed)
            case .fileRemoved: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRemoved)
            case .folderCreated: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
            case .folderRenamed: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
            case .folderRemoved: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRemoved)
            case .rootChanged: UInt32(kFSEventStreamEventFlagRootChanged)
            }
        }
    }

    /// - Parameter disk: what the watcher asks the disk; a test gives another, as a volume mounted again would answer.
    static func make(disk: ArchiveDisk = .disk) async throws -> WatchedArchive {
        let env = try await TestEnvironment.make()
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        // Sleeping on it never ends: the watcher polls only when the test does.
        let time = TestTime(.blocks)
        let registry = SelfChangeRegistry(ttl: env.config.watcher.selfChangeTTLSeconds, time: time)
        let watcher = ArchiveWatcher(config: env.config.watcher, skip: SkipRules(watcher: env.config.watcher), registry: registry,
                                     database: env.database, time: time)
        let reports = ArchiveReports()
        let changes = await watcher.changes()
        let collecting = Task { for await reported in changes { await reports.add(reported) } }
        await watcher.use(disk)
        await watcher.watch(env.archive, since: nil)
        return WatchedArchive(env: env, watcher: watcher, registry: registry, time: time, reports: reports, collecting: collecting)
    }

    func event(_ url: URL, _ flags: Flags, id: UInt64) -> FSEvent {
        FSEvent(path: url.path, flags: flags.bits, id: id)
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Polls until nothing waits, at most as many times as anything that stops changing needs.
    func settle() async {
        for _ in 0..<env.config.watcher.stabilityRequiredPolls {
            guard await watcher.poll() else { return }
        }
    }

    /// Whether the changes reported, in order, come to `expected`, once the reader has been sent them.
    func reported(_ expected: [ArchiveChange]) async -> Bool {
        await Patience.until { await reports.changes == expected }
    }

    func cleanup() async {
        await watcher.stop()
        collecting.cancel()
        env.cleanup()
    }
}
