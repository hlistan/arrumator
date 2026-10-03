@testable import ArrumatorCore
import Foundation
import Testing

/// What the tests of `arrumatorcli` share: a scratch home, the built command run in it, and the archive's documents and
/// History as the command finds and leaves them.
extension CommandLineTests {
    /// Finds the built command beside this test bundle, as SwiftPM builds both into one products folder.
    final class Marker: NSObject {}

    struct Home {
        let root: URL
        var support: URL { root.appendingPathComponent("support", isDirectory: true) }
        var archive: URL { root.appendingPathComponent("Archive", isDirectory: true) }

        /// Port 9 is the discard service: nothing answers there, so every model check sees Ollama as not running.
        static let nowhere = "http://127.0.0.1:9"

        /// A home whose settings save `ollamaURL` as the Ollama server.
        static func make(ollamaURL: String = nowhere) throws -> Home {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-cli-\(UUID().uuidString)", isDirectory: true)
            let home = Home(root: root)
            try FileManager.default.createDirectory(at: home.support, withIntermediateDirectories: true)
            let settings: [String: String] = ["incomingPath": root.appendingPathComponent("Incoming").path,
                                              "archivePath": home.archive.path,
                                              "ollamaURL": ollamaURL, "ollamaManagement": "external"]
            try JSONEncoder().encode(settings).write(to: home.support.appendingPathComponent("settings.json"))
            // The archive the user has: no command makes its folder but `archive switch`.
            try FileManager.default.createDirectory(at: home.archive, withIntermediateDirectories: true)
            return home
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    func run(_ home: Home, _ arguments: [String]) throws -> Result {
        let command = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("arrumatorcli")
        guard FileManager.default.isExecutableFile(atPath: command.path) else { throw CocoaError(.fileNoSuchFile) }
        // Only what the command needs: its scratch home and Trash, and a home folder for the disk-space check.
        let outcome = try ChildProcess.run(command, arguments, environment: [
            "ARRUMATOR_HOME": home.support.path, "ARRUMATOR_TRASH": home.root.appendingPathComponent("Trash").path,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ])
        return Result(status: outcome.status, stdout: outcome.stdout, stderr: String(decoding: outcome.stderr, as: UTF8.self))
    }

    func settings(_ home: Home) throws -> AppSettings {
        try JSON.decoder.decode(AppSettings.self, from: try run(home, ["settings", "--json"]).stdout)
    }

    /// The settings changes in the scratch archive's History.
    func settingsEvents(_ home: Home) throws -> [EventRecord] {
        try JSON.decoder.decode([EventRecord].self, from: try run(home, ["history", "--json"]).stdout).filter { $0.kind == .settingsChanged }
    }

    /// Puts documents into the scratch archive as an earlier run filed them, one a minute after the other, each labelled
    /// as given: the files, each with the identifier Arrumator keeps on it, and the archive's record of them, which the
    /// command's new index is rebuilt from. Returns their numbers, in the order given.
    func file(_ home: Home, _ documents: [(name: String, labels: [DocumentLabel])]) throws -> [Int64] {
        try FileManager.default.createDirectory(at: home.archive, withIntermediateDirectories: true)
        var entries: [DocumentEntry] = []
        for (offset, document) in documents.enumerated() {
            let url = home.archive.appendingPathComponent(document.name)
            let text = Data("A document: \(document.name)".utf8)
            try text.write(to: url)
            var record = DocumentRecord.arrived(path: url.path, sha256: try HashService.sha256(of: url), size: Int64(text.count),
                                                uttype: "public.plain-text", inode: nil, modified: nil, now: Date())
            record.id = Int64(offset + 1)
            record.status = .filed
            record.filedAt = record.addedAt.addingTimeInterval(Double(offset) * 60)
            record.labelsJson = JSON.string(document.labels)
            try Xattr.set(Xattr.documentID, record.uid, on: url)
            entries.append(try #require(DocumentEntry(record)))
        }
        let records = home.archive.appendingPathComponent(try PipelineConfig.bundledDefaults().records.documentsFileName)
        try FrontMatter.compose(RecordList(entries), body: "").write(to: records, atomically: true, encoding: .utf8)
        return entries.map(\.id)
    }

    /// Writes `text` as the list of documents in `folder`, which it makes if need be; the list.
    func writeList(_ text: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let listing = folder.appendingPathComponent(try PipelineConfig.bundledDefaults().records.documentsFileName)
        try text.write(to: listing, atomically: true, encoding: .utf8)
        return listing
    }
}
