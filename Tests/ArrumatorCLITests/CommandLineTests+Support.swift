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
        /// The settings every command in this home reads besides the bundled ones, when the home was made with some.
        var pipeline: URL { root.appendingPathComponent("pipeline.json") }
        /// What the command runs in: this home, its own Trash, the test's time zone, so a time it prints is the one the
        /// test formats, and the home's settings, if it has any.
        var environment: [String: String] {
            ["ARRUMATOR_HOME": support.path, "ARRUMATOR_TRASH": root.appendingPathComponent("Trash").path,
             "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TZ": TimeZone.current.identifier]
                .merging(FileManager.default.fileExists(atPath: pipeline.path) ? ["ARRUMATOR_PIPELINE_CONFIG": pipeline.path] : [:]) { $1 }
        }

        /// Port 9 is the discard service: nothing answers there, so every model check sees Ollama as not running.
        static let nowhere = "http://127.0.0.1:9"

        /// A home whose settings save `ollamaURL` as the Ollama server, and whose commands read `pipeline` besides the
        /// bundled settings, when given.
        static func make(ollamaURL: String = nowhere, pipeline: [String: Any]? = nil) throws -> Home {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-cli-\(UUID().uuidString)", isDirectory: true)
            let home = Home(root: root)
            try FileManager.default.createDirectory(at: home.support, withIntermediateDirectories: true)
            let settings: [String: String] = ["incomingPath": root.appendingPathComponent("Incoming").path,
                                              "archivePath": home.archive.path,
                                              "ollamaURL": ollamaURL, "ollamaManagement": "external"]
            try JSONEncoder().encode(settings).write(to: home.support.appendingPathComponent("settings.json"))
            // The archive the user has: no command makes its folder but `archive switch`.
            try FileManager.default.createDirectory(at: home.archive, withIntermediateDirectories: true)
            if let pipeline { try JSONSerialization.data(withJSONObject: pipeline).write(to: home.pipeline) }
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

    func run(_ home: Home, _ arguments: [String], environment: [String: String] = [:]) throws -> Result {
        let command = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("arrumatorcli")
        guard FileManager.default.isExecutableFile(atPath: command.path) else { throw CocoaError(.fileNoSuchFile) }
        // Only what the command needs: its scratch home and Trash, and a home folder for the disk-space check, and what
        // the test gives besides.
        let outcome = try ChildProcess.run(command, arguments, environment: home.environment.merging(environment) { _, given in given })
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
    /// as given, and read as `analyses` gives by its name: the files, each with the identifier Arrumator keeps on it, and
    /// the archive's record of them, which the command's new index is rebuilt from. Returns their numbers, in the order
    /// given.
    func file(_ home: Home, _ documents: [(name: String, labels: [DocumentLabel])], analyses: [String: DocumentAnalysis] = [:]) throws -> [Int64] {
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
            record.labelsJson = try JSON.string(document.labels)
            record.analysisJson = try analyses[document.name].map { try JSON.string($0) }
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
