import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

@Suite struct ConfigTests {
    @Test func bundledDefaultsDecode() throws {
        let config = try PipelineConfig.bundledDefaults()
        #expect(config.modelProfiles.keys.contains("standard"))
        #expect(config.extraction.languages == ["en", "ru", "pt"])
        let settings = try AppSettings.bundledDefaults()
        let models = try config.models(for: settings.models)
        #expect(!models.chat.isEmpty && !models.embed.isEmpty)
    }

    @Test func deepMergeOverridesNestedKeysOnly() throws {
        let base: JSONValue = ["a": ["x": 1, "y": 2], "b": "keep"]
        let merged = ConfigLoader.deepMerge(base, ["a": ["y": 3]])
        #expect(merged["a"]?["x"] == 1)
        #expect(merged["a"]?["y"] == 3)
        #expect(merged["b"] == "keep")
        #expect(ConfigLoader.diff(merged, from: base) == ["a": ["y": 3]])
    }

    @Test func settingsStoreWritesOnlyChanges() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try await env.settings.update { $0.renameFiles = false }
        let saved = try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: env.paths.settingsURL))
        #expect(saved["renameFiles"] == .bool(false))
        #expect(saved["transliterate"] == nil)
        let reloaded = try SettingsStore(paths: env.paths)
        #expect(await reloaded.current.renameFiles == false)
    }

    @Test func environmentOverridesOllamaEndpoint() throws {
        var env = RuntimeEnvironment.current
        env.ollamaURL = "http://localhost:12345"
        env.pipelineOverridePath = nil
        let paths = AppPaths(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                             logsDirectory: FileManager.default.temporaryDirectory)
        let config = try PipelineConfig.load(paths: paths, environment: env)
        #expect(config.ollama.baseURL == "http://localhost:12345")
    }

    @Test func nonLocalOllamaIsRejected() throws {
        var config = try PipelineConfig.bundledDefaults().ollama
        config.baseURL = "http://example.com:11434"
        #expect(throws: OllamaError.self) { try OllamaClient(config: config) }
    }

    @Test func networkGuardBlocksNonLocalRequests() async throws {
        let config = try PipelineConfig.bundledDefaults().ollama
        _ = try OllamaClient(config: config)
        NetworkGuardProtocol.resetViolations()
        let session = URLSession(configuration: NetworkGuardProtocol.guardedConfiguration())
        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: URL(string: "https://example.com/")!)
        }
        #expect(NetworkGuardProtocol.violations.contains { $0.contains("example.com") })
    }
}

@Suite struct JSONTests {
    @Test func orderedObjectsKeepOrderAndEscape() {
        let v: JSONValue = .orderedObject([JSONEntry("z", 1), JSONEntry("a", "q\"\n\u{1}"), JSONEntry("m", [true, .null, 1.5])])
        #expect(v.serialized() == #"{"z":1,"a":"q\"\n\u0001","m":[true,null,1.5]}"#)
        let sorted: JSONValue = ["b": 1, "a": 2]
        #expect(sorted.serialized() == #"{"a":2,"b":1}"#)
    }

    @Test func chatBodyPutsSchemaPropertiesInOrder() throws {
        let schema: JSONValue = .orderedObject([JSONEntry("type", "object"), JSONEntry("properties",
            .orderedObject([JSONEntry("rationale", ["type": "string"]), JSONEntry("folder_code", ["type": "string"])]))])
        let body = OllamaChatRequest(model: "m", messages: [.user("hi")], format: schema, options: [:], keepAlive: "1m", think: false)
            .body.serialized()
        let r = try #require(body.range(of: "rationale"))
        let f = try #require(body.range(of: "folder_code"))
        #expect(r.lowerBound < f.lowerBound)
        #expect(body.contains(#""think":false"#))
    }
}

@Suite struct JDCodeTests {
    @Test func codes() {
        #expect(JDCode.isArea("20-29"))
        #expect(JDCode.isCategory("23"))
        #expect(JDCode.area(of: "23") == "20-29")
        #expect(JDCode.nextFreeCategory(in: "30-39", used: ["31", "32"]) == "33")
        #expect(JDCode.nextFreeArea(used: ["10-19", "30-39"], first: 10, last: 90) == "20-29")
        #expect(JDCode.nextFreeArea(used: Set(stride(from: 10, through: 90, by: 10).map { String(format: "%02d-%02d", $0, $0 + 9) }),
                                    first: 10, last: 90) == nil)
        #expect(JDCode.parse(directoryName: "23 Taxes (Portugal)")?.code == "23")
        #expect(JDCode.parse(directoryName: "Misc") == nil)
        #expect(JDCode.isYearFolder("2025") && !JDCode.isYearFolder("25"))
    }
}
