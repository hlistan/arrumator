import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// Model profiles are the user's to add, change, set back and remove (docs/using-arrumator.md): a new one is a copy of
/// another, so no model name is written in code; a predefined one is changed and reset but never removed; the one in use
/// and one search tasks of the archive read with stay. Each change is checked against the settings in force and made in
/// the same step, so changes made at once all hold. `settings.json` holds only what differs from the bundled profiles,
/// and each change is one event in History saying what changed.
@Suite struct ModelProfileTests {
    /// Models no bundled profile names, so what a change made is told apart from what the bundled profiles say.
    static let reader = "reads-well:9b"
    static let describer = "sees-well:4b"
    static let embedder = "embeds-well"

    struct World {
        let h: Harness
        let profiles: ModelProfileActions
        let bundled: AppSettings

        var file: URL { h.env.paths.settingsURL }

        /// The user's `settings.json` as it was written.
        func saved() throws -> JSONValue { try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: file)) }

        /// The settings changes in History, in the order they were recorded: the test clock stands still, so by number.
        func events() async throws -> [EventRecord] {
            try await h.services.history.events(limit: 100, kinds: [.settingsChanged]).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        }

        /// The bundled profiles' ids, in the order they are listed.
        var bundledIDs: [String] { bundled.modelProfiles.sorted { $0.value.position < $1.value.position }.map(\.key) }

        /// A bundled profile other than the one in use.
        var otherBundled: String { bundledIDs.first { $0 != bundled.profile } ?? bundled.profile }
    }

    func world() async throws -> World {
        let h = try await Harness.make()
        let bundled = try AppSettings.bundledDefaults()
        let settings = SettingsActions(store: h.env.settings, history: h.services.history)
        return World(h: h, profiles: ModelProfileActions(settings: settings, bundled: bundled.modelProfiles, database: h.env.database),
                     bundled: bundled)
    }

    /// `profile` as `settings.json` holds it.
    private func json(_ profile: ModelProfile) throws -> JSONValue {
        try JSON.decoder.decode(JSONValue.self, from: JSON.encoder.encode(profile))
    }

    @Test func theProfilesAreListedInOrderTheBundledOnesPredefinedAndTheOneSettingsUsesInUse() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let listed = await w.profiles.list()
        #expect(listed.map(\.id) == w.bundledIDs, "the bundled profiles come by their position, as JSON objects keep no order")
        #expect(listed.allSatisfy { $0.predefined && !$0.changed && $0.profile == w.bundled.modelProfiles[$0.id] },
                "each is predefined, and unchanged as the bundled settings give it")
        #expect(listed.filter(\.inUse).map(\.id) == [w.bundled.profile], "the one Settings reads with is the one in use, and only it")
        let first = try #require(listed.first)
        let early = ModelProfile(name: "Aardvark", position: first.profile.position, chatModel: Self.reader, visionModel: Self.describer,
                                 embedModel: Self.embedder)
        try await w.h.env.settings.update { $0.modelProfiles["zeta"] = early }
        let mixed = await w.profiles.list()
        #expect(mixed.map(\.id) == ["zeta"] + w.bundledIDs, "a profile at the same position comes by its name: \(mixed.map(\.id))")
        #expect(mixed.first.map { !$0.predefined && !$0.changed && !$0.inUse } == true, "a profile of the user's own is neither predefined nor changed")
    }

    @Test func aNewProfileCopiesAnotherUnderAnIdOfItsOwn() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let inUse = try w.bundled.modelProfile()
        let last = try #require(w.bundled.modelProfiles.values.map(\.position).max())
        let mine = try await w.profiles.add(name: "  Mine\n", change: ModelProfileChange(models: [.chat: Self.reader]))
        #expect(mine.id == "mine" && mine.profile.name == "Mine", "its id is its name in lowercase, and its name is on one line")
        #expect(mine.profile == ModelProfile(name: "Mine", position: last + 1, chatModel: Self.reader, visionModel: inUse.visionModel,
                                             embedModel: inUse.embedModel),
                "a copy of the profile in use, with the model the change gives, after the last profile")
        #expect(!mine.predefined && !mine.changed && !mine.inUse, "it is the user's own, and Settings goes on with the one it uses")
        let saved = try w.saved()
        #expect(saved["modelProfiles"] == .object(["mine": try json(mine.profile)]),
                "settings.json holds the whole new profile and nothing of the bundled ones: \(String(describing: saved["modelProfiles"]))")
        #expect(saved["profile"] == nil, "nor the profile in use, which did not change")

        let source = try w.bundled.modelProfile(w.otherBundled)
        let copied = try await w.profiles.add(name: "Mine!", copying: w.otherBundled)
        #expect(copied.id == "mine-2", "a name whose id is taken gets a suffix: \(copied.id)")
        #expect(copied.profile == ModelProfile(name: "Mine!", position: last + 2, chatModel: source.chatModel, visionModel: source.visionModel,
                                               embedModel: source.embedModel),
                "every model of the profile it copies is kept when the change gives none")
        let worded = try await w.profiles.add(name: "Für  den\tAlltag 2", change: ModelProfileChange(models: [.embedding: Self.embedder]))
        #expect(worded.id == "für-den-alltag-2" && worded.profile.name == "Für den Alltag 2",
                "the id is the name's letters and digits, in lowercase, its words joined by hyphens: \(worded.id)")
        #expect(await w.profiles.list().map(\.id) == w.bundledIDs + ["mine", "mine-2", "für-den-alltag-2"], "each new one comes last")
        let reloaded = try await SettingsStore.opened(paths: w.h.env.paths).current
        #expect(reloaded.modelProfiles["mine"] == mine.profile, "and the profiles are there at the next launch")
    }

    @Test func aPredefinedProfileIsChangedAndResetButNeverRemoved() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let id = w.otherBundled
        let changed = try await w.profiles.update(id, ModelProfileChange(models: [.chat: Self.reader]))
        #expect(changed.changed && changed.predefined && changed.profile.chatModel == Self.reader, "the listing says the predefined profile is changed")
        #expect(try w.saved()["modelProfiles"] == .object([id: .object(["chatModel": .string(Self.reader)])]),
                "settings.json holds the changed field alone, so the profile's other models still follow the bundled ones")
        let reset = try await w.profiles.reset(id)
        #expect(!reset.changed && reset.profile == w.bundled.modelProfiles[id], "reset, it is the bundled profile again")
        #expect(try w.saved()["modelProfiles"] == nil, "and settings.json no longer mentions it, so a new bundled value reaches it")
        let file = try Data(contentsOf: w.file)
        for predefined in w.bundledIDs {
            let name = try w.bundled.modelProfile(predefined).name
            await #expect(throws: ModelProfileError.predefined(name), "\(predefined): the bundled settings would bring it back, named by its name") {
                try await w.profiles.remove(predefined)
            }
        }
        #expect(try Data(contentsOf: w.file) == file, "and nothing is written")
        #expect(await w.profiles.list().map(\.id) == w.bundledIDs, "every predefined profile is still listed")
    }

    @Test func theProfileInUseIsNotRemovedNorOneSearchTasksReadWithUntilTheyAreGivenAnother() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let mine = try await w.profiles.add(name: "Mine")
        try await w.profiles.use(mine.id)
        await #expect(throws: ModelProfileError.inUse("Mine"), "the profile Settings reads with stays, named by its name") {
            try await w.profiles.remove(mine.id)
        }
        try await w.profiles.use(w.bundled.profile)
        let (_, tasks) = w.h.searchTasks(StubInterpreter(plans: [:]))
        let first = try await tasks.create(prompt: SearchTaskTests.prompt, profile: mine.id)
        let second = try await tasks.create(prompt: SearchTaskTests.prompt, profile: mine.id)
        await #expect(throws: ModelProfileError.namedByTasks("Mine", count: 2), "nor one search tasks read with, which says how many") {
            try await w.profiles.remove(mine.id)
        }
        #expect(ModelProfileError.namedByTasks("Mine", count: 2).localizedDescription.hasPrefix("2 search tasks in this archive read with"),
                "the reason counts the tasks of the archive that is open, the only ones it knows of, so the user knows what to change first")
        #expect(try w.saved()["modelProfiles"]?[mine.id] != nil, "and nothing is removed")
        try await tasks.update(first.id, SearchTaskChange(profile: w.otherBundled))
        await #expect(throws: ModelProfileError.namedByTasks("Mine", count: 1), "while one task still reads with it") {
            try await w.profiles.remove(mine.id)
        }
        try await tasks.update(second.id, SearchTaskChange(profile: ""))
        let removed = try await w.profiles.remove(mine.id)
        #expect(removed.id == mine.id && removed.profile == mine.profile, "once no task reads with it, it is removed")
        #expect(try w.saved()["modelProfiles"] == nil, "settings.json no longer mentions it")
        #expect(await w.profiles.list().map(\.id) == w.bundledIDs, "and it is no longer listed")
    }

    @Test func blankAndTakenNamesBlankModelsUnknownProfilesAndAResetOfTheUsersOwnAreRefused() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let mine = try await w.profiles.add(name: "Mine")
        let other = try w.bundled.modelProfile(w.otherBundled)
        let file = try Data(contentsOf: w.file)
        let recorded = try await w.events().count
        let refusals: [(ModelProfileError, String, @Sendable () async throws -> Void)] = [
            (.blankName(nil), "a new profile without a name", { _ = try await w.profiles.add(name: " \n") }),
            (.nameTaken(name: other.name.uppercased(), by: other.name), "another profile's name in other letters, named by its name",
             { _ = try await w.profiles.add(name: other.name.uppercased()) }),
            (.nameWithoutLetterOrDigit("★ ☆"), "a name with no letter or digit to make an id of", { _ = try await w.profiles.add(name: "★ ☆") }),
            (.blankModel(profile: "Yours", role: .chat), "a new profile without a model to read with",
             { _ = try await w.profiles.add(name: "Yours", change: ModelProfileChange(models: [.chat: "  "])) }),
            (.unknown("nonexistent"), "a copy of a profile there is none of",
             { _ = try await w.profiles.add(name: "Yours", copying: "nonexistent") }),
            (.blankName("Mine"), "a name taken away", { _ = try await w.profiles.update(mine.id, ModelProfileChange(name: "")) }),
            (.nameTaken(name: other.name, by: other.name), "a name another profile has",
             { _ = try await w.profiles.update(mine.id, ModelProfileChange(name: other.name)) }),
            (.blankModel(profile: "Mine", role: .vision), "a model to describe images taken away",
             { _ = try await w.profiles.update(mine.id, ModelProfileChange(models: [.vision: "\n"])) }),
            (.blankModel(profile: "Mine", role: .embedding), "a model to find by meaning taken away",
             { _ = try await w.profiles.update(mine.id, ModelProfileChange(models: [.embedding: ""])) }),
            (.unknown("nonexistent"), "a change to a profile there is none of",
             { _ = try await w.profiles.update("nonexistent", ModelProfileChange(models: [.chat: Self.reader])) }),
            (.notPredefined("Mine"), "a reset of the user's own profile, which has nothing to go back to", { _ = try await w.profiles.reset(mine.id) }),
            (.unknown("nonexistent"), "a reset of a profile there is none of", { _ = try await w.profiles.reset("nonexistent") }),
            (.unknown("nonexistent"), "a removal of a profile there is none of", { _ = try await w.profiles.remove("nonexistent") }),
            (.unknown("nonexistent"), "reading with a profile there is none of", { _ = try await w.profiles.use("nonexistent") }),
        ]
        for (error, what, action) in refusals {
            await #expect(throws: error, "\(what) is refused, saying why") { try await action() }
            #expect(!(error.errorDescription ?? "").isEmpty, "\(what): the reason is worded")
        }
        #expect(try Data(contentsOf: w.file) == file, "nothing of a refused change is written")
        #expect(try await w.events().count == recorded, "and nothing is recorded")
        #expect(try await w.profiles.update(mine.id, ModelProfileChange(name: "MINE")).profile.name == "MINE",
                "a profile may take its own name in other letters")
    }

    @Test func aNewNameIsCheckedAsAddingChecksItNamingTheProfileThatHasItByItsName() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        // Renamed, so its name and its id differ, as the user's renaming leaves them.
        _ = try await w.profiles.update(w.otherBundled, ModelProfileChange(name: "Everyday Reader"))
        let settings = await w.h.env.settings.current
        let names: [(String, ModelProfileError?, String)] = [
            ("EVERYDAY reader", .nameTaken(name: "EVERYDAY reader", by: "Everyday Reader"), "another profile's name in other letters"),
            (" \n", .blankName(nil), "a blank name"),
            ("!!!", .nameWithoutLetterOrDigit("!!!"), "a name with no letter or digit"),
            (" Mine\t", nil, "a name of its own, whatever the space around it"),
        ]
        for (name, refusal, what) in names {
            #expect(ModelProfileActions.refusal(ofNewName: name, in: settings) == refusal, "\(what): said as it is typed")
            if let refusal {
                await #expect(throws: refusal, "\(what): and refused the same when it is added") { try await w.profiles.add(name: name) }
            }
        }
        let taken = ModelProfileError.nameTaken(name: "EVERYDAY reader", by: "Everyday Reader").localizedDescription
        #expect(taken.contains("the profile “Everyday Reader”") && !taken.contains("“\(w.otherBundled)”"),
                "the profile that has the name is named as the app lists it, never by its id: \(taken)")
        let letterless = ModelProfileError.nameWithoutLetterOrDigit("!!!").localizedDescription
        #expect(!letterless.contains("id"), "and the user is not told of ids, which the app never shows: \(letterless)")
    }

    @Test func whyAProfileCannotBeRemovedIsKnownBeforeItIsAskedAndIsWhatRemovingRefuses() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        for listing in await w.profiles.list() {
            #expect(listing.removalRefusal(searchTasks: 0) == .predefined(listing.profile.name),
                    "\(listing.id): one that comes with Arrumator is never removed, named by its name")
        }
        let mine = try await w.profiles.add(name: "Mine")
        func listed() async throws -> ModelProfileListing { try #require(await w.profiles.list().first { $0.id == mine.id }) }
        try await w.profiles.use(mine.id)
        #expect(try await listed().removalRefusal(searchTasks: 0) == .inUse("Mine"), "the one Settings reads with stays")
        try await w.profiles.use(w.bundled.profile)
        let (_, tasks) = w.h.searchTasks(StubInterpreter(plans: [:]))
        let task = try await tasks.create(prompt: SearchTaskTests.prompt, profile: mine.id)
        let reading = try await w.profiles.searchTasks(readingWith: mine.id)
        #expect(reading == 1, "the tasks of the archive that read with it are counted")
        let refusal = try #require(try await listed().removalRefusal(searchTasks: reading), "one a task reads with is not removed")
        #expect(refusal == .namedByTasks("Mine", count: 1), "which says how many, naming the profile by its name")
        await #expect(throws: refusal, "and removing it is refused for the very reason given before it was asked") {
            try await w.profiles.remove(mine.id)
        }
        try await tasks.update(task.id, SearchTaskChange(profile: ""))
        #expect(try await w.profiles.searchTasks(readingWith: mine.id) == 0, "a task given Settings' profile no longer reads with it")
        #expect(try await listed().removalRefusal(searchTasks: 0) == nil, "so it can be removed")
        _ = try await w.profiles.remove(mine.id)
    }

    @Test func thePredefinedProfilesAreNamedAsTheyComeHoweverTheUserRenamedThem() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let comeAs = w.bundledIDs.compactMap { w.bundled.modelProfiles[$0]?.name }
        _ = try await w.profiles.update(w.otherBundled, ModelProfileChange(name: "Smart QA"))
        #expect(w.profiles.predefinedNames == comeAs, "the names Arrumator comes with, in their order, not the user's: \(w.profiles.predefinedNames)")
    }

    @Test func eachProfileChangeIsOneHistoryEventSayingWhatChangedAndNoChangeRecordsNone() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let id = w.otherBundled
        let bundled = try w.bundled.modelProfile(id)
        let mine = try await w.profiles.add(name: "Mine", change: ModelProfileChange(models: [.chat: Self.reader]))
        _ = try await w.profiles.update(id, ModelProfileChange(models: [.chat: Self.describer]))
        _ = try await w.profiles.update(mine.id, ModelProfileChange(name: "Mine", models: [.chat: Self.reader]))
        _ = try await w.profiles.update(mine.id, ModelProfileChange(name: "Yours", models: [.vision: Self.describer, .embedding: Self.embedder]))
        _ = try await w.profiles.reset(id)
        _ = try await w.profiles.reset(id)
        try await w.profiles.use(mine.id)
        try await w.profiles.use(mine.id)
        try await w.profiles.use(w.bundled.profile)
        _ = try await w.profiles.remove(mine.id)
        let events = try await w.events()
        #expect(events.map(\.summary) == [
            "Added the profile “Mine”, reading with \(Self.reader)",
            "The profile “\(bundled.name)” reads with \(Self.describer) instead of \(bundled.chatModel)",
            "The profile “Mine” is renamed “Yours”, describes images with \(Self.describer) instead of \(mine.profile.visionModel) "
                + "and finds by meaning with \(Self.embedder) instead of \(mine.profile.embedModel)",
            "Reset the profile “\(bundled.name)”",
            "Reading with the profile “Yours”",
            "Reading with the profile “\(try w.bundled.modelProfile().name)”",
            "Removed the profile “Yours”",
        ], "one event per change, saying what changed in words; the same values again, or a reset of an unchanged profile, record none")
        #expect(events.allSatisfy { $0.actor == .user }, "each is the user's doing")
        let payloads = events.map { JSON.decode([String: JSONValue].self, from: $0.payloadJson) }
        #expect(payloads[4] == ["profile": .string(mine.id)], "choosing a profile records the setting it changed, with its new value")
        #expect(payloads[0]?.keys.sorted() == ["modelProfiles"], "a change to the profiles records the profiles as they are now")
    }

    @Test func changesMadeAtOnceAllHoldAndAChangeRacingARemovalNeverBringsTheProfileBack() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let mine = try await w.profiles.add(name: "Mine")
        let changes = [ModelProfileChange(name: "Yours"), ModelProfileChange(models: [.chat: Self.reader]),
                       ModelProfileChange(models: [.vision: Self.describer]), ModelProfileChange(models: [.embedding: Self.embedder])]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for change in changes { group.addTask { _ = try await w.profiles.update(mine.id, change) } }
            try await group.waitForAll()
        }
        let expected = ModelProfile(name: "Yours", position: mine.profile.position, chatModel: Self.reader, visionModel: Self.describer,
                                    embedModel: Self.embedder)
        #expect(try await w.h.env.settings.current.modelProfile(mine.id) == expected,
                "each change is made to the profile as the change before it left it, so none is lost")
        #expect(try await SettingsStore.opened(paths: w.h.env.paths).current.modelProfile(mine.id) == expected, "and so it is saved")
        #expect(try await w.events().count == 1 + changes.count, "each is in History once")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await w.profiles.remove(mine.id) }
            group.addTask { _ = try? await w.profiles.update(mine.id, ModelProfileChange(models: [.chat: Self.describer])) }
            try await group.waitForAll()
        }
        #expect(await w.h.env.settings.current.modelProfiles[mine.id] == nil,
                "a change made while the profile is removed is refused once it is gone, rather than writing it back")
        #expect(try w.saved()["modelProfiles"] == nil, "and settings.json no longer mentions it")
    }

    @Test func aChangeRefusedAgainstTheSettingsInForceSavesAndRecordsNothing() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let mine = try await w.profiles.add(name: "Mine")
        let file = try Data(contentsOf: w.file)
        let recorded = try await w.events().count
        await #expect(throws: ModelProfileError.unknown(mine.id), "a change whose check against the settings in force fails is refused") {
            try await w.profiles.settings.change(checking: { settings in
                // As a removal made meanwhile would leave them, then the check a change of the profile makes.
                settings.modelProfiles[mine.id] = nil
                _ = try settings.modelProfile(mine.id)
                return (summary: "Never recorded", outcome: ())
            })
        }
        #expect(try Data(contentsOf: w.file) == file, "nothing of it is written, not even what it changed before it was refused")
        #expect(await w.h.env.settings.current.modelProfiles[mine.id] == mine.profile, "the settings in force are as they were")
        #expect(try await w.events().count == recorded, "and nothing is recorded")
    }

    @Test func eachRoleIsPlayedByTheModelTheProfileGivesItAndAChangeForARoleChangesItAlone() async throws {
        let profile = ModelProfile(name: "Mine", position: 4, chatModel: Self.reader, visionModel: Self.describer, embedModel: Self.embedder)
        #expect(ModelProfile.roles == [.chat, .vision, .embedding], "the roles in the order Settings and History list them")
        #expect(ModelProfile.roles.map(profile.model(for:)) == [Self.reader, Self.describer, Self.embedder],
                "reading, describing images and finding by meaning, each by the profile's model for it")
        let w = try await world()
        defer { w.h.env.cleanup() }
        let mine = try await w.profiles.add(name: "Mine")
        for role in ModelProfile.roles {
            let other = "\(role.rawValue)-model"
            let changed = try await w.profiles.update(mine.id, ModelProfileChange(models: [role: other])).profile
            #expect(changed.model(for: role) == other, "\(role): a change for a role gives that role its model")
            #expect(ModelProfile.roles.filter { $0 != role }.allSatisfy { changed.model(for: $0) == mine.profile.model(for: $0) },
                    "\(role): and leaves the others' as they were")
            _ = try await w.profiles.update(mine.id, ModelProfileChange(models: [role: mine.profile.model(for: role)]))
        }
        var settings = w.bundled
        settings.modelProfiles["mine"] = ModelProfile(name: "Mine", position: 4, chatModel: "", visionModel: "", embedModel: "")
        #expect(settings.problems.filter { $0.hasPrefix("modelProfiles.mine.") } == [
            "modelProfiles.mine.chatModel is empty", "modelProfiles.mine.visionModel is empty", "modelProfiles.mine.embedModel is empty",
        ], "the settings name each role's model by its key in settings.json, in the roles' order")
    }

    @Test func installedModelsAreListedWithWhatEachCanDo() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let mock = MockOllama(installed: [Self.reader, Self.describer, Self.embedder],
                              modelCapabilities: [Self.reader: ["completion"],
                                                  Self.describer: ["completion", "vision", OllamaShowResponse.thinkingCapability],
                                                  Self.embedder: ["embedding"]],
                              modelThinking: [Self.describer: .levels]) { _ in "" }
        let installed = try await ModelManager(api: mock, config: env.config.ollama).installed()
        let sizes = try await mock.tags().map(\.size)
        #expect(installed.map(\.name) == [Self.reader, Self.describer, Self.embedder] && installed.map(\.sizeBytes) == sizes,
                "every installed model, in Ollama's order, with its size")
        #expect(installed.map(\.roles) == [[.chat], [.chat, .vision], [.embedding]],
                "a model that answers in words reads, and describes images when it sees them; one that embeds finds by meaning")
        #expect(installed.map(\.thinking) == [[], ["low", "medium", "high"], []],
                "one that thinks lists how it is told to: its levels; one that cannot lists none")
        #expect(installed.map(\.capabilities) == [["completion"], ["completion", "vision", OllamaShowResponse.thinkingCapability], ["embedding"]],
                "and what Ollama says each can do is kept as it says it")
    }

    /// The servers the user points the app at, one after the other, as `OllamaConnection` forwards to one at a time.
    final class Servers: OllamaAPI {
        private let all: [MockOllama]
        private let current = Mutex(0)

        init(_ all: [MockOllama]) { self.all = all }

        func use(_ index: Int) { current.withLock { $0 = index } }
        private var server: MockOllama { all[current.withLock { $0 }] }

        var baseURL: URL { server.baseURL }
        func version() async throws -> String { try await server.version() }
        func tags() async throws -> [OllamaModelInfo] { try await server.tags() }
        func show(model: String) async throws -> OllamaShowResponse { try await server.show(model: model) }
        func chat(_ request: OllamaChatRequest, partial: (@Sendable (OllamaChatResponse) async -> Void)?) async throws -> OllamaChatResponse {
            try await server.chat(request, partial: partial)
        }
        func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse { try await server.embed(request) }
        func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> { server.pull(model: model) }
    }

    @Test func whatAModelCanDoIsAskedAgainOfAnotherServer() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let other = try #require(URL(string: "http://192.168.1.20:11434"))
        let servers = Servers([MockOllama(installed: [Self.reader], modelCapabilities: [Self.reader: ["completion"]]) { _ in "" },
                               MockOllama(installed: [Self.reader], modelCapabilities: [Self.reader: ["completion", "vision"]],
                                          server: other) { _ in "" }])
        let models = ModelManager(api: servers, config: env.config.ollama)
        #expect(try await models.capabilities(of: Self.reader).capabilities == ["completion"], "this Mac's model reads")
        servers.use(1)
        #expect(try await models.capabilities(of: Self.reader).capabilities == ["completion", "vision"],
                "the model of that name on the server the user points the app at next is asked of there, not taken for this Mac's")
        #expect(try await models.installed().map(\.roles) == [[.chat, .vision]], "and is offered for what it can do there")
    }
}
