@testable import ArrumatorCore
@testable import ArrumatorExtract
import Foundation
import Testing

/// A search task's export as a ZIP archive (`ZipFolderArchiver`): read by other systems as the Mac reads it, every name
/// composed and marked as UTF-8 (APPNOTE.TXT 4.4.4, general purpose bit 11), whatever the disk holds.
@Suite struct FolderArchiverTests {
    /// What the archive's central directory and local headers say of one entry (APPNOTE.TXT 4.3.7, 4.3.12).
    struct Entry: Equatable {
        /// The entry's name, byte for byte as written.
        var name: [UInt8]
        /// The general purpose bit flag of its central directory record.
        var centralFlags: Int
        /// The general purpose bit flag of its local file header.
        var localFlags: Int
    }

    /// The language encoding flag: the entry's name and comment are UTF-8.
    static let utf8Flag = 1 << 11

    /// The entries of the ZIP archive at `zip`, read from its central directory and the local header each points to.
    static func entries(_ zip: URL) throws -> [Entry] {
        let bytes = [UInt8](try Data(contentsOf: zip))
        func word(_ at: Int, _ size: Int) -> Int { (0..<size).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
        var entries: [Entry] = []
        var at = 0
        while at + 46 <= bytes.count {
            guard word(at, 4) == 0x0201_4B50 else { at += 1; continue }
            let length = word(at + 28, 2), extra = word(at + 30, 2), comment = word(at + 32, 2), local = word(at + 42, 4)
            #expect(word(local, 4) == 0x0403_4B50, "each central record points to its local header")
            entries.append(Entry(name: Array(bytes[(at + 46)..<(at + 46 + length)]), centralFlags: word(at + 8, 2), localFlags: word(local + 6, 2)))
            at += 46 + length + extra + comment
        }
        return entries
    }

    @Test func everyNameIsComposedAndMarkedUTF8SoOtherSystemsReadIt() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        // A Mac may hold names decomposed (a letter, then its accent); POSIX calls write the bytes as given.
        let root = scratch.url("Contas 2025")
        let accented = "João".decomposedStringWithCanonicalMapping, receipt = "Recibo Eletrónico.txt".decomposedStringWithCanonicalMapping
        #expect(mkdir(root.path, 0o755) == 0 && mkdir(root.path + "/" + accented, 0o755) == 0 && mkdir(root.path + "/ФКП Росреестра", 0o755) == 0)
        #expect(FileManager.default.createFile(atPath: root.path + "/" + accented + "/" + receipt, contents: Data("recibo".utf8)))
        #expect(FileManager.default.createFile(atPath: root.path + "/ФКП Росреестра/выписка.txt", contents: Data("выписка".utf8)))
        let zip = scratch.url("Contas 2025.zip")
        try ZipFolderArchiver().zip(root, to: zip)

        let entries = try Self.entries(zip)
        let expected = ["Contas 2025/João/Recibo Eletrónico.txt", "Contas 2025/ФКП Росреестра/выписка.txt"]
        // Bytes, not strings: Swift holds a letter and its accent equal to the composed letter.
        #expect(entries.map(\.name) == expected.map { Array($0.precomposedStringWithCanonicalMapping.utf8) },
                "each file under the folder's name, composed: \(entries.map { String(decoding: $0.name, as: UTF8.self) })")
        #expect(entries.allSatisfy { $0.centralFlags & Self.utf8Flag != 0 && $0.localFlags & Self.utf8Flag != 0 },
                "and marked UTF-8 in its central record and local header, so unzip, Python and Windows do not read it as CP437")

        // Unpacked as Finder does, with the tool macOS ships for it.
        let unpacked = scratch.url("Unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0, "the archive is a ZIP archive macOS unpacks")
        let text = try String(contentsOf: unpacked.appendingPathComponent("Contas 2025/ФКП Росреестра/выписка.txt"), encoding: .utf8)
        #expect(text == "выписка", "with each file as it was")
    }

    @Test func anEmptyFolderIsKeptAndADestinationThatIsThereIsNeverWrittenOver() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let root = scratch.url("Export")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sem remetente"), withIntermediateDirectories: true)
        let zip = scratch.url("Export.zip")
        try ZipFolderArchiver().zip(root, to: zip)
        #expect(try Self.entries(zip).map(\.name) == [Array("Export/Sem remetente/".utf8)], "an empty folder is an entry of its own")
        let before = try Data(contentsOf: zip)
        #expect(throws: (any Error).self, "an archive already there is not written over") { try ZipFolderArchiver().zip(root, to: zip) }
        #expect(try Data(contentsOf: zip) == before, "and is as it was")
    }
    @Test func anExportTheArchiverFailsToPackLeavesNothingWhereTheArchiveWouldGo() throws {
        // The real archiver, given a folder that holds a file it cannot read, as a file whose permissions changed meanwhile.
        struct WithUnreadable: FolderArchiving {
            func zip(_ directory: URL, to destination: URL) throws {
                let unreadable = directory.appendingPathComponent("unreadable.txt").path
                #expect(FileManager.default.createFile(atPath: unreadable, contents: Data("x".utf8), attributes: [.posixPermissions: 0o000]))
                try ZipFolderArchiver().zip(directory, to: destination)
            }
        }
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let config = try PipelineConfig.bundledDefaults()
        let exporter = SearchTaskExporter(builder: FilenameBuilder(config: config.naming, reserved: SkipRules(watcher: config.watcher)),
                                          archiver: WithUnreadable(), tasks: config.tasks, excluded: [])
        let epoch = Date(timeIntervalSince1970: 0)
        let task = SearchTask(id: 1, name: "Contas 2025", prompt: "contas de 2025", title: nil, state: .queued, plan: nil, grouping: [],
                              groupedByUser: false, effort: .medium, profile: nil, model: nil, problem: nil, documents: [], added: [],
                              removed: [], exports: [], lastTrace: nil, createdAt: epoch, updatedAt: epoch)
        let out = scratch.url("Out")
        #expect("a file the archiver cannot read fails the export") {
            _ = try exporter.export(SearchTaskDetail(task: task, tree: LabelGroup(kind: nil, value: nil, groups: [], documents: [])),
                                    into: out, format: .zip)
        } throws: { error in
            guard case let SearchTaskError.exportFailed(path, _) = error else { return false }
            return path == out.appendingPathComponent("Contas 2025.zip").path
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty,
                "and leaves no part of an archive in the folder: it is packed elsewhere and moved there only once whole")
    }
}
