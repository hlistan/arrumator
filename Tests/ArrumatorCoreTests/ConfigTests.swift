import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

@Suite struct ConfigTests {
    @Test func bundledDefaultsDecode() throws {
        let config = try PipelineConfig.bundledDefaults()
        let settings = try AppSettings.bundledDefaults()
        let models = try config.models(for: settings.models)
        #expect(!models.chat.isEmpty && !models.embed.isEmpty, "the default settings name a profile the pipeline defines")
        #expect(config.extraction.ocrLanguages.allSatisfy { Locale.LanguageCode($0).isISOLanguage },
                "OCR hints are language codes Vision can be given")
        #expect(config.problems.isEmpty, "the bundled defaults pass their own validation: \(config.problems)")
    }

    @Test func everyKeyOfTheDefaultsIsNeededSoNoneIsMissing() throws {
        // Types declare no defaults (AGENTS.md §3), so leaving a key out of pipeline.json fails the load, naming it.
        guard case var .object(pipeline) = try ConfigLoader.bundledValue("pipeline"),
              case var .object(analysis) = pipeline["analysis"] else { throw ConfigError.missingResource("pipeline.json") }
        analysis["excerptChars"] = nil
        pipeline["analysis"] = .object(analysis)
        #expect("a key left out of pipeline.json fails the load, naming it") {
            try JSON.decoder.decode(PipelineConfig.self, from: JSON.encoder.encode(JSONValue.object(pipeline)))
        } throws: { error in
            String(describing: error).contains("excerptChars")
        }
        guard case var .object(settings) = try ConfigLoader.bundledValue("settings") else { throw ConfigError.missingResource("settings.json") }
        settings["duplicateAction"] = nil
        #expect(throws: DecodingError.self, "and so does a setting left out of settings.json") {
            try JSON.decoder.decode(AppSettings.self, from: JSON.encoder.encode(JSONValue.object(settings)))
        }
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

    @Test func everyFullTextColumnHasItsWeight() throws {
        let weights = try PipelineConfig.bundledDefaults().search.bm25Weights
        #expect(weights.count == SearchService.columns.count,
                "bm25() weighs columns by position; a column without a weight counts as 1 and a label would outrank the title")
    }

    @Test func theVocabularyMergesOnlyWhatItWouldAlsoOffer() throws {
        let vocabulary = try PipelineConfig.bundledDefaults().labels.vocabulary
        for (kind, policy) in vocabulary.kinds {
            #expect((0...1).contains(policy.suggestSimilarity) && (0...1).contains(policy.mergeSimilarity), "\(kind): a similarity")
            #expect(policy.mergeSimilarity >= policy.suggestSimilarity,
                    "\(kind): a label merged without asking is one the user would have been offered to merge")
        }
        #expect(throws: (any Error).self, "a kind that does not exist is refused, not ignored") {
            try JSONDecoder().decode([LabelKind: KindVocabularyConfig].self,
                                     from: Data(#"{"sendr": {"mergeSimilarity": 1, "suggestSimilarity": 1, "promptLimit": 0}}"#.utf8))
        }
    }

    @Test func aPipelineOverrideTheAppCannotRunWithIsRefused() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        for override in [#"{"ingest": {"retryDelays": []}}"#, #"{"analysis": {"repairAttempts": -1}}"#,
                         #"{"ingest": {"maxAttempts": 0}}"#, #"{"tasks": {"withoutLabelFolder": "No {{label}}"}}"#,
                         #"{"tasks": {"defaultGrouping": ["type", "sender", "date", "party"]}}"#, #"{"tasks": {"maxDocuments": 0}}"#,
                         #"{"tasks": {"efforts": {"low": {"repairAttempts": -1}}}}"#, #"{"tasks": {"efforts": {"high": {"numPredict": 0}}}}"#,
                         #"{"tasks": {"efforts": {"medium": {"timeout": 0}}}}"#, #"{"tasks": {"efforts": {"low": {"model": "vision"}}}}"#,
                         #"{"tasks": {"efforts": {"extreme": {"model": "chat"}}}}"#] {
            try Data(override.utf8).write(to: env.paths.pipelineOverrideURL)
            #expect(throws: ConfigError.self, "\(override) would crash or stall the pipeline, so it stops the app with the reason") {
                try PipelineConfig.load(paths: env.paths, environment: TestEnvironment.isolated)
            }
        }
    }

    @Test func everyEffortHasItsPresetAndMediumReadsAsTasksWereReadBefore() throws {
        var config = try PipelineConfig.bundledDefaults()
        let medium = try config.tasks.preset(.medium)
        #expect(medium.model == .chat && medium.fallback && medium.think == config.analysis.think
                    && medium.repairAttempts == config.analysis.repairAttempts && medium.numPredict == config.analysis.llmOptions.numPredict
                    && medium.timeout == config.ollama.timeouts.chat,
                "medium reads a request as every task was read before efforts: as documents are, by the chat model, then the fast one")
        let low = try config.tasks.preset(.low), high = try config.tasks.preset(.high)
        #expect(low.repairAttempts <= medium.repairAttempts && medium.repairAttempts <= high.repairAttempts
                    && low.numPredict <= medium.numPredict && medium.numPredict <= high.numPredict
                    && LabelKind.allCases.allSatisfy { (low.promptLabels[$0] ?? 0) <= (medium.promptLabels[$0] ?? 0)
                        && (medium.promptLabels[$0] ?? 0) <= (high.promptLabels[$0] ?? 0) },
                "each effort gives at least as much as the one below it")
        config.tasks.efforts[.high] = nil
        #expect(config.problems.contains("tasks.efforts.high is missing"), "an effort without its preset stops the app with the reason")
        #expect(throws: ConfigError.self, "and is never read with a guess") { try config.tasks.preset(.high) }
    }

    @Test func aListThatMayNotBeEmptyPicksItsValuesAndRefusesToBeEmpty() throws {
        let one = NonEmpty(2.0, [])
        #expect([-1, 0, 1, 5].map(one.clamped) == [2, 2, 2, 2], "a single delay serves every retry")
        let three = NonEmpty(2.0, [8, 30])
        #expect([0, 1, 2, 3, 99].map(three.clamped) == [2, 8, 30, 30, 30], "the n-th retry waits the n-th delay, then the last one")
        #expect(three.all == [2, 8, 30] && three.last == 30 && three.count == 3, "the list gives back every value, in order")
        #expect(try JSONDecoder().decode(NonEmpty<Double>.self, from: Data("[1, 2]".utf8)) == NonEmpty(1, [2]), "a list read from JSON keeps its values")
        #expect(throws: DecodingError.self, "an empty list is refused where it is read, not found empty when it is needed") {
            try JSONDecoder().decode(NonEmpty<Double>.self, from: Data("[]".utf8))
        }
    }

    @Test func deepMergeOverridesNestedKeysOnly() throws {
        let base: JSONValue = ["a": ["x": 1, "y": 2], "b": "keep"]
        let merged = ConfigLoader.deepMerge(base, ["a": ["y": 3]])
        #expect(merged["a"]?["x"] == 1, "a nested key the override leaves out keeps its value")
        #expect(merged["a"]?["y"] == 3, "a nested key the override names takes its value")
        #expect(merged["b"] == "keep", "a key beside the override is untouched")
        #expect(ConfigLoader.diff(merged, from: base) == ["a": ["y": 3]], "the difference is only what the override changed")
    }

    @Test func settingsStoreWritesOnlyChanges() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try await env.settings.update { $0.renameFiles = false }
        let saved = try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: env.paths.settingsURL))
        #expect(saved["renameFiles"] == .bool(false), "the changed setting is written")
        #expect(saved["transliterate"] == nil, "an unchanged setting is not, so a new default still reaches the user")
        let reloaded = try SettingsStore(paths: env.paths)
        #expect(await reloaded.current.renameFiles == false, "the change survives a restart")
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
        #expect(OllamaEndpoint.isThisMac(try OllamaEndpoint.validated("http://localhost:11434")), "localhost is this Mac")
        #expect(!OllamaEndpoint.isThisMac(try OllamaEndpoint.validated("http://192.168.1.239:11434")), "an address on the local network is another machine")
        let config = try PipelineConfig.bundledDefaults().ollama
        #expect(throws: OllamaError.self, "the client itself refuses a host beyond the local network") {
            try OllamaClient(config: config, baseURL: try #require(URL(string: "http://example.com:11434")), time: TestTime(.advances))
        }
    }

    @Test func networkGuardBlocksNonLocalRequests() async throws {
        let config = try PipelineConfig.bundledDefaults().ollama
        _ = try OllamaClient(config: config, baseURL: try OllamaEndpoint.validated("http://192.168.1.239:11434"), time: TestTime(.advances))
        NetworkGuardProtocol.resetViolations()
        let session = URLSession(configuration: NetworkGuardProtocol.guardedConfiguration())
        await #expect(throws: (any Error).self, "a request beyond the local network fails") {
            _ = try await session.data(from: URL(string: "https://example.com/")!)
        }
        #expect(NetworkGuardProtocol.violations.contains { $0.contains("example.com") }, "and is recorded, so Doctor can report it")
    }
}

@Suite struct JSONTests {
    @Test func orderedObjectsKeepOrderAndEscape() {
        let v: JSONValue = .orderedObject([JSONEntry("z", 1), JSONEntry("a", "q\"\n\u{1}"), JSONEntry("m", [true, .null, 1.5])])
        #expect(v.serialized() == #"{"z":1,"a":"q\"\n\u0001","m":[true,null,1.5]}"#, "keys keep their order and control characters are escaped")
        let sorted: JSONValue = ["b": 1, "a": 2]
        #expect(sorted.serialized() == #"{"a":2,"b":1}"#, "an unordered object is written with sorted keys, so the output is stable")
    }

    @Test func chatBodyPutsSchemaPropertiesInOrder() throws {
        let schema: JSONValue = .orderedObject([JSONEntry("type", "object"), JSONEntry("properties",
            .orderedObject([JSONEntry("correspondent", ["type": "string"]), JSONEntry("file_name", ["type": "string"])]))])
        let body = OllamaChatRequest(model: "m", messages: [.user("hi")], format: schema, options: [:], keepAlive: "1m", think: false, timeout: nil)
            .body.serialized()
        let r = try #require(body.range(of: "correspondent"))
        let f = try #require(body.range(of: "file_name"))
        #expect(r.lowerBound < f.lowerBound, "the model is asked for the properties in the order the schema gives them")
        #expect(body.contains(#""think":false"#), "thinking is turned off as asked")
    }
}
