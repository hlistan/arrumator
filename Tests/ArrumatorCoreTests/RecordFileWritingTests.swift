@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// Writing a record file from the index never writes over what reached the file after it was read, and two writings
/// never overlap (docs/storage.md): what a test does between reading a file and writing it (`setBeforeWriting`) is what
/// the user or another process could do at that moment.
@Suite struct RecordFileWritingTests {
    /// Runs `change` the first time a flush is between reading the file at `url` and writing it.
    private func once(at url: URL, _ change: @escaping @Sendable () throws -> Void) -> @Sendable (URL) async -> Void {
        let done = Mutex(false)
        return { written in
            guard written.standardizedFileURL.path == url.standardizedFileURL.path,
                  done.withLock({ done in defer { done = true }; return !done }) else { return }
            try? change()
        }
    }

    @Test func anEditMadeWhileAFileIsWrittenIsNeverWrittenOver() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        // The user corrects a label in the very file the flush has just read.
        await w.records.setBeforeWriting(once(at: w.topListing) { _ = try w.editLabelByHand() })
        try await w.records.flush()
        let text = try String(contentsOf: w.topListing, encoding: .utf8)
        #expect(text.contains("value: Maria Silva") && text.contains("file: edp_september.txt"),
                "the edit is read back first, and the file then holds both it and the change of the index")
        let parties = try await w.h.services.documents.list(DocumentFilter(), limit: 5).flatMap { $0.labels(.party) }
        #expect(parties.contains("Maria Silva"), "and the edit is the document's")
    }

    @Test func aFileEditedWhileItIsRemovedIsNeverRemoved() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let rule = try await w.h.labels.merge(DocumentLabel(kind: .sender, value: "EDP Comercial"), into: "EDP")
        try await w.records.flush()
        let url = w.h.env.layout.labelRules
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "target: EDP\n", with: "target: EDP Energia\n")
        try await w.h.labels.forget(rule: try #require(rule.rule?.id))
        // With no rule left, the flush removes the file, which the user edits just then.
        await w.records.setBeforeWriting(once(at: url) { try edited.write(to: url, atomically: true, encoding: .utf8) })
        try await w.records.flush()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("target: EDP Energia"), "the file the user edited is not removed")
        #expect(try await w.h.services.labels.rules().map(\.target) == ["EDP Energia"], "and the rule they wrote is read back")
    }

    @Test func noOtherWriterOfTheIndexCanActBetweenAFileTakingItsNewTextAndItsChecksumBeingKept() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        // An index on disk, which another process opens as a connection of its own.
        let (database, records) = try w.newIndex()
        try #require(try await records.rebuildIfPending() != nil)
        _ = try await LabelActions(database: database, time: TestTime(.advances)).merge(DocumentLabel(kind: .sender, value: "EDP Comercial"),
                                                                                        into: "EDP")
        let path = database.writer.path
        let others = Mutex<[Bool]>([])
        await records.setAfterReplacing { _ in
            // Another process starts a write of its own, without waiting for the lock.
            let wrote = (try? DatabaseQueue(path: path).writeWithoutTransaction { db -> Bool in
                try db.execute(sql: "BEGIN IMMEDIATE")
                try db.execute(sql: "ROLLBACK")
                return true
            }) ?? false
            others.withLock { $0.append(wrote) }
        }
        try await records.flush()
        let tried = others.withLock { $0 }
        #expect(!tried.isEmpty && !tried.contains(true),
                "while a file holds new text whose checksum is not kept yet, no other process can write to the index: \(tried)")
        #expect(try String(contentsOf: w.topListing, encoding: .utf8).contains("value: EDP\n"), "and the file is written")
    }

    @Test func aRecordFilesStagedTextACrashLeftIsRemovedWhenTheArchiveIsReadAndNothingElseIs() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let archive = w.h.env.archive
        let list = w.h.env.config.records.documentsFileName
        let uuid = "2F1C6C1E-8D4B-4C2A-9E57-3B1D2A6F0C11"
        // What a crash between writing a record file's text beside it and its rename leaves, beside the list and the
        // history, and in a folder whose list was never written.
        let staged = [archive.appendingPathComponent(".\(uuid).\(list)"),
                      w.h.env.layout.history.appendingPathComponent(".\(uuid).\(w.h.env.config.watcher.managedFilePrefix)2026-07.md"),
                      try w.h.env.put("Bills/.\(uuid).\(list)", text: "staged")]
        // Files of the user's, hidden or not, that only look alike.
        let theUsers = [try w.h.env.put(".not-a-uuid.\(list)", text: "mine"), try w.h.env.put(".\(uuid).notes.md", text: "mine"),
                        try w.h.env.put("\(uuid).\(list)", text: "mine"), try w.h.env.put("Bills/.\(list)", text: "mine")]
        for url in staged.prefix(2) { try Data("staged".utf8).write(to: url) }
        // Written before the crash, longer ago than another process's staged text could still be in use.
        let long = w.h.env.time.now().addingTimeInterval(-(w.h.env.config.records.stagedLeftoverMinutes + 1) * Units.secondsPerMinute)
        for url in staged { try FileManager.default.setAttributes([.modificationDate: long], ofItemAtPath: url.path) }
        try await w.records.reconcile()
        #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "the staged text a crash left is removed")
        #expect(theUsers.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "and no file of the user's is")

        // A rebuild removes it too.
        try Data("staged".utf8).write(to: staged[0])
        try FileManager.default.setAttributes([.modificationDate: long], ofItemAtPath: staged[0].path)
        let (_, records) = try w.freshIndex()
        try await records.rebuild()
        #expect(!FileManager.default.fileExists(atPath: staged[0].path) && theUsers.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                "when the archive is read for a rebuild as well")
    }

    @Test func aRecordFilesStagedTextYoungerThanTheLeftoverAgeIsLeftForTheProcessThatStagedIt() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let age = w.h.env.config.records.stagedLeftoverMinutes * Units.secondsPerMinute
        let now = w.h.env.time.now()
        let young = w.h.env.archive.appendingPathComponent(".2F1C6C1E-8D4B-4C2A-9E57-3B1D2A6F0C11.\(w.h.env.config.records.documentsFileName)")
        try Data("staged".utf8).write(to: young)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age / 2)], ofItemAtPath: young.path)
        try await w.records.reconcile()
        let (_, records) = try w.freshIndex()
        try await records.rebuild()
        #expect(FileManager.default.fileExists(atPath: young.path), "staged text written less long ago may be another process's: it is left")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age * 2)], ofItemAtPath: young.path)
        try await w.records.reconcile()
        #expect(!FileManager.default.fileExists(atPath: young.path), "once older than the leftover age, it is a crash's, and removed")
    }

    @Test func aReadBackWhileAnotherProcessHasStagedARecordFileLeavesItsWriteToSucceed() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        // Another process, as the app beside a command that flushes, with an index of its own here, reads the archive back
        // while the command's new text is staged and not yet in its file's place.
        let (_, other) = try w.freshIndex()
        try await other.rebuild()
        let readBack = Mutex(false)
        let (now, watcher) = (w.h.env.time.now(), w.h.env.config.watcher)
        await w.records.setAfterStaging { url in
            guard readBack.withLock({ done in defer { done = true }; return !done }) else { return }
            // Staged just now, by the clock both processes read.
            let folder = url.deletingLastPathComponent()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where StagedRecordFile.isStaged(name, watcher: watcher) {
                try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: folder.appendingPathComponent(name).path)
            }
            _ = try? await other.reconcile()
        }
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        try await w.records.flush()
        #expect(readBack.withLock { $0 }, "the other process read the archive back between the staging and the rename")
        #expect(try String(contentsOf: w.topListing, encoding: .utf8).contains("file: edp_september.txt"),
                "and the write whose staged text it found still takes its file's place")
    }

    @Test func aRecordFilesStagedTextIsNeverADocumentWhateverTheWatcherIgnores() async throws {
        var config = try PipelineConfig.bundledDefaults()
        // Hidden files no longer left out by their name.
        config.watcher.ignoredNamePrefixes.removeAll { $0.hasPrefix(".") }
        let skip = SkipRules(watcher: config.watcher)
        let name = ".2F1C6C1E-8D4B-4C2A-9E57-3B1D2A6F0C11.\(config.records.documentsFileName)"
        #expect(skip.ignoreReason(name: name) != nil, "a record file's staged text is never taken for a document")
        let sidecar = StagedRecordFile.sidecarURL(for: URL(fileURLWithPath: "/A/fatura.pdf\(config.watcher.sidecarSuffix)"), watcher: config.watcher)
        #expect(StagedRecordFile.isStaged(sidecar.lastPathComponent, watcher: config.watcher) && skip.ignoreReason(name: sidecar.lastPathComponent) != nil,
                "nor is a sidecar's, named without its document's so a long name leaves it room, and removed once a crash has left it long enough")
        #expect(!StagedRecordFile.isStaged(".2F1C6C1E-8D4B-4C2A-9E57-3B1D2A6F0C11.notes.md", watcher: config.watcher),
                "while a hidden file of the user's that only looks like one is not")
        #expect(skip.ignoreReason(name: ".notes.txt") == nil, "while a hidden file of the user's is read as the settings say")
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondFlushWaitsUntilTheFirstHasWritten() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        let hold = Hold()
        await w.records.setBeforeWriting { _ in await hold.arrive() }
        let first = Task { try await w.records.flush() }
        #expect(await Patience.until { hold.arrivals == 1 }, "the first flush has read the file and is about to write it")
        let second = Task { try await w.records.flush() }
        let waiting = await Patience.until { await w.records.waitingTurns == 1 || hold.arrivals > 1 }
        #expect(waiting && hold.arrivals == 1, "the second waits for its turn, rather than reading the file the first is writing")
        hold.open()
        _ = try await first.value
        _ = try await second.value
        #expect(try String(contentsOf: w.topListing, encoding: .utf8).contains("file: edp_september.txt"), "and both end with the file written")
        #expect(try await RecordsWorld.marks(w.h.env.database).isEmpty, "and nothing left to write")
    }
}
