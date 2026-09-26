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

    @Test func imagesAreDescribedWithTheContextTheirModelIsLoadedWithElsewhere() throws {
        var models = try PipelineConfig.bundledDefaults().models(for: AppSettings.bundledDefaults().models)
        models.numCtx = 12288
        models.fastNumCtx = 8192
        models.chat = "one-model"
        models.vision = "one-model"
        models.fast = "one-model"
        #expect(models.visionNumCtx == 12288,
                "one model for decisions and images keeps one context, so describing an image does not reload it")
        models.chat = "a-decision-model"
        #expect(models.visionNumCtx == 8192, "an image model that also names files keeps the naming context")
        models.fast = "another-naming-model"
        #expect(models.visionNumCtx == 12288, "an image model of its own is asked with the decision context")
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

    @Test func ollamaAnswersOnThisMacOrTheLocalNetworkOnly() throws {
        for address in ["http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434", "http://192.168.1.239:11434",
                        "http://10.0.0.5:11434", "http://172.20.1.1:11434", "http://169.254.3.4:11434", "https://gpu-box.local:11434",
                        "http://[fd12:3456::1]:11434", "http://[fe80::1]:11434", " http://192.168.1.239:11434 "] {
            #expect(throws: Never.self, "\(address)") { _ = try OllamaEndpoint.validated(address) }
        }
        for address in ["http://8.8.8.8:11434", "http://172.32.0.1:11434", "http://ollama.example.com:11434", "http://[2001:db8::1]:11434",
                        "ftp://192.168.1.2", "not a url", "http://", "192.168.1.239:11434"] {
            #expect(throws: OllamaError.self, "\(address)") { _ = try OllamaEndpoint.validated(address) }
        }
        #expect(OllamaEndpoint.isThisMac(try OllamaEndpoint.validated("http://localhost:11434")))
        #expect(!OllamaEndpoint.isThisMac(try OllamaEndpoint.validated("http://192.168.1.239:11434")))
        let config = try PipelineConfig.bundledDefaults().ollama
        #expect(throws: OllamaError.self, "the client itself refuses a host beyond the local network") {
            try OllamaClient(config: config, baseURL: try #require(URL(string: "http://example.com:11434")))
        }
    }

    @Test func networkGuardBlocksNonLocalRequests() async throws {
        let config = try PipelineConfig.bundledDefaults().ollama
        _ = try OllamaClient(config: config, baseURL: try OllamaEndpoint.validated("http://192.168.1.239:11434"))
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
            .orderedObject([JSONEntry("rationale", ["type": "string"]), JSONEntry("ideal_path", ["type": "array"])]))])
        let body = OllamaChatRequest(model: "m", messages: [.user("hi")], format: schema, options: [:], keepAlive: "1m", think: false)
            .body.serialized()
        let r = try #require(body.range(of: "rationale"))
        let f = try #require(body.range(of: "ideal_path"))
        #expect(r.lowerBound < f.lowerBound)
        #expect(body.contains(#""think":false"#))
    }
}

@Suite struct FolderCodeTests {
    @Test func codesCountUpPastEveryCodeEverUsed() {
        #expect(FolderCode.next(after: []) == "F1")
        #expect(FolderCode.next(after: ["F1", "F7", "11", "10-19", "needs-review"]) == "F8", "codes of earlier versions are no part of the count")
    }

    @Test func yearFolders() {
        #expect(YearFolder.matches("2025") && !YearFolder.matches("25") && !YearFolder.matches("2025 Taxes"))
    }

    @Test func aFolderReadsItsNameFromItsDirectory() {
        let definition = FolderDefinition(code: "11", name: "Utilities", description: "", yearSubfolders: false, yearRule: nil,
                                          autoFile: true, origin: .learned)
        #expect(definition.name(fromDirectory: "11 Utilities") == "Utilities", "a directory an earlier version numbered")
        #expect(definition.name(fromDirectory: "Energy and Water") == "Energy and Water", "renamed in Finder")
    }
}
