import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

@Suite struct ConfigTests {
    @Test func bundledDefaultsDecode() throws {
        let config = try PipelineConfig.bundledDefaults()
        let settings = try AppSettings.bundledDefaults()
        #expect(config.extraction.ocrLanguages.allSatisfy { Locale.LanguageCode($0).isISOLanguage },
                "OCR hints are language codes Vision can be given")
        #expect(config.problems.isEmpty, "the bundled defaults pass their own validation: \(config.problems)")
        #expect(settings.problems.isEmpty, "and so do the bundled settings: \(settings.problems)")
    }

    @Test func theBundledSettingsUseAProfileTheyListAndListFastStandardAndSmartInThatOrder() throws {
        let settings = try AppSettings.bundledDefaults()
        let inUse = try settings.modelProfile()
        #expect(inUse == settings.modelProfiles[settings.profile] && inUse.name == "Standard",
                "the profile in use is one the settings list, Standard, so documents are read as before profiles were settings")
        #expect(settings.modelProfiles.values.sorted { $0.position < $1.position }.map(\.name) == ["Fast", "Standard", "Smart"],
                "the profiles are listed by position, as JSON objects keep no order")
        #expect(settings.modelProfiles.values.allSatisfy { $0.visionModel == $0.chatModel },
                "each bundled profile reads documents and describes images with one model, which stays loaded once for both")
        #expect(throws: ModelProfileError.unknown("lowMemory"), "a profile the settings do not list is refused, naming it") {
            try settings.modelProfile("lowMemory")
        }
        let replay = try settings.reading(withChatModel: "gpt-oss:20b")
        #expect(try replay.modelProfile() == ModelProfile(name: inUse.name, position: inUse.position, chatModel: "gpt-oss:20b",
                                                          visionModel: inUse.visionModel, embedModel: inUse.embedModel)
                    && replay.profile == settings.profile,
                "replay and eval read with another chat model in the profile in use, and change nothing else of it")
        #expect(throws: ConfigError.self, "and never with a blank one, which no model answers to") {
            try settings.reading(withChatModel: " ")
        }
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
        settings["renameFiles"] = nil
        #expect(throws: DecodingError.self, "and so does a setting left out of settings.json") {
            try JSON.decoder.decode(AppSettings.self, from: JSON.encoder.encode(JSONValue.object(settings)))
        }
    }

    @Test func imagesAreDescribedByTheProfilesVisionModelWithTheContextDocumentsAreReadWith() throws {
        let config = try PipelineConfig.bundledDefaults()
        var settings = try AppSettings.bundledDefaults()
        settings.modelProfiles[settings.profile]?.visionModel = "an-image-model"
        let vision = try #require(try config.extractionContext(settings: settings).vision, "images are described while enableVLM is on")
        #expect(vision.model == "an-image-model", "by the vision model of the profile in use")
        #expect(vision.numCtx == config.analysis.numCtx && vision.keepAlive == config.ollama.keepAlive.chat,
                "with the context and keep-alive documents are read with, so a model that does both is loaded once, not again for each image")
        settings.enableVLM = false
        #expect(try config.extractionContext(settings: settings).vision == nil, "and none is described when the user turned it off")
    }

    @Test func everyFullTextColumnHasItsWeight() throws {
        let weights = try PipelineConfig.bundledDefaults().search.bm25Weights
        #expect(weights.count == SearchService.columns.count,
                "bm25() weighs columns by position; a column without a weight counts as 1 and a label would outrank the title")
    }

    @Test func tagsAreNeitherKeptOneVocabularyNorShownToTheModelHoweverTheConfigurationIsWritten() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let bundled = try PipelineConfig.bundledDefaults()
        #expect(bundled.labels.vocabulary.kinds[.tag] == nil && bundled.tasks.efforts.values.allSatisfy { $0.promptLabels[.tag] == nil },
                "the bundled configuration keeps no tag one vocabulary and shows none to the model")
        for (override, why) in [(#"{"labels": {"vocabulary": {"kinds": {"tag": {"mergeSimilarity": 1, "suggestSimilarity": 1, "promptLimit": 0}}}}}"#,
                                 "labels.vocabulary.kinds.tag"),
                                (#"{"tasks": {"efforts": {"low": {"promptLabels": {"tag": 5}}}}}"#, "tasks.efforts.low.promptLabels.tag")] {
            try Data(override.utf8).write(to: env.paths.pipelineOverrideURL)
            #expect("\(why) would merge the user's own words or show them to the model, so it stops the app naming the key") {
                try PipelineConfig.load(paths: env.paths, environment: TestEnvironment.isolated)
            } throws: { error in
                (error as? ConfigError)?.localizedDescription.contains(why) == true
            }
        }
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
                         #"{"tasks": {"efforts": {"medium": {"timeout": 0}}}}"#, #"{"tasks": {"efforts": {"extreme": {"think": false}}}}"#,
                         #"{"conversation": {"efforts": {"low": {"repairAttempts": -1}}}}"#, #"{"conversation": {"efforts": {"high": {"timeout": 0}}}}"#,
                         #"{"conversation": {"efforts": {"medium": {"numPredict": 16384}}}}"#, #"{"conversation": {"contextChars": 0}}"#,
                         #"{"conversation": {"documentChars": 0}}"#, #"{"conversation": {"maxListed": -1}}"#,
                         #"{"conversation": {"historyChars": -1}}"#, #"{"conversation": {"maxQuestionChars": 0}}"#,
                         #"{"conversation": {"maxSuggested": 0}}"#, #"{"conversation": {"efforts": {"extreme": {"think": false}}}}"#,
                         #"{"extraction": {"emailReadCapBytes": 0}}"#, #"{"extraction": {"emailBodyCapBytes": -1}}"#,
                         #"{"extraction": {"image": {"maxPixels": 0}}}"#, #"{"extraction": {"pdf": {"ocrHeadPages": -1}}}"#,
                         #"{"extraction": {"zipMaxEntries": 0}}"#,
                         #"{"extraction": {"zipEntryCapBytes": -1}}"#, #"{"extraction": {"archiveMaxEntries": -1}}"#,
                         #"{"extraction": {"xlsx": {"maxRows": -1}}}"#] {
            try Data(override.utf8).write(to: env.paths.pipelineOverrideURL)
            #expect(throws: ConfigError.self, "\(override) would crash or stall the pipeline, so it stops the app with the reason") {
                try PipelineConfig.load(paths: env.paths, environment: TestEnvironment.isolated)
            }
        }
        try Data(#"{"tasks": {"efforts": {"high": {"think": ""}}}}"#.utf8).write(to: env.paths.pipelineOverrideURL)
        #expect("a level without a name would tell a model nothing, so it stops the app saying so") {
            try PipelineConfig.load(paths: env.paths, environment: TestEnvironment.isolated)
        } throws: { error in
            (error as? ConfigError)?.localizedDescription.contains("think names no level") == true
        }
    }

    @Test func everyEffortHasItsPresetLowDoesNotThinkAndEachThinksAtLeastAsMuchAsTheOneBelowIt() throws {
        var config = try PipelineConfig.bundledDefaults()
        let low = try config.tasks.preset(.low), medium = try config.tasks.preset(.medium), high = try config.tasks.preset(.high)
        #expect(low.think == .off && low.repairAttempts == config.analysis.repairAttempts
                    && low.numPredict == config.analysis.llmOptions.numPredict && low.timeout == config.ollama.timeouts.chat,
                "low reads at once, as every request was read before efforts thought: with the repairs, answer length and time documents get")
        #expect(medium.think != .off && high.think != .off, "medium and high let a model that can think do so before it answers")
        let levels = try #require(OllamaShowResponse.Thinking.levels.values, "the levels a model like gpt-oss thinks at, least first")
        let mediumLevel = try #require(levels.firstIndex(of: medium.think), "medium names a level, so a model with levels is told it")
        let highLevel = try #require(levels.firstIndex(of: high.think), "and so does high")
        #expect(mediumLevel <= highLevel, "a model with levels thinks at least as much at high as at medium")
        #expect(low.repairAttempts <= medium.repairAttempts && medium.repairAttempts <= high.repairAttempts
                    && low.numPredict <= medium.numPredict && medium.numPredict <= high.numPredict
                    && low.timeout <= medium.timeout && medium.timeout <= high.timeout
                    && LabelKind.allCases.allSatisfy { (low.promptLabels[$0] ?? 0) <= (medium.promptLabels[$0] ?? 0)
                        && (medium.promptLabels[$0] ?? 0) <= (high.promptLabels[$0] ?? 0) },
                "each effort gives at least as much as the one below it: repairs, answer length, time and the archive's vocabulary")
        #expect([medium, high].allSatisfy { $0.numPredict > low.numPredict && $0.timeout > low.timeout },
                "an effort that thinks gives the answer more room and time than one that does not: thinking counts toward both")
        config.tasks.efforts[.high] = nil
        #expect(config.problems.contains("tasks.efforts.high is missing"), "an effort without its preset stops the app with the reason")
        #expect(throws: ConfigError.self, "and is never read with a guess") { try config.tasks.preset(.high) }
    }

    @Test func everyEffortAnswersQuestionsWithItsPresetEachAtLeastAsMuchAsTheOneBelowItAndAllWithinTheContext() throws {
        var config = try PipelineConfig.bundledDefaults()
        let conversation = config.conversation
        let low = try conversation.effort(.low), medium = try conversation.effort(.medium), high = try conversation.effort(.high)
        #expect(low.think == .off && medium.think != .off && high.think != .off,
                "a question is answered at once at low, and a model that can think does so at medium and high")
        #expect(low.numPredict <= medium.numPredict && medium.numPredict <= high.numPredict && low.timeout <= medium.timeout
                    && medium.timeout <= high.timeout && low.repairAttempts <= medium.repairAttempts && medium.repairAttempts <= high.repairAttempts,
                "each effort gives at least as much as the one below it")
        #expect([low, medium, high].allSatisfy { $0.numPredict < conversation.numCtx }, "every answer leaves room for what it is shown")
        #expect(conversation.contextChars + conversation.historyChars + conversation.maxQuestionChars > conversation.documentChars,
                "the context holds more than one document's text")
        let options = conversation.options(medium)
        #expect(options.numPredict == medium.numPredict && options.temperature == conversation.sampling.temperature && options.temperature > 0,
                "an answer is sampled as writing is, not decoded greedily as a document is read, with its effort's length")
        config.conversation.efforts[.low] = nil
        #expect(config.problems.contains("conversation.efforts.low is missing"), "an effort without its preset stops the app with the reason")
        #expect(throws: ConfigError.self, "and is never answered with a guess") { try config.conversation.effort(.low) }
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

    @Test func aSettingChangedThroughTheActionsIsRecordedOnceWithWhatChangedAndNothingWhenNothingChanged() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let history = HistoryStore(database: env.database, time: env.time)
        let actions = SettingsActions(store: env.settings, history: history)
        func events() async throws -> [EventRecord] {
            try await history.events(limit: 50, kinds: [.settingsChanged]).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        }
        let changed = try await actions.change(summary: "Files keep their names, and more is logged") {
            $0.renameFiles = false
            $0.logLevel = .debug
        }
        #expect(!changed.renameFiles && changed.logLevel == .debug, "the settings in force are returned")
        #expect(try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: env.paths.settingsURL))["renameFiles"] == .bool(false),
                "and saved")
        let recorded = try await events()
        #expect(recorded.map(\.summary) == ["Files keep their names, and more is logged"] && recorded.first?.actor == .user,
                "the change is one event in History, the user's, in the words given")
        #expect(JSON.decode([String: JSONValue].self, from: recorded.first?.payloadJson) == ["logLevel": "debug", "renameFiles": false],
                "its payload is the settings that changed, with their new values, and nothing else")

        let file = try Data(contentsOf: env.paths.settingsURL)
        let same = try await actions.change(summary: "Nothing new") { $0.renameFiles = false }
        #expect(same == changed, "a change that changes nothing leaves the settings as they are")
        #expect(try await events().count == 1, "and records nothing")
        #expect(try Data(contentsOf: env.paths.settingsURL) == file, "and settings.json is as it was")

        try await actions.change(summary: "Ollama from Homebrew") { $0.ollamaBinaryPath = "/opt/homebrew/bin/ollama" }
        try await actions.change(summary: "Ollama found again") { $0.ollamaBinaryPath = nil }
        #expect(JSON.decode([String: JSONValue].self, from: try await events().last?.payloadJson) == ["ollamaBinaryPath": .null],
                "a setting taken away is recorded as null, so the payload says it changed")
        await #expect(throws: ConfigError.self, "settings the next launch would refuse are refused") {
            try await actions.change(summary: "A profile there is none of") { $0.profile = "lowMemory" }
        }
        #expect(try await events().count == 3, "and recorded nowhere")
    }

    @Test func aChangeGivenWithoutWordsIsRecordedInWordsMadeOfWhatChanged() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let history = HistoryStore(database: env.database, time: env.time)
        let actions = SettingsActions(store: env.settings, history: history)
        func summaries() async throws -> [String] {
            try await history.events(limit: 50, kinds: [.settingsChanged]).sorted { ($0.id ?? 0) < ($1.id ?? 0) }.map(\.summary)
        }
        let changed = try await actions.change {
            $0.renameFiles = false
            $0.logLevel = .debug
            $0.ollamaBinaryPath = "/opt/homebrew/bin/ollama"
        }
        #expect(!changed.renameFiles && changed.logLevel == .debug, "the settings in force are returned")
        #expect(try await summaries() == ["Changed logLevel to debug, ollamaBinaryPath to /opt/homebrew/bin/ollama, renameFiles to false"],
                "History names each setting that changed and what it became, in the order of their names, the app's changes as the command's")
        try await actions.change { $0.ollamaBinaryPath = nil }
        try await actions.change { $0.traceRawRetentionDays = 30 }
        #expect(try await summaries().dropFirst() == ["Changed ollamaBinaryPath to null", "Changed traceRawRetentionDays to 30"],
                "a setting taken away is said to be null, and a value that is not text is written as settings.json writes it")
        try await actions.change { $0.renameFiles = false }
        #expect(try await summaries().count == 3, "a change that changes nothing records nothing")
        await #expect(throws: ConfigError.self, "settings the next launch would refuse are refused, so the app shows why") {
            try await actions.change { $0.profile = "lowMemory" }
        }
        #expect(try await summaries().count == 3, "and recorded nowhere")
    }

    @Test func aChangedPredefinedProfileIsSavedAsItsChangeAloneAndNothingOnceSetBack() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let bundled = try AppSettings.bundledDefaults().modelProfile("smart")
        try await env.settings.update { $0.modelProfiles["smart"]?.chatModel = "gpt-oss:20b" }
        let changed = try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: env.paths.settingsURL))
        #expect(changed["modelProfiles"] == ["smart": ["chatModel": "gpt-oss:20b"]] && changed["profile"] == nil,
                "the user's file holds the one field changed, so the profile's other models still follow the bundled ones")
        #expect(try await SettingsStore(paths: env.paths).current.modelProfile("smart").chatModel == "gpt-oss:20b",
                "and the change survives a restart")
        try await env.settings.update { $0.modelProfiles["smart"] = bundled }
        let reset = try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: env.paths.settingsURL))
        #expect(reset["modelProfiles"] == nil, "a profile set back to the bundled one is saved as nothing, so a new default reaches it")
    }

    @Test func settingsTheNextLaunchWouldRefuseAreRefusedBeforeTheyAreSaved() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let file = try Data(contentsOf: env.paths.settingsURL)
        let current = await env.settings.current
        let mine = ModelProfile(name: "Mine", position: 4, chatModel: "qwen3.5:9b", visionModel: " ", embedModel: "bge-m3")
        let refused: [(String, @Sendable (inout AppSettings) -> Void)] = [
            ("profile", { $0.profile = "lowMemory" }),
            ("modelProfiles.fast.name", { $0.modelProfiles["fast"]?.name = "  " }),
            ("modelProfiles.smart.chatModel", { $0.modelProfiles["smart"]?.chatModel = "" }),
            ("modelProfiles.standard.embedModel", { $0.modelProfiles["standard"]?.embedModel = "\n" }),
            ("modelProfiles.mine.visionModel", { $0.modelProfiles["mine"] = mine }),
            ("modelProfiles.smart.name", { $0.modelProfiles["smart"]?.name = "fast" }),
        ]
        for (key, change) in refused {
            await #expect("settings with \(key) the app cannot use are refused, with the reason that names the key") {
                try await env.settings.update(change)
            } throws: { error in
                guard case let ConfigError.invalid(name, underlying) = error else { return false }
                return name == "settings" && underlying.hasPrefix(key + " ")
            }
            #expect(try Data(contentsOf: env.paths.settingsURL) == file, "\(key): nothing is written, so the next launch still starts")
            #expect(await env.settings.current == current, "\(key): and the app goes on with the settings it had")
        }
        try Data(#"{"profile": "lowMemory"}"#.utf8).write(to: env.paths.settingsURL)
        #expect("a file naming a profile it does not list stops the load, naming the profile") {
            try SettingsStore(paths: env.paths)
        } throws: { error in
            (error as? ConfigError)?.localizedDescription.contains("lowMemory") == true
        }
    }

    /// Whether `error` refuses the configuration `name` for each key of `paths`, which the app does not know.
    private func refuses(_ error: any Error, _ name: String, unknown paths: [String]) -> Bool {
        guard case let ConfigError.invalid(refused, underlying) = error else { return false }
        return refused == name && underlying == paths.map(ConfigLoader.unknownKey).joined(separator: "; ")
    }

    @Test func aScratchRunCanGiveTheAppAFolderAsItsTrashAndOtherwiseItUsesTheUsers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let users = FolderTrash(folder: folder.appendingPathComponent("users", isDirectory: true))
        let scratch = RuntimeEnvironment(home: nil, ollamaURL: nil, logLevelName: nil, pipelineOverridePath: nil, trashPath: folder.path)
        let trash = try #require(scratch.trash(orElse: users) as? FolderTrash, "ARRUMATOR_TRASH names a folder the app uses as its Trash")
        #expect(trash.folder.path == folder.path, "that folder")
        #expect((TestEnvironment.isolated.trash(orElse: users) as? FolderTrash)?.folder == users.folder,
                "and without it the Trash is the one the app gives, the user's")
    }

    @Test func aKeyTheAppDoesNotKnowStopsTheLoadNamingItAndKeysItKnowsLoad() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try Data(#"{"models": {"profile": "lowMemory"}, "renameFiles": false}"#.utf8).write(to: env.paths.settingsURL)
        #expect("a choice of profile an earlier version saved stops the app naming the key, rather than being read as another") {
            try SettingsStore(paths: env.paths)
        } throws: { refuses($0, "settings", unknown: ["models"]) }
        let extra = env.root.appendingPathComponent("extra.json")
        let environment = RuntimeEnvironment(home: nil, ollamaURL: nil, logLevelName: nil, pipelineOverridePath: extra.path, trashPath: nil)
        for (override, unknown) in [(#"{"modelProfiles": {"standard": {"numCtx": 8192}}}"#, ["modelProfiles"]),
                                    (#"{"tasks": {"efforts": {"low": {"model": "fast", "fallback": false, "repairAttempts": 1}}}}"#,
                                     ["tasks.efforts.low.fallback", "tasks.efforts.low.model"])] {
            try Data(override.utf8).write(to: env.paths.pipelineOverrideURL)
            #expect("\(override) sets what the pipeline no longer reads, so it stops the app naming each key") {
                try PipelineConfig.load(paths: env.paths, environment: TestEnvironment.isolated)
            } throws: { refuses($0, "pipeline", unknown: unknown) }
        }
        try Data(#"{"search": {"rrfK": 30}}"#.utf8).write(to: env.paths.pipelineOverrideURL)
        try Data(#"{"analysis": {"fastNumCtx": 8192}}"#.utf8).write(to: extra)
        #expect("ARRUMATOR_PIPELINE_CONFIG is held to the same rule") {
            try PipelineConfig.load(paths: env.paths, environment: environment)
        } throws: { refuses($0, "pipeline", unknown: ["analysis.fastNumCtx"]) }

        try Data(#"""
            {"ollamaBinaryPath": "/opt/homebrew/bin/ollama", "profile": "mine", "renameFiles": null,
             "modelProfiles": {"mine": {"name": "Mine", "position": 4, "chatModel": "qwen3.5:9b", "visionModel": "qwen3.5:9b",
                                        "embedModel": "bge-m3"},
                               "smart": {"chatModel": "gpt-oss:20b"}}}
            """#.utf8).write(to: env.paths.settingsURL)
        let settings = try await SettingsStore(paths: env.paths).current
        #expect(settings.ollamaBinaryPath == "/opt/homebrew/bin/ollama" && settings.renameFiles,
                "an optional setting loads, and a null one sets nothing")
        #expect(try settings.modelProfile().name == "Mine" && settings.modelProfiles["smart"]?.chatModel == "gpt-oss:20b",
                "a profile of the user's own, under an id of its own, and a change to a bundled one load")
        try Data(#"""
            {"ollama": {"serveEnvironment": {"OLLAMA_FLASH_ATTENTION": "1"}},
             "labels": {"vocabulary": {"kinds": {"language": {"mergeSimilarity": 1, "suggestSimilarity": 1, "promptLimit": 5}}}}}
            """#.utf8).write(to: env.paths.pipelineOverrideURL)
        try Data(#"{"tasks": {"efforts": {"high": {"promptLabels": {"object": 5}}}}}"#.utf8).write(to: extra)
        let config = try PipelineConfig.load(paths: env.paths, environment: environment)
        #expect(config.ollama.serveEnvironment["OLLAMA_FLASH_ATTENTION"] == "1" && config.labels.vocabulary.kinds[.language]?.promptLimit == 5
                    && config.tasks.efforts[.high]?.promptLabels[.object] == 5,
                "keys of a dictionary the user fills, from either override, load: a variable for Ollama, a kind, an effort's labels")
    }
}

/// The Ollama server the app talks to: where it may be, how its address is written, and the bounds on its answers.
extension ConfigTests {
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
        #expect(OllamaEndpoint.isThisMac(try OllamaEndpoint.validated("http://LOCALHOST:11434")), "however it is cased")
        #expect(!OllamaEndpoint.isThisMac(try OllamaEndpoint.validated("http://192.168.1.239:11434")), "an address on the local network is another machine")
        let config = try PipelineConfig.bundledDefaults().ollama
        #expect(throws: OllamaError.self, "the client itself refuses a host beyond the local network") {
            try OllamaClient(config: config, baseURL: try #require(URL(string: "http://example.com:11434")), time: TestTime(.advances))
        }
    }

    /// An address names a scheme, a host, a port and a path. A user name and password would go into the log and History
    /// with it, and a query or fragment means nothing to Ollama; a host written with escapes is one host when checked
    /// and another when compared, so it is refused rather than read two ways.
    @Test func anOllamaAddressNamesItsServerAndNothingElse() throws {
        let refused: [(String, OllamaError)] = [
            ("http://ollama:s3cret@192.168.1.239:11434", .invalidAddress(.userInfo)),
            ("http://ollama@localhost:11434", .invalidAddress(.userInfo)),
            ("http://127.0.0.1:11434/?model=x", .invalidAddress(.query)),
            ("http://127.0.0.1:11434/#top", .invalidAddress(.fragment)),
            ("http://127.0.0.%31:11434", .invalidAddress(.escapedHost)),
            ("http://gpu%2Dbox.local:11434", .invalidAddress(.escapedHost)),
            ("ftp://192.168.1.2", .invalidAddress(.scheme)),
            ("http://", .invalidAddress(.noHost)),
            ("http://ollama:s3cret@gpu box:11434", .invalidAddress(.unreadable)),
        ]
        for (address, error) in refused {
            #expect(throws: error, "\(address)") { _ = try OllamaEndpoint.validated(address) }
        }
        let said = OllamaError.invalidAddress(.userInfo).localizedDescription
        #expect(!said.contains("s3cret") && said.contains("a user name or password"), "what is refused is named, never the password: \(said)")
        // Addresses that do not read as a URL at all, a space in the host or an unclosed IPv6 bracket, with a password.
        for unreadable in ["http://ollama:s3cret@gpu box:11434", "http://ollama:s3cret@[fe80::1:11434"] {
            do {
                _ = try OllamaEndpoint.validated(unreadable)
                Issue.record("\(unreadable) is refused")
            } catch {
                #expect(!error.localizedDescription.contains("s3cret"), "an address that does not read is never repeated: \(error.localizedDescription)")
            }
        }
        #expect(try OllamaEndpoint.validated("http://192.168.1.239:11434/ollama").path() == "/ollama", "a path, as a proxy of the user's serves it, is kept")
        let config = try PipelineConfig.bundledDefaults().ollama
        #expect(throws: OllamaError.invalidAddress(.userInfo), "the client itself refuses one") {
            try OllamaClient(config: config, baseURL: try #require(URL(string: "http://ollama:s3cret@127.0.0.1:11434")), time: TestTime(.advances))
        }
    }

    @Test func ollamasTimeoutsAndAnswerSizeAreRefusedWhereTheyMakeNoSense() throws {
        var config = try PipelineConfig.bundledDefaults()
        #expect(config.ollama.maxResponseBytes > 1 << 20, "the bundled limit holds the largest answer the app asks for, an embedding batch")
        config.ollama.timeouts.chat = -1
        config.ollama.maxResponseBytes = 0
        config.ollama.modelLocationMaxAge = -1
        #expect(config.problems.contains("ollama.timeouts.chat cannot be negative: 0 is no timeout")
                    && config.problems.contains("ollama.maxResponseBytes must be at least 1")
                    && config.problems.contains("ollama.modelLocationMaxAge cannot be negative: 0 asks before every request"),
                "\(config.problems)")
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
        let body = OllamaChatRequest.sample(format: schema, think: nil).body.serialized()
        let r = try #require(body.range(of: "correspondent"))
        let f = try #require(body.range(of: "file_name"))
        #expect(r.lowerBound < f.lowerBound, "the model is asked for the properties in the order the schema gives them")
    }
}
