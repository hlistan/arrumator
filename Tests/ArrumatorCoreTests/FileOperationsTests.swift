@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// Writes a package, a folder macOS shows as one document, at `url`: each file at its path in it, in the order given,
/// with the folders it needs.
@discardableResult
func writePackage(_ url: URL, _ files: [(path: String, text: String)]) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for file in files {
        let target = url.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(file.text.utf8).write(to: target)
    }
    return url
}

/// An `.rtfd` as TextEdit saves one: its text, and a picture beside it.
let notesPackage: [(path: String, text: String)] = [("TXT.rtf", "{\\rtf1 a note about the boiler}"), ("Pictures/boiler.png", "a picture")]

/// A Trash that refuses what is in the folders `refusing`, as that of a volume without one, however a path to it is
/// spelled, and takes the rest into `folder`.
struct PickyTrash: Trashing {
    let refusing: [URL]
    let folder: FolderTrash

    func trash(_ url: URL) throws -> URL? {
        let path = url.spelledOnDisk.path
        guard !refusing.contains(where: { path.hasPrefix($0.spelledOnDisk.path + "/") }) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: RefusingTrash.reason])
        }
        return try folder.trash(url)
    }
}

/// How the app knows a file and a package on disk, and moves them: what a package holds is the package, which is weighed
/// and hashed by what it holds; a move to another volume is a checked copy whose source goes to the Trash the app was
/// given, and that leaves no second copy and no copy in progress when it fails; a file changed since it was read is not
/// moved.
@Suite struct FileOperationsTests {
    // MARK: Packages

    @Test func aPathInsideAPackageIsThePackage() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let root = env.root
        let notes = try writePackage(root.appendingPathComponent("Notes.rtfd"), notesPackage)
        let picture = notes.appendingPathComponent("Pictures/boiler.png")
        #expect(Packages.document(holding: picture, under: root).path == notes.path, "a file at any depth in a package is the package")
        #expect(Packages.document(holding: notes, under: root).path == notes.path, "and a package is itself")
        let filed = try writePackage(root.appendingPathComponent("Taxes 2024/Notes.rtfd"), notesPackage)
        #expect(Packages.document(holding: filed.appendingPathComponent("TXT.rtf"), under: root).path == filed.path,
                "a package in a folder of the user's is the document, not the folder")
        let inner = try writePackage(notes.appendingPathComponent("Old.rtfd"), notesPackage)
        #expect(Packages.document(holding: inner.appendingPathComponent("TXT.rtf"), under: root).path == notes.path,
                "a package in a package is part of the outer one, the document Finder shows")
        let loose = root.appendingPathComponent("Taxes 2024/scan.pdf")
        #expect(Packages.document(holding: loose, under: root) == loose, "a file of its own is its own document")
        let gone = root.appendingPathComponent("Gone.rtfd/TXT.rtf")
        #expect(Packages.document(holding: gone, under: root).path == root.appendingPathComponent("Gone.rtfd").path,
                "what a package that is gone held is still the package, as its extension declares a package type")
        #expect(Packages.document(holding: root.appendingPathComponent("Gone.qqzz/a.txt"), under: root).lastPathComponent == "a.txt",
                "while a folder of an extension no type declares is no package")
        let elsewhere = URL(fileURLWithPath: "/Elsewhere/Notes.rtfd/TXT.rtf")
        #expect(Packages.document(holding: elsewhere, under: root) == elsewhere, "nothing outside the root is looked into")
    }

    @Test func aPackageIsWeighedByWhatItHoldsAndChangesWithIt() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let notes = try writePackage(env.root.appendingPathComponent("Notes.rtfd"), notesPackage)
        let picture = notes.appendingPathComponent("Pictures/boiler.png")
        let (earlier, later) = (TestTime.start.addingTimeInterval(-86400), TestTime.start)
        for item in [notes, notes.appendingPathComponent("Pictures"), picture, notes.appendingPathComponent("TXT.rtf")] {
            try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: item.path)
        }
        let first = try FileFingerprint.of(notes)
        #expect(first.size == Int64(notesPackage.map(\.text.utf8.count).reduce(0, +)) && first.modified == earlier,
                "a package's size is that of the files it holds, at any depth, not the folder's own")
        try Data("a larger picture".utf8).write(to: picture)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: picture.path)
        let grown = try FileFingerprint.of(notes)
        #expect(grown.size > first.size && grown.modified == later,
                "writing into a file deep in it changes the package: its size and its latest change, which is the file's")
        #expect(grown.inode == first.inode, "while it is the same package on the volume")
    }

    @Test func aPackageIsHashedByWhatItHoldsTheSameForACopyWhereverAndHoweverItsNamesAreWritten() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let notes = try writePackage(env.root.appendingPathComponent("Notes.rtfd"), notesPackage)
        let digest = try HashService.sha256(of: notes)
        #expect(digest.count == 64 && digest.allSatisfy(\.isHexDigit), "a package has a SHA-256 as a file does")
        #expect(try HashService.sha256(of: notes) == digest, "the same each time it is taken")
        let other = try writePackage(env.root.appendingPathComponent("elsewhere/Renamed.rtfd"), notesPackage.reversed())
        #expect(try HashService.sha256(of: other) == digest,
                "a package that holds the same, under another name and written in another order, is the same document")
        let copy = env.root.appendingPathComponent("copy/Notes.rtfd")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: notes, to: copy)
        #expect(try HashService.sha256(of: copy) == digest, "and so is a copy of it")
        let composed = try writePackage(env.root.appendingPathComponent("composed/A.rtfd"), [("Fatura\u{00E7}\u{00E3}o.rtf", "x")])
        let decomposed = try writePackage(env.root.appendingPathComponent("decomposed/A.rtfd"), [("Faturac\u{0327}a\u{0303}o.rtf", "x")])
        #expect(try HashService.sha256(of: composed) == HashService.sha256(of: decomposed),
                "a name written decomposed, as another volume may write it, hashes as the same name composed")
        try Data("{\\rtf1 another note}".utf8).write(to: other.appendingPathComponent("TXT.rtf"))
        #expect(try HashService.sha256(of: other) != digest, "a change to what a file in it says makes another document")
        try FileManager.default.moveItem(at: copy.appendingPathComponent("TXT.rtf"), to: copy.appendingPathComponent("Text.rtf"))
        #expect(try HashService.sha256(of: copy) != digest, "and so does a file in it renamed")
        try FileManager.default.createDirectory(at: notes.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        #expect(try HashService.sha256(of: notes) != digest, "or a folder added to it")
        let folder = try writePackage(env.root.appendingPathComponent("Taxes 2024"), notesPackage)
        #expect(throws: (any Error).self, "while a folder that is no package is no document, and has no hash of one") {
            try HashService.sha256(of: folder)
        }
    }

    // MARK: Moving

    /// A file of `text` at `name` in a folder of its own, as in Incoming, and the folder it is moved into, as the archive.
    private func setUp(_ env: TestEnvironmentSync, _ name: String = "scan.pdf",
                       text: String = "a whole document") throws -> (source: URL, archive: URL) {
        let incoming = env.root.appendingPathComponent("Incoming", isDirectory: true)
        let archive = env.root.appendingPathComponent("Archive", isDirectory: true)
        for folder in [incoming, archive] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let source = incoming.appendingPathComponent(name)
        try Data(text.utf8).write(to: source)
        return (source, archive)
    }

    private func folderTrash(_ env: TestEnvironmentSync) -> FolderTrash {
        FolderTrash(folder: env.root.appendingPathComponent("Trash", isDirectory: true))
    }

    /// Everything in `folder`, by name.
    private func names(in folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// The names of what `trash` holds, at any depth.
    private func trashed(_ trash: FolderTrash) -> [String] {
        let all = FileManager.default.enumerator(at: trash.folder, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants])
        return (all?.allObjects as? [URL] ?? []).filter { $0.deletingLastPathComponent().deletingLastPathComponent().path == trash.folder.path }
            .map(\.lastPathComponent)
    }

    /// Every move crosses a volume.
    private static let otherVolume: FileOperations.VolumeCheck = { _, _ in false }

    @Test func aMoveToAnotherVolumeIsACheckedCopyWhoseSourceGoesToTheTrashTheAppWasGiven() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let (source, archive) = try setUp(env)
        let dated = Date(timeIntervalSince1970: TestTime.start.timeIntervalSince1970 - 86400)
        try FileManager.default.setAttributes([.modificationDate: dated], ofItemAtPath: source.path)
        let sha = try HashService.sha256(of: source)
        let trash = folderTrash(env)
        let operations = FileOperations(trash: trash, sameVolume: Self.otherVolume)
        let destination = archive.appendingPathComponent("2026-07-05 EDP - Fatura.pdf")
        let result = try operations.move(source, to: destination, within: archive, collision: nil, expectedSHA256: sha, fingerprint: nil)
        #expect(result.crossVolume && result.to == destination.path, "across volumes the move is a copy")
        #expect(try HashService.sha256(of: destination) == sha, "the copy holds the document's bytes")
        #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date == dated,
                "and its dates")
        #expect(!FileManager.default.fileExists(atPath: source.path) && trashed(trash) == ["scan.pdf"],
                "the source went to the Trash the app was given (ARRUMATOR_TRASH, a folder in tests), never to the user's")
        #expect(try names(in: archive) == [destination.lastPathComponent], "and no copy in progress is left beside the document")
    }

    @Test func aSourceTheTrashRefusesStaysWhereItWasAndItsCopyIsTakenBackSoARetryMakesNoSecond() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let (source, archive) = try setUp(env)
        let trash = folderTrash(env)
        let operations = FileOperations(trash: PickyTrash(refusing: [source.deletingLastPathComponent()], folder: trash),
                                        sameVolume: Self.otherVolume)
        for attempt in 1...2 {
            let (destination, collision) = try FilenameBuilder(config: try PipelineConfig.bundledDefaults().naming,
                                                               reserved: SkipRules(watcher: env.config.watcher))
                .uniqueDestination(directory: archive, filename: "Fatura.pdf")
            #expect(destination.lastPathComponent == "Fatura.pdf" && collision == nil,
                    "attempt \(attempt): the name is free, as nothing was left of the attempt before, so no “Fatura (2).pdf”")
            #expect("attempt \(attempt): the move fails, saying the Trash would not take the file") {
                try operations.move(source, to: destination, within: archive, collision: collision, expectedSHA256: nil, fingerprint: nil)
            } throws: { error in
                guard case .sourceNotTrashed(source.path, RefusingTrash.reason, nil)? = error as? FileOperationError else { return false }
                return true
            }
            #expect(FileManager.default.fileExists(atPath: source.path), "attempt \(attempt): the file stays where it was")
            #expect(try names(in: archive).isEmpty, "attempt \(attempt): and its copy is not left in the archive, nor one in progress")
        }
        #expect(trashed(trash) == ["Fatura.pdf", "Fatura.pdf"], "each copy taken back went to the Trash, never deleted")
    }

    @Test func aCopyTheTrashRefusesTooIsNamedWhereItStays() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let (source, archive) = try setUp(env)
        let destination = archive.appendingPathComponent("Fatura.pdf")
        let operations = FileOperations(trash: RefusingTrash(), sameVolume: Self.otherVolume)
        #expect("a copy that cannot be taken back is not left unsaid") {
            try operations.move(source, to: destination, within: archive, collision: nil, expectedSHA256: nil, fingerprint: nil)
        } throws: { error in
            guard case .sourceNotTrashed(source.path, RefusingTrash.reason, destination.path)? = error as? FileOperationError else { return false }
            return true
        }
        #expect(FileManager.default.fileExists(atPath: source.path) && FileManager.default.fileExists(atPath: destination.path),
                "neither is deleted: the error names both")
    }

    @Test func aCopyThatCannotBePutInPlaceLeavesNoCopyInProgress() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let (source, archive) = try setUp(env)
        let taken = archive.appendingPathComponent("Fatura.pdf")
        try Data("another document, which took the name meanwhile".utf8).write(to: taken)
        let trash = folderTrash(env)
        let operations = FileOperations(trash: trash, sameVolume: Self.otherVolume)
        #expect(throws: (any Error).self, "a name taken between choosing it and moving there is never written over") {
            try operations.move(source, to: taken, within: archive, collision: nil, expectedSHA256: nil, fingerprint: nil)
        }
        #expect(try names(in: archive) == ["Fatura.pdf"], "the copy in progress is removed, not left beside the document for good")
        #expect(try String(contentsOf: taken, encoding: .utf8).hasPrefix("another document"), "what was there is as it was")
        #expect(FileManager.default.fileExists(atPath: source.path) && trashed(trash).isEmpty, "and the source stays, out of the Trash")
    }

    @Test func aCopyThatFailsItsCheckLeavesNothingBehind() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let (source, archive) = try setUp(env)
        let operations = FileOperations(trash: folderTrash(env), sameVolume: Self.otherVolume)
        #expect("a copy that does not hash as the document read is no copy of it") {
            try operations.move(source, to: archive.appendingPathComponent("Fatura.pdf"), within: archive, collision: nil,
                                expectedSHA256: String(repeating: "0", count: 64), fingerprint: nil)
        } throws: { error in
            guard case .verificationFailed(source.path)? = error as? FileOperationError else { return false }
            return true
        }
        #expect(try names(in: archive).isEmpty && FileManager.default.fileExists(atPath: source.path),
                "nothing is left in the archive and the source is where it was")
    }

    @Test func aPackageIsMovedWholeAcrossVolumes() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let (_, archive) = try setUp(env)
        let notes = try writePackage(env.root.appendingPathComponent("Incoming/Notes.rtfd"), notesPackage)
        let sha = try HashService.sha256(of: notes)
        let trash = folderTrash(env)
        let destination = archive.appendingPathComponent("2026-07-05 Boiler.rtfd")
        _ = try FileOperations(trash: trash, sameVolume: Self.otherVolume)
            .move(notes, to: destination, within: archive, collision: nil, expectedSHA256: sha, fingerprint: try FileFingerprint.of(notes))
        #expect(try HashService.sha256(of: destination) == sha, "the package is copied whole, and checked as one")
        #expect(trashed(trash) == ["Notes.rtfd"], "and the package went to the Trash as one")
    }

    // MARK: The folder a file goes into

    @Test func aMoveIntoAFolderThatIsGoneMakesNothingAndOneBelowItIsMade() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let (source, archive) = try setUp(env)
        let operations = FileOperations(trash: folderTrash(env), sameVolume: FileOperations.onOneVolume)
        let deeper = archive.appendingPathComponent("Old/2024", isDirectory: true)
        _ = try operations.move(source, to: deeper.appendingPathComponent("scan.pdf"), within: archive, collision: nil, expectedSHA256: nil,
                                fingerprint: nil)
        #expect(FileManager.default.fileExists(atPath: deeper.appendingPathComponent("scan.pdf").path), "the folders below the archive it needs are made")
        let away = env.root.appendingPathComponent("Archive renamed", isDirectory: true)
        try FileManager.default.moveItem(at: archive, to: away)
        try Data("another".utf8).write(to: source)
        #expect("the archive's folder, renamed away, is not there") {
            try operations.move(source, to: archive.appendingPathComponent("next.pdf"), within: archive, collision: nil, expectedSHA256: nil,
                                fingerprint: nil)
        } throws: { error in
            guard case .folderMissing(archive.path)? = error as? FileOperationError else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: archive.path) && FileManager.default.fileExists(atPath: source.path),
                "and is not made again where it was: the file stays where it is")
    }

    // MARK: A file changed since it was read

    @Test func aFileChangedSinceItWasReadIsNotMoved() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let (source, archive) = try setUp(env)
        let read = try FileFingerprint.of(source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" and a page more".utf8))
        try handle.close()
        let operations = FileOperations(trash: folderTrash(env), sameVolume: FileOperations.onOneVolume)
        #expect("what was read of it is not what it holds") {
            try operations.move(source, to: archive.appendingPathComponent("Fatura.pdf"), within: archive, collision: nil, expectedSHA256: nil, fingerprint: read)
        } throws: { error in
            guard case .sourceChanged(source.path)? = error as? FileOperationError else { return false }
            return true
        }
        let left = try names(in: archive)
        #expect(FileManager.default.fileExists(atPath: source.path) && left.isEmpty, "so it stays where it is")
        let now = try FileFingerprint.of(source)
        _ = try operations.move(source, to: archive.appendingPathComponent("Fatura.pdf"), within: archive, collision: nil, expectedSHA256: nil, fingerprint: now)
        #expect(try names(in: archive) == ["Fatura.pdf"], "read as it is now, it moves")
    }

    @Test func whatAJobKeepsOfAFileStillMatchesItThoughItsDatesAreKeptToTheSecond() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let (source, _) = try setUp(env)
        let withFraction = Date(timeIntervalSince1970: TestTime.start.timeIntervalSince1970 + 0.75)
        try FileManager.default.setAttributes([.modificationDate: withFraction], ofItemAtPath: source.path)
        let fingerprint = try FileFingerprint.of(source)
        var payload = JobPayload()
        (payload.size, payload.mtime, payload.inode) = (fingerprint.size, fingerprint.modified, fingerprint.inode)
        // Kept as a job's row keeps its payload (`JobRecord.setPayload`), and read back.
        let stored = try #require(JSON.decode(JobPayload.self, from: JSON.string(payload)))
        let kept = try #require(stored.fingerprint, "a job that hashed its file keeps what the file was")
        #expect(kept.modified != fingerprint.modified, "its time is kept to the second, as JSON keeps dates")
        #expect(try FileFingerprint.of(source).matches(kept), "and still matches the file it was taken of")
        #expect(!FileFingerprint(size: kept.size + 1, modified: kept.modified, inode: kept.inode).matches(kept), "another size does not")
        #expect(!FileFingerprint(size: kept.size, modified: kept.modified, inode: (kept.inode ?? 0) + 1).matches(kept),
                "nor another file in its place, of another identity")
        #expect(!FileFingerprint(size: kept.size, modified: withFraction.addingTimeInterval(1), inode: kept.inode).matches(kept),
                "nor one changed a second or more later")
        #expect(JobPayload().fingerprint == nil, "a job that did not hash its file keeps nothing to compare")
    }
}
