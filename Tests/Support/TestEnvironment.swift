import ArrumatorCore
import Foundation

/// Temporary app home, empty archive and Incoming folder, removed on `cleanup()`.
public struct TestEnvironment: Sendable {
    public let root: URL
    public let paths: AppPaths
    public let archive: URL
    public let incoming: URL
    public let database: AppDatabase
    public let config: PipelineConfig
    public let settings: SettingsStore
    /// What everything built on this environment stamps and waits by; sleeping on it passes at once.
    public let time: TestTime

    public static func make() async throws -> TestEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-test-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(supportDirectory: root.appendingPathComponent("support"), logsDirectory: root.appendingPathComponent("logs"))
        try paths.ensureDirectories()
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        let incoming = root.appendingPathComponent("Incoming", isDirectory: true)
        let config = try PipelineConfig.bundledDefaults()
        let settings = try SettingsStore(paths: paths)
        try await settings.update {
            $0.archivePath = archive.path
            $0.incomingPath = incoming.path
        }
        let database = try AppDatabase.inMemory()
        return TestEnvironment(root: root, paths: paths, archive: archive, incoming: incoming, database: database, config: config,
                               settings: settings, time: TestTime(.advances))
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// What stands in for the Trash in everything built on this environment, so nothing a test does reaches the user's.
    public var trash: FolderTrash { FolderTrash(folder: root.appendingPathComponent("Trash", isDirectory: true)) }

    /// Every file put in the Trash, at any depth.
    public func trashed() -> [URL] {
        let found = FileManager.default.enumerator(at: trash.folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects ?? []
        return found.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// Writes a text file into Incoming and returns its URL. `name` may be a path below Incoming, such as
    /// `Taxes 2024/sub/scan.txt`, as when the user puts a folder there: the folders are made as needed.
    @discardableResult
    public func drop(_ name: String, text: String) throws -> URL {
        let url = incoming.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// An environment that reads none of the process's variables: tests never depend on how they were started.
    public static let isolated = RuntimeEnvironment(home: nil, ollamaURL: nil, logLevelName: nil, pipelineOverridePath: nil, trashPath: nil)

    /// Where things are in the archive.
    public var layout: ArchiveLayout { ArchiveLayout(root: archive, records: config.records, watcher: config.watcher) }

    /// The archive's record files, kept with `index`: the environment's own database unless another is given, such as an
    /// index made anew over the same archive. The archive is one the test made, not the app.
    public func records(index: AppDatabase? = nil) -> ArchiveRecords {
        ArchiveRecords(database: index ?? database, archive: archive, settings: settings, config: config, registry: nil,
                       time: time)
    }

    /// Writes a text file into the archive at `path`, below its top, as the user would put one there.
    @discardableResult
    public func put(_ path: String, text: String) throws -> URL {
        let url = archive.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.standardizedFileURL
    }
}

/// Extractor for tests: reads files as UTF-8 text and fills the minimum of `ExtractedContent`.
public struct PlainTestExtractor: ContentExtracting {
    public init() {}
    public func extract(_ url: URL, sha256: String, context: ExtractionContext, trace: TraceContext) async throws -> ExtractedContent {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let source = SourceFile(path: url.path, originalFilename: url.lastPathComponent, fileExtension: url.pathExtension,
                                utType: "public.plain-text", byteSize: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                                createdAt: nil, modifiedAt: attrs[.modificationDate] as? Date, sha256: sha256)
        return ExtractedContent(source: source, kind: .textDocument, textOrigin: .textLayer, text: text,
                                language: LanguageGuess(primary: "en", confidence: 1), extractorName: "plain-test")
    }
}
