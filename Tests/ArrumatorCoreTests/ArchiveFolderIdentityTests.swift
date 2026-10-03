@testable import ArrumatorCore
import ArrumatorTesting
import CoreServices
import Foundation
import Synchronization
import Testing

/// Which folder the archive watcher takes for the archive: the same one across mounts, another put at its path, and the
/// earlier one back, each said so in History once, and one that went looked for until it is back.
@Suite struct ArchiveFolderIdentityTests {
    @Test func anotherFolderMadeAtTheArchivesPathIsTakenAsTheArchiveAndSaidSoOnce() async throws {
        let w = try await WatchedArchive.make()
        _ = try w.env.put("scan.pdf", text: "a scan")
        let away = w.env.root.appendingPathComponent("Archive moved away", isDirectory: true)
        try FileManager.default.moveItem(at: w.env.archive, to: away)
        try FileManager.default.createDirectory(at: w.env.archive, withIntermediateDirectories: true)
        let letter = try w.env.put("letter.pdf", text: "a letter in the new folder")
        await w.watcher.handle([FSEvent(path: w.env.archive.path, flags: WatchedArchive.Flags.rootChanged.bits, id: 1)])
        await w.settle()
        #expect(await w.reported([.recordsChanged, .found(path: letter.path), .gone(path: w.env.archive.standardizedFileURL.path)]),
                "another folder at the archive's path is the archive now: its record files are read, everything in it is looked at, and every document looked for")
        #expect(try await w.env.database.meta(ArchiveRecords.mergeOwedKey) == ArchiveRecords.mergeOwed,
                "merged with the index, not taken over it, as the index keeps until they are read")
        let note = try w.env.put("note.pdf", text: "put there afterwards")
        await w.watcher.handle([w.event(note, .fileCreated, id: 2)])
        await w.settle()
        #expect(await Patience.until { await w.reports.changes.contains(.found(path: note.path)) }, "and the watcher goes on reporting what comes")
        let said = try await HistoryStore(database: w.env.database, time: w.env.time).events(limit: 5, kinds: [.error]).map(\.summary)
        #expect(said.count == 1 && said.first?.contains(w.env.archive.standardizedFileURL.path) == true,
                "History says once that the archive's folder was replaced: \(said)")
        await w.cleanup()
    }

    @Test func anArchiveOnAVolumeMountedAgainIsTheSameFolderAndGoesOnBeingWatched() async throws {
        let remounts = Remounts()
        let w = try await WatchedArchive.make(disk: remounts.disk)
        remounts.again()
        await w.watcher.handle([FSEvent(path: w.env.archive.path, flags: WatchedArchive.Flags.rootChanged.bits, id: 1)])
        let note = try w.env.put("note.pdf", text: "put there once the disk came back")
        await w.watcher.handle([w.event(note, .fileCreated, id: 2)])
        await w.settle()
        #expect(await w.reported([.recordsChanged, .found(path: note.path), .gone(path: w.env.archive.standardizedFileURL.path)]),
                "under another device number, the same volume's folder is the archive still: it is looked at again, and watched")
        let said = try await HistoryStore(database: w.env.database, time: w.env.time).events(limit: 5, kinds: [.error])
        #expect(said.isEmpty, "and it is not taken for another folder: \(said.map(\.summary))")
        await w.cleanup()
    }

    @Test func anArchiveFolderBackWithNoEventIsFoundByLookingForIt() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        // Time that passes at once: the watcher looks again as soon as it waits.
        let time = TestTime(.advances)
        let watcher = ArchiveWatcher(config: env.config.watcher, skip: SkipRules(watcher: env.config.watcher),
                                     registry: SelfChangeRegistry(ttl: env.config.watcher.selfChangeTTLSeconds, time: time),
                                     database: env.database, time: time)
        let presence = await watcher.presence()
        let seen = ArchivePresence()
        let following = Task { for await there in presence { await seen.add(there) } }
        defer { following.cancel() }
        await watcher.watch(env.archive, since: nil)
        let away = env.root.appendingPathComponent("Away", isDirectory: true)
        try FileManager.default.moveItem(at: env.archive, to: away)
        await watcher.handle([FSEvent(path: env.archive.path, flags: WatchedArchive.Flags.rootChanged.bits, id: 1)])
        #expect(await Patience.until { await seen.values.last == false }, "its folder gone, the archive is said to be away")
        // Back with no event, as a disk attached again need not give one.
        try FileManager.default.moveItem(at: away, to: env.archive)
        #expect(await Patience.until { await seen.values.last == true }, "it is looked for every watcher.awayPollSeconds, and found back")
        await watcher.stop()
    }

    @Test func theArchivesEarlierFolderComingBackIsSaidToBeBack() async throws {
        let w = try await WatchedArchive.make()
        let history = HistoryStore(database: w.env.database, time: w.env.time)
        let earlier = w.env.root.appendingPathComponent("Earlier folder", isDirectory: true)
        try FileManager.default.moveItem(at: w.env.archive, to: earlier)
        try FileManager.default.createDirectory(at: w.env.archive, withIntermediateDirectories: true)
        await w.watcher.handle([FSEvent(path: w.env.archive.path, flags: WatchedArchive.Flags.rootChanged.bits, id: 1)])
        let other = w.env.root.appendingPathComponent("Other folder", isDirectory: true)
        try FileManager.default.moveItem(at: w.env.archive, to: other)
        try FileManager.default.moveItem(at: earlier, to: w.env.archive)
        await w.watcher.handle([FSEvent(path: w.env.archive.path, flags: WatchedArchive.Flags.rootChanged.bits, id: 2)])
        let said = try await history.events(limit: 5, kinds: [.error]).map(\.summary)
        #expect(said.count == 2 && said.first?.hasPrefix("The archive's earlier folder at \(w.env.archive.standardizedFileURL.path) is back") == true
                    && said.last?.contains("is another folder than before") == true,
                "the folder the index was kept for, back, is said to be back, not another: \(said)")
        #expect(try await w.env.database.meta(ArchiveWatcher.folderKey) == ArchiveDisk.disk.identity(of: w.env.archive)?.stored,
                "and the index is kept for it again")
        #expect(try await w.env.database.meta(ArchiveRecords.mergeOwedKey) == ArchiveRecords.mergeOwed,
                "and its record files are to be merged with what was kept meanwhile")
        await w.cleanup()
    }

    @Test func aMergeOwedForAnotherFolderIsDoneAfterAStopBeforeIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        try await h.readyToWork()
        _ = try await h.labels.ignore(DocumentLabel(kind: .topic, value: "electricity"))
        try await h.env.records().flush()
        let watcher = ArchiveWatcher(config: h.env.config.watcher, skip: SkipRules(watcher: h.env.config.watcher),
                                     registry: SelfChangeRegistry(ttl: h.env.config.watcher.selfChangeTTLSeconds, time: h.env.time),
                                     database: h.env.database, time: h.env.time)
        try await watcher.start(root: h.env.archive)
        // Another folder taken as the archive, its record files read merged, and a rule made meanwhile.
        let earlier = h.env.root.appendingPathComponent("Earlier folder", isDirectory: true)
        try FileManager.default.moveItem(at: h.env.archive, to: earlier)
        try FileManager.default.createDirectory(at: h.env.archive, withIntermediateDirectories: true)
        await watcher.handle([FSEvent(path: h.env.archive.path, flags: WatchedArchive.Flags.rootChanged.bits, id: 1)])
        try await h.env.records().reconcile()
        #expect(try await h.env.database.meta(ArchiveRecords.mergeOwedKey) == nil, "a merge done is owed no more")
        _ = try await h.labels.ignore(DocumentLabel(kind: .topic, value: "water"))
        try await h.env.records().flush()
        // The earlier folder back, and the app stopped before its record files were read.
        try FileManager.default.moveItem(at: h.env.archive, to: h.env.root.appendingPathComponent("Other folder", isDirectory: true))
        try FileManager.default.moveItem(at: earlier, to: h.env.archive)
        await watcher.handle([FSEvent(path: h.env.archive.path, flags: WatchedArchive.Flags.rootChanged.bits, id: 2)])
        await watcher.stop()
        // The next start: the index is kept for this folder already, and its record files are read.
        try await h.env.records().reconcile()
        let rules = try await h.env.database.reader.read { db in try LabelRule.fetchAll(db) }
        #expect(rules.count == 2, "the earlier folder's record files are merged still, so the rule made meanwhile is kept: \(rules.map(\.value))")
        #expect(try await h.env.database.meta(ArchiveRecords.mergeOwedKey) == nil, "and the merge is owed no more")
    }

    @Test func aVolumeWithoutAnIdentifierIsKnownByItsNameAndTheFoldersPathAcrossMounts() async throws {
        let mounts = Mutex<UInt64>(1)
        // A volume without an identifier of its own, as some formats are: mounted again, its device number and its
        // folders' numbers change.
        let disk = ArchiveDisk(file: { url in FileOnDisk(url).map { _ in mounts.withLock { FileOnDisk(device: Int32($0), inode: $0 * 100) } } },
                               volume: { _ in nil }, volumeName: { _ in "Backup" }, keepsFileIDs: { _ in false })
        let w = try await WatchedArchive.make(disk: disk)
        mounts.withLock { $0 += 1 }
        await w.watcher.handle([FSEvent(path: w.env.archive.path, flags: WatchedArchive.Flags.rootChanged.bits, id: 1)])
        let said = try await HistoryStore(database: w.env.database, time: w.env.time).events(limit: 5, kinds: [.error])
        #expect(said.isEmpty, "mounted again, it is the same archive, known by the volume's name and the folder's path: \(said.map(\.summary))")
        #expect(disk.identity(of: w.env.archive) == FolderIdentity(volume: "named Backup", place: "path \(w.env.archive.standardizedFileURL.path)"))
        await w.cleanup()
    }

    @Test func anotherFolderPutInPlaceWhileTheAppDidNotRunIsTakenAsTheArchiveWhenItStarts() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        try await env.database.setMeta(ArchiveWatcher.folderKey, FolderIdentity(volume: "the volume it was on", place: "inode 1").stored)
        let watcher = ArchiveWatcher(config: env.config.watcher, skip: SkipRules(watcher: env.config.watcher),
                                     registry: SelfChangeRegistry(ttl: env.config.watcher.selfChangeTTLSeconds, time: env.time),
                                     database: env.database, time: env.time)
        try await watcher.start(root: env.archive)
        await watcher.stop()
        let said = try await HistoryStore(database: env.database, time: env.time).events(limit: 5, kinds: [.error]).map(\.summary)
        #expect(said.count == 1 && said.first?.contains(env.archive.standardizedFileURL.path) == true,
                "History says once that the archive's folder is another than the one the index was kept for: \(said)")
        #expect(try await env.database.meta(ArchiveWatcher.folderKey) == ArchiveDisk.disk.identity(of: env.archive)?.stored,
                "which the index is kept for from then on")
    }
}
