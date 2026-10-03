@testable import ArrumatorCore
@testable import ArrumatorRuntime
import ArrumatorTesting
import Foundation
import Testing

/// The running app watches its archive: what the user puts there is taken in once it has stopped changing, and the
/// archive's events are resumed after the last one whose changes were applied, so a change a stop or a failure kept from
/// being applied is reported again at the next start.
@Suite struct ArchiveWatchingTests {
    @Test func aFilePutIntoTheArchiveWhileTheAppRunsIsTakenIn() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try home.watchQuickly()
        let runtime = try await home.open()
        await runtime.start()
        let letter = home.folder("First").appendingPathComponent(Self.letter)
        try Data(Self.text.utf8).write(to: letter)
        #expect(try await Patience.until { try await adopted(runtime).contains { $0.hasPrefix(Self.letter) } },
                "FSEvents reports it, the watcher waits until it has stopped changing, and the reconciler takes it in")
        await runtime.stop()
    }

    /// What keeps a change from being applied.
    enum Interruption: CaseIterable, Sendable {
        /// The app stops while it is applied.
        case stop
        /// It cannot be applied.
        case failure
    }

    @Test(arguments: Interruption.allCases)
    func aChangeNotAppliedIsReportedAgainAtTheNextStart(_ interruption: Interruption) async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try home.watchQuickly()
        let first = try await home.open()
        let letter = home.folder("First").appendingPathComponent(Self.letter).standardizedFileURL
        let reached = Signal()
        await first.reconciler.setBeforeApplying { change in
            guard change == .found(path: letter.path) else { return }
            reached.fire()
            switch interruption {
            // Waits until the app stops, which cancels it.
            case .stop: try await TestTime(.blocks).sleep(seconds: 0)
            case .failure: throw NotApplied()
            }
        }
        await first.start()
        #expect(try await Patience.until { try await first.database.meta(ArchiveWatcher.lastEventKey) != nil },
                "watched for the first time, the archive is watched from now on, which is saved at once")
        try Data(Self.text.utf8).write(to: letter)
        try #require(await Patience.until { reached.fired }, "the letter is reported, and its change is being applied")
        let saved = try await first.database.meta(ArchiveWatcher.lastEventKey)
        if interruption == .failure {
            #expect(try await Patience.until { try await failures(first).contains { $0.contains(letter.path) } },
                    "a change that cannot be applied is said so in History, naming where")
        }
        await first.stop()
        let savedAfter = try await first.database.meta(ArchiveWatcher.lastEventKey)
        let applied = try await adopted(first)
        #expect(savedAfter == saved && applied.isEmpty, "nothing after the change is saved as applied, as it was not")

        let second = try await home.open()
        await second.start()
        #expect(try await Patience.until { try await adopted(second).contains { $0.hasPrefix(Self.letter) } },
                "the next start reports it again, as the events after the last applied are, and it is applied")
        await second.stop()
    }

    @Test func aRuleMadeWhileAnotherFolderIsTheArchiveIsKeptWhenTheEarlierOneIsBack() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try home.watchQuickly()
        let runtime = try await home.open()
        await runtime.start()
        _ = try await runtime.labels.ignore(DocumentLabel(kind: .topic, value: "electricity"))
        try await runtime.records.flush()
        // The archive's disk taken out, and a folder made at its path, which the app takes as the archive.
        try FileManager.default.moveItem(at: home.folder("First"), to: home.folder("Earlier"))
        try FileManager.default.createDirectory(at: home.folder("First"), withIntermediateDirectories: true)
        #expect(try await Patience.until { try await said(runtime).contains { $0.contains("another folder than before") } },
                "the other folder is taken as the archive, which History says")
        _ = try await runtime.labels.ignore(DocumentLabel(kind: .topic, value: "water"))
        let rules = home.folder("First").appendingPathComponent(runtime.config.records.systemFolderName)
            .appendingPathComponent(runtime.config.records.labelRulesFileName)
        try #require(await Patience.until { (try? String(contentsOf: rules, encoding: .utf8))?.contains("water") == true },
                     "the rule made meanwhile is written into the folder that is the archive then")
        try #require(try await Patience.until {
            try await runtime.database.reader.read { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM record_dirty WHERE key = ?)", arguments: [RecordKind.labelRules.key]) == false
            }
        }, "and nothing of it waits to be written any more")
        // The earlier folder back, its rules file holding the first rule alone.
        try FileManager.default.moveItem(at: home.folder("First"), to: home.folder("Other"))
        try FileManager.default.moveItem(at: home.folder("Earlier"), to: home.folder("First"))
        #expect(try await Patience.until { try await said(runtime).contains { $0.contains("earlier folder") } }, "it is said to be back")
        #expect(await Patience.until { (try? String(contentsOf: rules, encoding: .utf8))?.contains("water") == true },
                "its record files are merged with what was kept meanwhile, and the rule made then is written into it")
        #expect(try await runtime.database.reader.read { db in try LabelRule.fetchCount(db) } == 2, "both rules are kept")
        await runtime.stop()
    }

    private func said(_ runtime: ArrumatorRuntime) async throws -> [String] {
        try await runtime.services.history.events(limit: 20, kinds: [.error]).map(\.summary)
    }

    struct NotApplied: LocalizedError {
        var errorDescription: String? { "not applied, as the test asks" }
    }

    static let letter = "letter.txt"
    static let text = "a letter put into the archive by hand"

    private func adopted(_ runtime: ArrumatorRuntime) async throws -> [String] {
        try await runtime.services.history.events(limit: 10, kinds: [.adopted]).map(\.summary)
    }

    private func failures(_ runtime: ArrumatorRuntime) async throws -> [String] {
        try await runtime.services.history.events(limit: 10, kinds: [.error]).map(\.summary)
    }
}
