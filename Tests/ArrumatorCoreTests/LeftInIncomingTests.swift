@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// A Trash that refuses one file until `mended` fires, as a share whose Trash comes back, and takes the rest into `folder`.
struct RefusingUntil: Trashing {
    let refused: URL
    let folder: FolderTrash
    let mended: Signal

    func trash(_ url: URL) throws -> URL? {
        guard mended.fired || url.spelledOnDisk.path != refused.spelledOnDisk.path else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: RefusingTrash.reason])
        }
        return try folder.trash(url)
    }
}

/// A document left in Incoming, not filed: what its card offers, what Read Again and a save of its file do with it, and
/// an archive named otherwise than the disk spells it, whose documents are its documents however their paths are spelled.
@Suite struct LeftInIncomingTests {
    static let bill = "EDP electricity July"

    /// The pipeline over `base`, every move crossing a volume when `crossing`, with `trash` as the Trash and retries due
    /// at once.
    private func pipeline(_ base: Harness, crossing: Bool, trash: (any Trashing)?, analyzer: StubAnalyzer = StubAnalyzer()) -> Harness {
        var config = base.env.config
        config.ingest.retryDelays = NonEmpty(0, [])
        let sameVolume: FileOperations.VolumeCheck = crossing ? Self.otherVolume : FileOperations.onOneVolume
        return Harness(env: base.env, services: Harness.services(base.env, analyzer: analyzer, config: config, sameVolume: sameVolume, trash: trash))
    }

    /// Every move crosses a volume.
    private static let otherVolume: FileOperations.VolumeCheck = { _, _ in false }

    private func drain(_ h: Harness) async {
        for _ in 0..<h.services.config.ingest.maxAttempts { await h.coordinator.drain() }
    }

    private func documents(_ h: Harness) async throws -> [DocumentRecord] {
        try await h.services.documents.list(DocumentFilter(), limit: 10)
    }

    @Test func readAgainOnACopyLeftInIncomingHandsItOverAndNeverFilesASecondDocument() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let original = try await base.ingest("bill.txt", text: Self.bill)
        let copy = try base.env.drop("bill copy.txt", text: Self.bill)
        let mended = Signal()
        let analyzer = StubAnalyzer()
        let h = pipeline(base, crossing: false, trash: RefusingUntil(refused: copy, folder: base.env.trash, mended: mended), analyzer: analyzer)
        await h.coordinator.enqueue(copy)
        await drain(h)
        let left = try #require(try await documents(h).first { $0.id != original.id })
        #expect(left.status == .failed && FileManager.default.fileExists(atPath: copy.path), "the copy the Trash refused is left in Incoming")
        mended.fire()
        try await h.review.retry(try #require(left.id))
        await drain(h)
        let same = try await documents(h).filter { $0.sha256 == original.sha256 && $0.status == .filed }
        #expect(same.map(\.id) == [original.id], "read again, the copy is no second document of the same bytes")
        let leftID = try #require(left.id)
        let ended = try #require(try await h.services.documents.document(id: leftID))
        #expect(ended.status == .duplicate && ended.duplicateOf == original.id, "it ends as the copy it is, of its original")
        #expect(h.env.trashed().map(\.lastPathComponent) == ["bill copy.txt"] && !FileManager.default.fileExists(atPath: copy.path),
                "and goes to the Trash, now that it takes it")
        #expect(await analyzer.calls.files == [original.filename], "its original is read again in its place")
    }

    @Test func aDocumentLeftInIncomingOffersReadAgainAndLaterNeverLooksRightOrUndo() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let filed = try await base.ingest("bill.txt", text: Self.bill)
        #expect(await base.review.choices(for: filed) == DocumentChoices(actions: [.undo, .confirm], notFiled: false),
                "a filed document can be undone or confirmed")
        let h = pipeline(base, crossing: true, trash: RefusingTrash())
        let scan = try h.env.drop("scan.txt", text: "A scan of the boiler service")
        await h.coordinator.enqueue(scan)
        await drain(h)
        let left = try #require(try await documents(h).first { $0.id != filed.id })
        #expect(await h.review.choices(for: left) == DocumentChoices(actions: [.hold, .readAgain], notFiled: true),
                "one left in Incoming can be read again or left for later, and its card says it was not filed; never Looks Right")
    }

    @Test(arguments: ["new identity", "in place"])
    func aFileLeftInIncomingSavedAgainIsTheSameDocumentArrivingAgain(_ save: String) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let bill = try base.env.drop("bill.txt", text: Self.bill)
        let mended = Signal()
        let h = pipeline(base, crossing: true, trash: RefusingUntil(refused: bill, folder: base.env.trash, mended: mended))
        await h.coordinator.enqueue(bill)
        await drain(h)
        let id = try #require(try await documents(h).first?.id)
        // Refused again after a save, still not filed: its problems are the last attempt's, never piled up.
        try Self.save(bill, save == "in place")
        await h.coordinator.enqueue(bill)
        await drain(h)
        let again = try #require(try await h.services.documents.document(id: id))
        #expect(try await documents(h).count == 1 && again.status == .failed && again.analysis?.problems.count == 1,
                "saved (\(save)), the file is the same document taken again, and its problems are this attempt's alone")
        mended.fire()
        try Self.save(bill, save == "in place")
        await h.coordinator.enqueue(bill)
        await drain(h)
        let filed = try #require(try await documents(h).first)
        #expect(try await documents(h).count == 1 && filed.id == id && filed.status == .filed,
                "saved (\(save)) once the Trash takes it, it is filed, one document, never a second beside one stuck")
        #expect(try filed.sha256 == HashService.sha256(of: filed.url), "as what the file holds now")
    }

    @Test func readAgainOnADocumentWhoseFileChangedReadsTheFileNotTheTextStoredOfIt() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let bill = try base.env.drop("bill.txt", text: Self.bill)
        let mended = Signal()
        let h = pipeline(base, crossing: true, trash: RefusingUntil(refused: bill, folder: base.env.trash, mended: mended))
        await h.coordinator.enqueue(bill)
        await drain(h)
        let id = try #require(try await documents(h).first?.id)
        try Self.save(bill, true)
        mended.fire()
        try await h.review.retry(id)
        await drain(h)
        let filed = try #require(try await h.services.documents.document(id: id))
        #expect(try filed.status == .filed && filed.sha256 == HashService.sha256(of: filed.url),
                "read again after its file changed, it is hashed and read as it is now, and filed")
    }

    /// Saves new text over `file`: in place, as an editor that writes into the file, or as a new file put in its place.
    private static func save(_ file: URL, _ inPlace: Bool) throws {
        let text = Data(" and a corrected total".utf8)
        if inPlace {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: text)
            try handle.close()
        } else {
            let saved = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).sb-save")
            try (try Data(contentsOf: file) + text).write(to: saved)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: saved)
        }
    }

    // MARK: An archive named otherwise

    @Test(arguments: ["through a link", "in another case"])
    func anArchiveNamedOtherwiseHoldsItsDocumentsHoweverTheirPathsAreSpelled(_ named: String) async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let real = base.env.archive
        let spelled: URL
        if named == "through a link" {
            spelled = base.env.root.appendingPathComponent("My Archive", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: spelled, withDestinationURL: real)
        } else {
            guard Volume.ignoresCase else { return }
            spelled = base.env.root.appendingPathComponent("ARCHIVE", isDirectory: true)
        }
        // The runtime's archive, as the settings name it.
        var services = pipeline(base, crossing: false, trash: nil).services
        services.archive = spelled
        let h = Harness(env: base.env, services: services)
        let doc = try await h.ingest("bill.txt", text: Self.bill)
        let id = try #require(doc.id)
        // Renamed in Finder; the archive watcher reports the new path as the disk spells it.
        let renamed = doc.url.deletingLastPathComponent().appendingPathComponent("Renamed by me.txt")
        try FileManager.default.moveItem(at: doc.url, to: renamed)
        try await ArchiveReconciler(services: h.services, coordinator: h.coordinator)
            .apply([.found(path: renamed.spelledOnDisk.standardizedFileURL.path), .gone(path: doc.path)])
        let moved = try #require(try await h.services.documents.document(id: id))
        #expect(h.services.isInArchive(moved), "renamed (\(named)), it is in the archive")
        #expect(try await h.services.documents.existing(sha256: moved.sha256, excluding: nil, archive: spelled)?.id == id,
                "the original of a copy of it")
        let plan = SearchPlan(title: "", labels: [DocumentLabel(kind: .sender, value: "EDP Comercial")], words: [], grouping: [])
        #expect(try await SearchPlanMatcher(database: h.env.database, archive: spelled, limit: 10).documents(plan) == [id],
                "and what a search task finds")
        await h.coordinator.enqueue(try h.env.drop("bill copy.txt", text: Self.bill))
        await h.coordinator.drain()
        let (all, copies) = (try await documents(h), try await h.services.history.events(limit: 5, kinds: [.duplicate]))
        #expect(all.count == 1 && copies.map(\.docId) == [id],
                "so a copy dropped into Incoming is handed over to it, never a second document")
        await drain(h)
        let read = try #require(try await h.services.documents.document(id: id))
        #expect(read.status == .filed && FileManager.default.fileExists(atPath: read.path) && h.services.isInArchive(read),
                "and read again where its path is spelled as the disk spells it, it is renamed where it is, never failed")
    }

    @Test func aDocumentLeftInIncomingIsToldByWhereItIsNotByHowItsProblemIsWorded() async throws {
        let base = try await Harness.make()
        defer { base.env.cleanup() }
        let h = pipeline(base, crossing: true, trash: RefusingTrash())
        let bill = try h.env.drop("bill.txt", text: Self.bill)
        await h.coordinator.enqueue(bill)
        await drain(h)
        var left = try #require(try await documents(h).first)
        left.analysisJson = try JSON.string(DocumentAnalysis(problems: ["Worded otherwise"]))
        _ = try await h.services.documents.save(left)
        #expect(await h.coordinator.enqueue(bill) == nil, "however its problem is worded, a rescan leaves the file it is alone")
        #expect(await h.review.choices(for: left).notFiled, "and its card still says it was not filed")
    }
}
