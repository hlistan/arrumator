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
        try await watcher.start(root: incoming)
        defer { Task { await watcher.stop() } }
        var files = watcher.stableFiles.makeAsyncIterator()
        let stable = await files.next()
        #expect(stable?.lastPathComponent == "bill.pdf", "the document, once unchanged, and not the system file")
        let waited = time.now().timeIntervalSince(TestTime.start)
        let polls = Double(env.config.watcher.stabilityRequiredPolls)
        #expect(waited >= polls * env.config.watcher.stabilityPollInterval,
                "it was taken only after unchanged for watcher.stabilityRequiredPolls polls, so a copy in progress is never read half")
    }

    @Test func aFolderMovedIntoIncomingIsTakenInWithEverythingInIt() async throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = env.root.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let watcher = IncomingWatcher(config: env.config.watcher, skip: SkipRules(watcher: env.config.watcher), time: TestTime(.advances))
        try await watcher.start(root: incoming)
        defer { Task { await watcher.stop() } }
        let taken = Taken()
        let collecting = Task { for await url in watcher.stableFiles { await taken.add(url.lastPathComponent) } }
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
}

/// The names of the files the Incoming watcher took in.
actor Taken {
    private(set) var names: Set<String> = []
    func add(_ name: String) { names.insert(name) }
}

/// A scratch folder and the bundled configuration, for tests that need no database.
struct TestEnvironmentSync {
    let root: URL
    let config: PipelineConfig

    static func make() throws -> TestEnvironmentSync {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TestEnvironmentSync(root: root.resolvingSymlinksInPath(), config: try PipelineConfig.bundledDefaults())
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
