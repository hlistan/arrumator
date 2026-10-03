@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What the reconciler makes of an archive's folder replaced and back, of volumes that give file numbers again, and of
/// changes that fail at every start.
@Suite struct ArchiveReconcilerFolderTests {
    @Test(arguments: [true, false])
    func aDocumentFiledWhileAnotherFolderWasTheArchiveIsMissingWhenTheEarlierOneIsBack(_ itsFileIsFound: Bool) async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let first = try await h.ingest("bill.txt", text: IngestTests.bill)
        let earlier = h.env.root.appendingPathComponent("Earlier folder", isDirectory: true)
        try FileManager.default.moveItem(at: h.env.archive, to: earlier)
        try FileManager.default.createDirectory(at: h.env.archive, withIntermediateDirectories: true)
        // Filed into the other folder under the same name, which the model gives both, before the first was found missing.
        let second = try await h.ingest("receipt.txt", text: "Another bill")
        try #require(second.path == first.path, "both are recorded at one path")
        try FileManager.default.moveItem(at: h.env.archive, to: h.env.root.appendingPathComponent("Other folder", isDirectory: true))
        try FileManager.default.moveItem(at: earlier, to: h.env.archive)
        // Its file found where both are recorded, or the archive looked through for what is gone: each says so alone.
        try await h.reconciler.apply(itsFileIsFound ? [.found(path: first.path)] : [.gone(path: h.env.archive.standardizedFileURL.path)])
        let secondNow = try await h.services.documents.document(id: try #require(second.id))
        #expect(secondNow?.status == .missing, "the document whose file is not the one at its path is missing, though a file is there")
        if itsFileIsFound {
            #expect(try await h.services.documents.document(id: try #require(first.id))?.status == .filed, "and the one whose file it is is back")
        }
    }

    @Test func aCopyAndAMoveOfItsOriginalAreToldApartOnAVolumeThatGivesNumbersAgain() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let original = try await h.ingest("bill.txt", text: IngestTests.bill)
        let reconciler = h.reconciler
        await reconciler.use(ArchiveDisk(file: ArchiveDisk.disk.file, volume: ArchiveDisk.disk.volume, volumeName: ArchiveDisk.disk.volumeName,
                                         keepsFileIDs: { _ in false }))
        let copy = h.env.archive.appendingPathComponent("A copy.txt").standardizedFileURL
        try FileManager.default.copyItem(at: original.url, to: copy)
        try Xattr.set(Xattr.documentID, original.uid, on: copy)
        let moved = try h.moveIntoArchive(original.url, to: "Z/\(original.filename)")
        try await reconciler.apply([.found(path: copy.path), .found(path: moved.path), .gone(path: original.path)])
        #expect(try await h.services.documents.document(id: try #require(original.id))?.path == moved.path,
                "two files there at once never share a number, on exFAT too: the original is told from its copy in one batch")
    }

    @Test func aFileFoundAndAPathGoneAtOnePathAreCountedApart() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let failing = try h.env.put("failing.txt", text: IngestTests.bill)
        let reconciler = h.reconciler
        await reconciler.setBeforeApplying { _ in throw ArchiveReconcilerTests.Refused() }
        for _ in 1..<h.env.config.ingest.maxAttempts { _ = try await reconciler.apply([.found(path: failing.path)]) }
        #expect(try await reconciler.apply([.gone(path: failing.path)]) == false,
                "the path gone fails a first time, whatever the file found at the same path did")
    }

    @Test func aChangeThatFailsAtEveryStartIsGivenUpAfterIngestMaxAttemptsAndSaidSoTwice() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let failing = try h.env.put("failing.txt", text: IngestTests.bill)
        let reconciler = h.reconciler
        await reconciler.setBeforeApplying { change in
            if change == .found(path: failing.path) { throw ArchiveReconcilerTests.Refused() }
        }
        var outcomes: [Bool] = []
        for _ in 0..<h.env.config.ingest.maxAttempts { outcomes.append(try await reconciler.apply([.found(path: failing.path)])) }
        #expect(outcomes == Array(repeating: false, count: h.env.config.ingest.maxAttempts - 1) + [true],
                "a change that fails is applied again at each start until ingest.maxAttempts, then given up, so the saved event moves past it")
        let said = try await h.services.history.events(limit: 10, kinds: [.error]).map(\.summary)
        #expect(said.count == 2 && said.allSatisfy { $0.contains(failing.path) } && said.first?.hasPrefix("Gave up") == true,
                "History says it once when it first fails and once when it is given up, not at every start: \(said)")
        #expect(try await reconciler.apply([.found(path: failing.path)]) == false, "a later failure of it is counted afresh")
    }
}
