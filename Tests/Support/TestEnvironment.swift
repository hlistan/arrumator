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
    public let taxonomy: TaxonomyStore

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
        let taxonomy = TaxonomyStore(database: database, config: config.taxonomy, registry: nil)
        return TestEnvironment(root: root, paths: paths, archive: archive, incoming: incoming, database: database, config: config,
                               settings: settings, taxonomy: taxonomy)
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a text file into Incoming and returns its URL.
    @discardableResult
    public func drop(_ name: String, text: String) throws -> URL {
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let url = incoming.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Creates a folder inside a top-level one named `area`, the way the app does on demand.
    @discardableResult
    public func folder(_ name: String, area: String, yearly: Bool = false, description: String? = nil) async throws -> TaxonomyFolder {
        try await folder(path: [area, name], yearly: yearly, description: description)
    }

    /// Creates the folders along `path`, outermost first, reusing those that exist, and returns the last.
    @discardableResult
    /// `kinds` says, level by level, what the folders stand for in the logic with `LogicStore.version` `logic`.
    public func folder(path: [String], yearly: Bool = false, description: String? = nil, kinds: [LevelKind] = [],
                       logic: String? = nil) async throws -> TaxonomyFolder {
        let levels = path.enumerated().map { index, name in
            FolderLevel(name: name, description: index == path.count - 1 ? (description ?? "\(name) documents.") : "\(name) documents.",
                        kind: kinds.indices.contains(index) ? kinds[index] : nil)
        }
        return try await taxonomy.materialize(FolderSpec(parentCode: nil, levels: levels, yearSubfolders: yearly,
                                                         yearRule: yearly ? .documentDate : nil, logic: logic),
                                              root: archive, origin: .learned)
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
