@testable import ArrumatorCore
import ArrumatorTesting
import CoreServices
import Foundation
import Testing

/// Which files the app takes in, when it takes them, and when it waits: the Incoming watcher, the rules that skip
/// files, and the pause for power, on time a test controls.
@Suite struct WatchingTests {
    @Test func temporaryLockedAndOwnFilesAreNeverTakenIn() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let skip = SkipRules(watcher: env.config.watcher)
        let root = env.root
        for (name, why) in [(".DS_Store", "a system file"), ("~$Contract.docx", "Office's lock file"), ("report.pdf.crdownload", "a download"),
                            ("._scan.pdf", "a resource fork"), ("x.arrumator-tmp-1", "the app's own copy in progress"),
                            ("_documents.md", "a record file")] {
            #expect(skip.ignoreReason(root.appendingPathComponent(name)) != nil, "\(name) is \(why)")
        }
        let bill = root.appendingPathComponent("bill.pdf")
        try Data("pdf".utf8).write(to: bill)
        #expect(skip.ignoreReason(bill) == nil, "a document is taken in")
        #expect(skip.isInsideIgnoredDirectory(root.appendingPathComponent(".hidden/bill.pdf"), root: root), "and nothing inside a hidden folder")
        #expect(!skip.isInsideIgnoredDirectory(root.appendingPathComponent("Scans/bill.pdf"), root: root), "but a folder of the user's is read")
    }

    @Test func aFileIsTakenInOnceItHasStoppedChanging() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = env.root.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let bill = incoming.appendingPathComponent("bill.pdf")
        try Data("a whole document".utf8).write(to: bill)
        try Data().write(to: incoming.appendingPathComponent(".DS_Store"))
        let time = TestTime(.advances)
        let watcher = IncomingWatcher(config: env.config.watcher, skip: SkipRules(watcher: env.config.watcher), time: time)
        var files = await watcher.arrivals().makeAsyncIterator()
        try await watcher.start(root: incoming, excluding: [])
        defer { await watcher.stop() }
        let stable = await files.next()
        #expect(stable.map(Self.paths) == [bill.path], "the document, once unchanged, and not the system file")
        let waited = time.now().timeIntervalSince(TestTime.start)
        let polls = Double(env.config.watcher.stabilityRequiredPolls)
        #expect(waited >= polls * env.config.watcher.stabilityPollInterval,
                "it was taken only after unchanged for watcher.stabilityRequiredPolls polls, so a copy in progress is never read half")
    }

    @Test func aFileThatChangesBetweenPollsIsTakenOnlyOnceItHasStopped() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        let watcher = env.watcher()
        try await watcher.start(root: incoming, excluding: [])
        defer { await watcher.stop() }
        let bill = incoming.appendingPathComponent("bill.pdf")
        try Data("the first pages".utf8).write(to: bill)
        await watcher.handle([Self.created(bill)])
        #expect(await watcher.poll().isEmpty, "unchanged for one pass, it is not taken yet")
        let handle = try FileHandle(forWritingTo: bill)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" and the pages copied since".utf8))
        try handle.close()
        #expect(await watcher.poll().isEmpty, "a file that changed between two passes is not taken")
        for pass in 1..<env.config.watcher.stabilityRequiredPolls {
            #expect(await watcher.poll().isEmpty, "pass \(pass) after the change: it counts the passes unchanged again, from none")
        }
        #expect(Self.paths(await watcher.poll()) == [bill.path],
                "it is taken once unchanged for watcher.stabilityRequiredPolls passes after its last change, so it is never read half")
    }

    @Test func aFolderMovedIntoIncomingIsTakenInWithEverythingInIt() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = env.root.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let watcher = IncomingWatcher(config: env.config.watcher, skip: SkipRules(watcher: env.config.watcher), time: TestTime(.advances))
        try await watcher.start(root: incoming, excluding: [])
        defer { await watcher.stop() }
        let taken = Taken()
        let stable = await watcher.arrivals()
        let collecting = Task { for await arrival in stable { await taken.add(arrival) } }
        defer { collecting.cancel() }
        // Made elsewhere and moved in whole, as Finder moves a folder on one volume: macOS reports the folder that came,
        // not what is in it.
        let elsewhere = env.root.appendingPathComponent("Taxes 2024", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try Data("a scan".utf8).write(to: elsewhere.appendingPathComponent("scan.pdf"))
        try Data("a receipt".utf8).write(to: elsewhere.appendingPathComponent("sub/receipt.pdf"))
        let moved = incoming.appendingPathComponent("Taxes 2024", isDirectory: true)
        try FileManager.default.moveItem(at: elsewhere, to: moved)
        await watcher.handle([FSEvent(path: moved.path, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed), id: 1)])
        #expect(await Patience.until { await taken.names == ["scan.pdf", "receipt.pdf"] },
                "every file in a folder that comes into Incoming is taken in, at any depth, once it has stopped changing")
    }

    @Test func aPackageInIncomingIsOneDocumentWhetherFoundThereOrMovedInWhole() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        let found = try writePackage(incoming.appendingPathComponent("Found.rtfd"), notesPackage)
        let watcher = env.watcher()
        try await watcher.start(root: incoming, excluding: [])
        defer { await watcher.stop() }
        let moved = incoming.appendingPathComponent("Notes.rtfd", isDirectory: true)
        try FileManager.default.moveItem(at: try writePackage(env.root.appendingPathComponent("Notes.rtfd"), notesPackage), to: moved)
        // Moved on one volume, the package is reported alone; copied from another, each file in it is reported too.
        await watcher.handle([FSEvent(path: moved.path, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed), id: 1),
                              Self.created(moved.appendingPathComponent("TXT.rtf")),
                              Self.created(moved.appendingPathComponent("Pictures/boiler.png"))])
        var taken: [IncomingArrival] = []
        for _ in 0..<env.config.watcher.stabilityRequiredPolls { taken += await watcher.poll() }
        #expect(Set(Self.paths(taken)) == [found.path, moved.path] && taken.count == 2,
                "a package is one document, taken whole once it has stopped changing, never the files it holds one by one")
    }

    @Test func aPackageWrittenFileByFileIsTakenWholeOnceNothingInItChanges() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        let watcher = env.watcher()
        try await watcher.start(root: incoming, excluding: [])
        defer { await watcher.stop() }
        let notes = incoming.appendingPathComponent("Notes.rtfd", isDirectory: true)
        try writePackage(notes, [notesPackage[0]])
        await watcher.handle([FSEvent(path: notes.path, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated), id: 1),
                              Self.created(notes.appendingPathComponent(notesPackage[0].path))])
        #expect(await watcher.poll().isEmpty, "a package being written is not taken after one pass")
        try writePackage(notes, [notesPackage[1]])
        await watcher.handle([Self.created(notes.appendingPathComponent(notesPackage[1].path))])
        #expect(await watcher.poll().isEmpty, "a file written deep inside it is the package changing")
        for pass in 1..<env.config.watcher.stabilityRequiredPolls {
            #expect(await watcher.poll().isEmpty, "pass \(pass) after the change: it counts the passes unchanged again")
        }
        #expect(Self.paths(await watcher.poll()) == [notes.path],
                "it is taken whole, once, when nothing in it has changed for watcher.stabilityRequiredPolls passes")
    }

    @Test func nothingInTheArchiveKeptInsideIncomingIsTakenIn() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        let archive = try env.folder("Incoming/Archive")
        try Data("a filed document".utf8).write(to: archive.appendingPathComponent("2026-07-05 EDP - Fatura.pdf"))
        let bill = incoming.appendingPathComponent("bill.pdf")
        try Data("a new document".utf8).write(to: bill)
        let watcher = env.watcher()
        try await watcher.start(root: incoming, excluding: [archive])
        defer { await watcher.stop() }
        let filed = archive.appendingPathComponent("2026-07-06 MEO - Contrato.pdf")
        try Data("filed while watched".utf8).write(to: filed)
        await watcher.handle([Self.created(filed), FSEvent(path: archive.path, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed), id: 2)])
        var taken: [IncomingArrival] = []
        for _ in 0..<env.config.watcher.stabilityRequiredPolls { taken += await watcher.poll() }
        #expect(Self.paths(taken) == [bill.path],
                "what is in the archive, found at start, reported by an event or in the archive's folder moved in, is never filed again")
    }

    @Test func incomingNamedThroughALinkIsWatchedAsTheDiskSpellsIt() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        let link = env.root.appendingPathComponent("Scans", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: incoming)
        try await Self.takesIn(env, watching: link, real: incoming,
                               "Incoming named through a link is watched as FSEvents reports it, links resolved")
    }

    @Test(.enabled(if: WatchingTests.temporaryVolumeIgnoresCase, "only a volume that ignores case finds Incoming written in another case"))
    func incomingNamedInAnotherCaseIsWatchedAsTheDiskSpellsIt() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        try await Self.takesIn(env, watching: env.root.appendingPathComponent("INCOMING", isDirectory: true), real: incoming,
                               "Incoming named in another case than the disk's is watched as FSEvents reports it, in the disk's case")
        let folders = IncomingFolders(incoming: env.root.appendingPathComponent("INCOMING", isDirectory: true), watcher: env.config.watcher,
                                      labels: env.config.labels)
        let scan = try env.file("Incoming/Taxes 2024/scan.pdf")
        #expect(folders.tag(of: scan)?.label == DocumentLabel(kind: .tag, value: "Taxes 2024"),
                "and a file it reports in the disk's spelling is given the tag of its folder all the same")
    }

    /// Whether the volume of the temporary folder, where the tests write, ignores case, as a Mac's does unless it was
    /// formatted otherwise.
    static var temporaryVolumeIgnoresCase: Bool {
        (try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) == false
    }

    /// Starts a watcher on `root`, another spelling of `real`, and checks a file FSEvents reports in `real` is taken.
    private static func takesIn(_ env: TestEnvironmentSync, watching root: URL, real: URL, _ why: String) async throws {
        let watcher = env.watcher()
        try await watcher.start(root: root, excluding: [])
        defer { await watcher.stop() }
        let bill = real.appendingPathComponent("bill.pdf")
        try Data("a whole document".utf8).write(to: bill)
        await watcher.handle([created(bill)])
        var taken: [IncomingArrival] = []
        for _ in 0..<env.config.watcher.stabilityRequiredPolls { taken += await watcher.poll() }
        #expect(paths(taken) == [bill.path], "\(why)")
    }

    @Test(.enabled(if: getuid() != 0, "the superuser opens a file whatever its permissions, so none is unopenable to it"))
    func aFileThatCannotBeOpenedIsWaitedForThenLeftAndTakenUpOnceItCanBe() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        let time = TestTime(.blocks)
        let watcher = env.watcher(time: time)
        try await watcher.start(root: incoming, excluding: [])
        defer { await watcher.stop() }
        let locked = incoming.appendingPathComponent("locked.pdf")
        try Data("a document the app may not read".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        await watcher.handle([Self.created(locked)])
        let wait = env.config.watcher.unopenableWaitSeconds
        #expect(await watcher.poll().isEmpty, "unchanged but not to be opened, it is not taken")
        time.advance(by: wait / 2)
        #expect(await watcher.poll().isEmpty, "and it is waited for, within watcher.unopenableWaitSeconds")
        time.advance(by: wait / 2)
        let left = await watcher.poll()
        #expect(left.count == 1 && left.first == .unopenable(URL(fileURLWithPath: locked.path), .unreadable),
                "after watcher.unopenableWaitSeconds it is no longer waited for, and that is said, once")
        #expect(await watcher.poll().isEmpty, "it is polled no more")
        await watcher.handle([Self.created(locked)])
        #expect(await watcher.poll().isEmpty, "nor taken up by an event while it still cannot be opened")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        await watcher.handle([Self.created(locked)])
        var taken: [IncomingArrival] = []
        for _ in 0..<env.config.watcher.stabilityRequiredPolls { taken += await watcher.poll() }
        #expect(Self.paths(taken) == [locked.path], "once it can be opened, it is taken in")
    }

    @Test(.enabled(if: getuid() != 0, "the superuser lists a folder whatever its permissions, so none is unreadable to it"))
    func aPackageThatCannotBeReadWholeIsWaitedForThenLeft() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        let time = TestTime(.blocks)
        let watcher = env.watcher(time: time)
        try await watcher.start(root: incoming, excluding: [])
        defer { await watcher.stop() }
        let notes = try writePackage(incoming.appendingPathComponent("Notes.rtfd"), notesPackage)
        let pictures = notes.appendingPathComponent("Pictures")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: pictures.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pictures.path) }
        await watcher.handle([Self.created(notes.appendingPathComponent("TXT.rtf"))])
        #expect(await watcher.poll().isEmpty, "a package one of whose folders cannot be listed is not taken")
        time.advance(by: env.config.watcher.unopenableWaitSeconds)
        #expect(await watcher.poll() == [.unopenable(URL(fileURLWithPath: notes.path), .unreadable)],
                "nor polled for ever: after watcher.unopenableWaitSeconds it is left, and that is said")
    }

    @Test func aPackageOfMoreItemsThanAllowedIsNotWalkedFurtherAndIsLeft() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        let time = TestTime(.blocks)
        var config = env.config.watcher
        config.maxPackageItems = 2
        let watcher = IncomingWatcher(config: config, skip: SkipRules(watcher: config), time: time)
        try await watcher.start(root: incoming, excluding: [])
        defer { await watcher.stop() }
        // Notes.rtfd holds three items: two files and a folder.
        let notes = try writePackage(incoming.appendingPathComponent("Notes.rtfd"), notesPackage)
        await watcher.handle([Self.created(notes.appendingPathComponent("TXT.rtf"))])
        #expect(await watcher.poll().isEmpty, "a package of more than watcher.maxPackageItems items is not taken")
        time.advance(by: config.unopenableWaitSeconds)
        #expect(await watcher.poll() == [.unopenable(URL(fileURLWithPath: notes.path), .tooManyItems(limit: 2))],
                "and is left after watcher.unopenableWaitSeconds, saying why")
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        await h.coordinator.receive(.unopenable(notes, .tooManyItems(limit: 2)))
        #expect(try await h.services.history.events(limit: 5, kinds: [.error]).map(\.summary)
                    == ["Notes.rtfd in Incoming holds more than 2 items, too many for one document (watcher.maxPackageItems)"],
                "History says why it stays in Incoming")
    }

    @Test(.timeLimit(.minutes(1)))
    func aPipeInIncomingIsNeverTakenInNorWaitedOn() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        let time = TestTime(.blocks)
        let watcher = env.watcher(time: time)
        try await watcher.start(root: incoming, excluding: [])
        defer { await watcher.stop() }
        let pipe = incoming.appendingPathComponent("pipe")
        try #require(mkfifo(pipe.path, 0o644) == 0, "a named pipe is made, as any program may make one in a folder")
        #expect(SkipRules(watcher: env.config.watcher).ignoreReason(pipe) == "not a regular file", "it is no file to read")
        await watcher.handle([Self.created(pipe)])
        time.advance(by: env.config.watcher.unopenableWaitSeconds)
        #expect(await watcher.poll().isEmpty,
                "it is never a candidate, and opening it, which waits for a writer for ever, is never tried: the watcher goes on")
    }

    @Test func aFileThatCannotBeOpenedIsSaidInHistoryAndNotQueued() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let locked = try h.env.drop("locked.pdf", text: "a document the app may not read")
        await h.coordinator.receive(.unopenable(locked, .unreadable))
        let said = try await h.services.history.events(limit: 5, kinds: [.error])
        #expect(said.map(\.summary) == ["locked.pdf in Incoming cannot be opened; it is taken once it can be"],
                "History says why the file stays in Incoming, where the user sees it")
        #expect(try await h.jobs().isEmpty, "and it is not queued")
    }

    /// The app stops its watchers and the tasks that read them when it stops; started again, a new reader is sent what
    /// comes, though the one before it was cancelled.
    @Test func aFileThatComesAfterTheWatcherIsStoppedAndStartedAgainIsTakenIn() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = env.root.appendingPathComponent("Incoming", isDirectory: true)
        let watcher = IncomingWatcher(config: env.config.watcher, skip: SkipRules(watcher: env.config.watcher), time: TestTime(.advances))
        let first = await watcher.arrivals()
        let reading = Task { for await _ in first {} }
        try await watcher.start(root: incoming, excluding: [])
        await watcher.stop()
        reading.cancel()
        await reading.value

        let taken = Taken()
        let again = await watcher.arrivals()
        let collecting = Task { for await arrival in again { await taken.add(arrival) } }
        defer { collecting.cancel() }
        try await watcher.start(root: incoming, excluding: [])
        defer { await watcher.stop() }
        let bill = incoming.appendingPathComponent("bill.pdf")
        try Data("a whole document".utf8).write(to: bill)
        await watcher.handle([Self.created(bill)])
        #expect(await Patience.until { await taken.names == ["bill.pdf"] },
                "a file that comes once the watcher is started again is sent to its new reader, as Incoming is watched again")
    }

    @Test func aChangeInTheArchiveAfterItsWatcherIsStoppedAndStartedAgainIsReported() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.archive, withIntermediateDirectories: true)
        let watcher = ArchiveWatcher(config: env.config.watcher, records: env.config.records, skip: SkipRules(watcher: env.config.watcher),
                                     registry: SelfChangeRegistry(ttl: env.config.watcher.selfChangeTTLSeconds, time: env.time),
                                     database: env.database)
        let first = await watcher.changes()
        let reading = Task { for await _ in first {} }
        try await watcher.start(root: env.archive, excluding: [env.incoming])
        await watcher.stop()
        reading.cancel()
        await reading.value

        let reported = Reported()
        let again = await watcher.changes()
        let collecting = Task { for await changes in again { await reported.add(changes) } }
        defer { collecting.cancel() }
        try await watcher.start(root: env.archive, excluding: [env.incoming])
        defer { await watcher.stop() }
        let note = try env.put("note.txt", text: "put there by the user")
        await watcher.handle([FSEvent(path: note.path, flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated), id: 1)])
        #expect(await Patience.until { await reported.changes.contains(.untrackedFile(path: note.path)) },
                "a file the user puts in the archive once its watcher is started again is reported to the new reader")
    }

    @Test func theWatchersBoundsAreRefusedWhereTheyMakeNoSense() throws {
        var config = try PipelineConfig.bundledDefaults()
        #expect(config.problems.isEmpty, "the bundled watcher settings are sound")
        config.watcher.unopenableWaitSeconds = -1
        config.watcher.maxPackageItems = 0
        #expect(config.problems.contains("watcher.unopenableWaitSeconds cannot be negative")
                    && config.problems.contains("watcher.maxPackageItems must be at least 1"), "\(config.problems)")
    }

    @Test func workPausesWhenTheMacIsHotOrItsBatteryLow() throws {
        let config = try PipelineConfig.bundledDefaults().power
        var settings = try AppSettings.bundledDefaults()
        let cool = PowerState(onBattery: false, batteryPercent: nil, thermal: .nominal, lowPowerMode: false)
        #expect(cool.pauseReason(settings: settings, config: config) == nil, "on power and cool, work goes on")
        let hot = PowerState(onBattery: false, batteryPercent: nil, thermal: config.pauseAtThermalState, lowPowerMode: false)
        #expect(hot.pauseReason(settings: settings, config: config) == "thermal state \(config.pauseAtThermalState.rawValue)",
                "at power.pauseAtThermalState, it waits, and says why")
        let low = PowerState(onBattery: true, batteryPercent: config.pauseBelowBatteryPercent - 1, thermal: .nominal, lowPowerMode: false)
        #expect(low.pauseReason(settings: settings, config: config) == "battery at \(config.pauseBelowBatteryPercent - 1)%",
                "on a battery below power.pauseBelowBatteryPercent, it waits, and says why")
        settings.pauseOnBattery = false
        #expect(low.pauseReason(settings: settings, config: config) == nil, "unless the user turned that off")
        let charged = PowerState(onBattery: true, batteryPercent: config.pauseBelowBatteryPercent, thermal: .nominal, lowPowerMode: false)
        settings.pauseOnBattery = true
        #expect(charged.pauseReason(settings: settings, config: config) == nil, "at the limit itself, work goes on")
    }

    /// An event FSEvents reports for a file that came, at its path as the disk spells it.
    static func created(_ file: URL) -> FSEvent {
        FSEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated), id: 1)
    }

    /// The paths of the files taken in, in the order they were.
    static func paths(_ arrivals: [IncomingArrival]) -> [String] {
        arrivals.compactMap { if case let .stable(url) = $0 { url.path } else { nil } }
    }

    static func paths(_ arrival: IncomingArrival) -> [String] { paths([arrival]) }
}

/// The names of the files the Incoming watcher took in.
actor Taken {
    private(set) var names: Set<String> = []
    func add(_ arrival: IncomingArrival) {
        if case let .stable(url) = arrival { names.insert(url.lastPathComponent) }
    }
}

/// What the archive watcher reported, in the order it reported it.
actor Reported {
    private(set) var changes: [ArchiveChange] = []
    func add(_ batch: [ArchiveChange]) { changes += batch }
}

/// A scratch folder and the bundled configuration, for tests that need no database. Its path is spelled as the file
/// system spells it (`URL.canonicalFolderPath`), as FSEvents reports paths, so an event a test makes up is one FSEvents
/// could send.
struct TestEnvironmentSync {
    let root: URL
    let config: PipelineConfig

    static func make() throws -> TestEnvironmentSync {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let canonical = root.canonicalFolderPath else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path]) }
        return TestEnvironmentSync(root: URL(fileURLWithPath: canonical, isDirectory: true), config: try PipelineConfig.bundledDefaults())
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// The folder at `path` below the root, made.
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file at `path` below the root, with the folders it needs.
    func file(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a document".utf8).write(to: url)
        return url
    }

    /// An Incoming watcher on `time`, whose passes a test makes itself (`IncomingWatcher.poll()`): on a time that
    /// blocks, as by default, its own polling never makes one.
    func watcher(time: TestTime = TestTime(.blocks)) -> IncomingWatcher {
        IncomingWatcher(config: config.watcher, skip: SkipRules(watcher: config.watcher), time: time)
    }
}
