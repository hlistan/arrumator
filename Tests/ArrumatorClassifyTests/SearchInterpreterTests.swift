@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The model reads what a person asks for, in their own words, as a plan: labels of each kind, words, an arrangement
/// and a name, checked as a document's answer is, and told the archive's labels and today's date.
@Suite struct SearchInterpreterTests {
    static func validator() throws -> SearchPlanValidator {
        let config = try PipelineConfig.bundledDefaults()
        return SearchPlanValidator(tasks: config.tasks, labels: config.labels)
    }

    static let request = "EDP electricity invoices from 2025, by sender and year"

    /// A label asked for, with the words of the request the model quotes for it.
    static func asked(_ value: String, _ askedAs: String) -> JSONValue {
        .object(["value": .string(value), "asked_as": .string(askedAs)])
    }

    /// The answer to `request`: EDP's electricity invoices of 2025, by sender and year. `overrides` replaces a list,
    /// `omitting` leaves one out.
    static func answer(_ overrides: [String: JSONValue] = [:], omitting: String? = nil) -> String {
        var fields: [String: JSONValue] = [:]
        for kind in ClassificationSchema.answerOrder { fields[ClassificationSchema.labelsKey(kind)] = .array([]) }
        fields["senders"] = .array([asked("EDP Comercial", "EDP")])
        fields["types"] = .array([asked("invoice", "invoices")])
        fields["topics"] = .array([asked("Electricity", "electricity")])
        fields["dates"] = .array([asked("2025", "2025")])
        fields["words"] = .array([])
        fields["group_by"] = .array([.string("sender"), .string("date")])
        fields["title"] = .string("EDP invoices 2025")
        for (key, value) in overrides { fields[key] = value }
        if let omitting { fields[omitting] = nil }
        return JSON.string(fields)
    }

    static func strings(_ values: String...) -> JSONValue { .array(values.map(JSONValue.string)) }

    static let edp2025 = SearchPlan(title: "EDP invoices 2025",
                                    labels: [DocumentLabel(kind: .sender, value: "EDP Comercial"), DocumentLabel(kind: .type, value: "invoice"),
                                             DocumentLabel(kind: .topic, value: "electricity"), DocumentLabel(kind: .date, value: "2025")],
                                    words: [], grouping: [.sender, .date])

    // MARK: Validation

    @Test func anAnswerBecomesAPlanWithEachLabelKeptAsItsKindKeepsIt() throws {
        let checked = try Self.validator().validate("<think>which bills?</think>" + Self.answer(), request: Self.request)
        #expect(checked.plan == Self.edp2025 && checked.notes.isEmpty, "a topic is lowercase, and the kinds come in their order")
    }

    @Test func aRequestIsNeverReadAsAskingForATag() throws {
        let config = try PipelineConfig.bundledDefaults()
        let schema = SearchSchema.plan(config.tasks).serialized()
        #expect(!schema.contains("\"tags\"") && !schema.contains("\"tag\""),
                "the plan's schema asks for no tag and offers no arrangement by one: a tag is the user's own: \(schema)")
        let request = Self.request
        let checked = try Self.validator().validate(Self.answer(["tags": .array([Self.asked("Taxes 2024", "electricity")])]), request: request)
        #expect(checked.plan == Self.edp2025 && checked.notes.isEmpty, "a list of tags in the answer is not read")
        #expect(throws: AnswerValidationError.invalid(["group_by: “tag” is no kind of label"]),
                "nor an arrangement by tags, which the schema does not offer; the user arranges a set by them") {
            try Self.validator().validate(Self.answer(["group_by": Self.strings("tag")]), request: request)
        }
    }

    @Test func aLabelNoWordsOfTheRequestAskForIsDropped() throws {
        let request = "facturas de la luz de agosto y septiembre de 2026"
        let checked = try Self.validator().validate(Self.answer([
            "senders": .array([]), "types": .array([Self.asked("invoice", "FACTURAS")]),
            "topics": .array([Self.asked("electricity", "luz")]),
            "dates": .array([Self.asked("2026-08", "agosto de 2026"), Self.asked("2026-09", "septiembre 2026")]),
            "jurisdictions": .array([Self.asked("Spain", "facturas de la luz"), Self.asked("Portugal", "")]),
            "languages": .array([Self.asked("es", "Spanish")]),
            "words": Self.strings("luz", "contador"),
        ]), request: request)
        #expect(checked.plan.labels.values(.type) == ["invoice"] && checked.plan.labels.values(.topic) == ["electricity"],
                "a label quoting the request's words is kept, whatever their case")
        #expect(checked.plan.labels.values(.date) == ["2026-08", "2026-09"], "a quote may leave words of the request out, in their order or not")
        #expect(checked.plan.labels.values(.jurisdiction) == ["Spain"],
                "a quote made of the request's words stands, but one of none asks for nothing")
        #expect(checked.plan.labels.values(.language).isEmpty, "and one with a word the request does not have is dropped")
        #expect(checked.notes.contains("languages: “es” is not asked for by the request (“Spanish”), dropped"), "and noted for the trace")
        #expect(checked.plan.words.isEmpty, "a word a label already asks for is no word, and one the request does not have neither")
        #expect(checked.notes.contains("words: “contador” is not in the request, dropped"), "\(checked.notes)")
    }

    /// A word of the request asks for one thing: "faturas de Portugal" asks for documents under Portuguese law, not also
    /// for documents written in Portuguese, which would silently hide a Portuguese bill written in English.
    @Test func wordsTheLabelOfOneKindQuotesGroundNoLabelOfALaterKind() throws {
        let request = "faturas e recibos de Portugal de 2026, por remetente"
        let checked = try Self.validator().validate(Self.answer([
            "senders": .array([]), "types": .array([Self.asked("invoice", "faturas"), Self.asked("receipt", "recibos")]),
            "topics": .array([]), "dates": .array([Self.asked("2026", "2026")]),
            "jurisdictions": .array([Self.asked("Portugal", "de Portugal")]),
            "languages": .array([Self.asked("pt", "Portugal")]),
        ]), request: request)
        #expect(checked.plan.labels.values(.jurisdiction) == ["Portugal"], "the first kind the words ground keeps them")
        #expect(checked.plan.labels.values(.language).isEmpty, "a later kind quoting only those words asks for nothing more")
        #expect(checked.notes.contains("languages: “pt” is asked for by words a label of another kind quotes (“Portugal”), dropped"),
                "and the trace says why: \(checked.notes)")
        let both = try Self.validator().validate(Self.answer([
            "senders": .array([]), "topics": .array([]), "types": .array([Self.asked("invoice", "invoices")]),
            "dates": .array([]), "languages": .array([Self.asked("pt", "Portuguese invoices")]),
        ]), request: "Portuguese invoices")
        #expect(both.plan.labels.values(.language) == ["pt"],
                "a quote with words of its own is kept, though an earlier kind quotes some of them too")
    }

    @Test func aDateOrDeadlineAskedForMayBeAnySpanOfTime() throws {
        let request = "invoices from March 2025, from 1.4.2025 to 30.6.2025, last year, due in 2026, in Portuguese, of 54.21 euros"
        let checked = try Self.validator().validate(Self.answer([
            "dates": .array([Self.asked("2025-03", "March 2025"), Self.asked("01.04.2025/30.06.2025", "from 1.4.2025 to 30.6.2025"),
                             Self.asked("last year", "last year")]),
            "deadlines": .array([Self.asked("2026", "due in 2026")]), "senders": .array([]), "topics": .array([]),
            "languages": .array([Self.asked("Portuguese", "Portuguese"), Self.asked("Klingonese", "in")]),
            "amounts": .array([Self.asked("EUR 54.21", "54.21 euros")]),
        ]), request: request)
        #expect(checked.plan.labels.values(.date) == ["2025-03", "2025-04-01/2025-06-30"], "a month, or a span of days written day first")
        #expect(checked.plan.labels.values(.deadline) == ["2026"], "a deadline in a year")
        #expect(checked.plan.labels.values(.language) == ["pt"] && checked.plan.labels.values(.amount) == ["54.21 EUR"],
                "a language by its code, an amount as the archive writes it")
        #expect(checked.notes.contains("dates: “last year” is no date, dropped") && checked.notes.contains("languages: “Klingonese” is no language, dropped"),
                "what is no label of its kind is dropped and noted for the trace: \(checked.notes)")
    }

    @Test func eachListIsKeptOnceAndWithinItsLimits() throws {
        let config = try PipelineConfig.bundledDefaults().tasks
        let many = (1...config.maxValuesPerKind + 2).map { "Sender \($0)" }
        let request = "letters from " + many.joined(separator: ", ") + " mentioning the meter reading contador leitura kwh"
        let checked = try Self.validator().validate(Self.answer([
            "senders": .array(many.map { Self.asked($0, $0) } + [Self.asked("sender 1", "Sender 1")]),
            "types": .array([Self.asked("letter", "letters")]), "topics": .array([]), "dates": .array([]),
            "words": Self.strings("meter", "METER", "", "—", "reading", "contador", "leitura", "kwh"),
            "group_by": Self.strings("sender", "date", "sender", "topic", "type"),
            "title": .string(String(repeating: "Letters ", count: 20)),
        ]), request: request)
        #expect(checked.plan.labels.values(.sender) == Array(many.prefix(config.maxValuesPerKind)), "a kind keeps its first few, each once")
        #expect(checked.plan.words == Array(["meter", "reading", "contador", "leitura", "kwh"].prefix(config.maxWords)),
                "words once each, however cased, and only those with something to look for")
        #expect(checked.plan.grouping == Array([LabelKind.sender, .date, .topic, .type].prefix(config.maxGroupingDepth)),
                "each kind once in the arrangement, at most tasks.maxGroupingDepth deep")
        #expect(checked.plan.title.count <= config.maxTitleChars && checked.plan.title.hasPrefix("Letters"), "a long name is cut at a word")
    }

    @Test func anAnswerTheModelMustCorrectGoesBackWithWhatWasWrong() throws {
        let validator = try Self.validator()
        #expect(throws: AnswerValidationError.invalid(["group_by is missing; give [] when the request does not limit it"])) {
            try validator.validate(Self.answer(omitting: "group_by"), request: Self.request)
        }
        #expect(throws: AnswerValidationError.invalid(["group_by: “colour” is no kind of label"]), "an arrangement by what is no kind") {
            try validator.validate(Self.answer(["group_by": Self.strings("colour")]), request: Self.request)
        }
        let unfounded = Self.answer(["senders": .array([Self.asked("MEO", "phone")]), "types": .array([]), "topics": .array([]),
                                     "dates": .array([Self.asked("someday", "someday")])])
        #expect(throws: AnswerValidationError.invalid([
            "senders: “MEO” is not asked for by the request (“phone”), dropped", "dates: “someday” is no date, dropped",
            "nothing to search by: give the labels the request asks for, each with asked_as copied from the request",
        ]), "a plan left asking for nothing would find nothing, so it goes back with why") {
            try validator.validate(unfounded, request: Self.request)
        }
    }

    // MARK: Asking the model

    private struct World {
        let env: TestEnvironment
        let mock: MockOllama
        let interpreter: SearchPromptInterpreter
        let sink = MemoryTraceSink()

        /// Reads `prompt` by `profile`, else by the one Settings uses.
        func interpret(_ prompt: String, effort: TaskEffort = .medium, profile: ModelProfile? = nil,
                       vocabulary: [LabelKind: [LabelUsage]] = [:]) async throws -> SearchInterpretation {
            let profile = if let profile { profile } else { try await env.settings.current.modelProfile() }
            return try await interpreter.interpret(prompt, effort: effort, profile: profile, vocabulary: vocabulary, today: "2026-07-05",
                                                   config: env.config, trace: TraceContext(traceID: 1, sink: sink))
        }
    }

    /// The chat model of the profile Settings uses, and the other models the Ollama double has: one that thinks and says
    /// so by its capability alone, as on an older server, one that says it thinks or not as it is switched, one that thinks
    /// at the levels it names, as gpt-oss does, one that says it cannot think, and one that only embeds.
    static let chat = ClassifyHarness.chatModel
    static let thinker = "qwen3.5:9b"
    static let switcher = "deepseek-r1:8b"
    static let leveller = "gpt-oss:20b"
    static let nonThinker = "gemma3:12b"

    /// A profile of the user's that reads with `model`, and describes images with another, so only its chat model can
    /// have read a request.
    static func profile(reading model: String) -> ModelProfile {
        ModelProfile(name: "Mine", position: 4, chatModel: model, visionModel: chat, embedModel: "bge-m3")
    }

    /// The interpreter over a new environment, `env` when given, its model calls answered by `handler` and a failure
    /// asked again after each of `retryDelays`.
    private func world(_ env: TestEnvironment? = nil, retryDelays: [Double] = [],
                       _ handler: @escaping MockOllama.ChatHandler) async throws -> World {
        let env = if let env { env } else { try await TestEnvironment.make() }
        let thinks = MockOllama.thinkingCapabilities
        let mock = MockOllama(installed: [Self.chat, Self.thinker, Self.switcher, Self.leveller, Self.nonThinker, "bge-m3"],
                              modelCapabilities: [Self.thinker: thinks, Self.switcher: thinks, Self.leveller: thinks, "bge-m3": ["embedding"]],
                              modelThinking: [Self.switcher: .switches, Self.leveller: .levels, Self.nonThinker: .never], handler: handler)
        let interpreter = SearchPromptInterpreter(gate: InferenceGate(api: mock, retryDelays: retryDelays, time: env.time),
                                                  models: ModelManager(api: mock, config: env.config.ollama), library: try PromptLibrary.bundled())
        return World(env: env, mock: mock, interpreter: interpreter)
    }

    static func usage(_ kind: LabelKind, _ values: String...) -> [LabelUsage] {
        values.enumerated().map { LabelUsage(label: DocumentLabel(kind: kind, value: $1), documents: values.count - $0) }
    }

    @Test func theModelIsToldTheArchivesLabelsTodayAndTheRequestAndAnswersInTheSchema() async throws {
        let w = try await world { _ in Self.answer() }
        defer { w.env.cleanup() }
        let vocabulary: [LabelKind: [LabelUsage]] = [.sender: Self.usage(.sender, "EDP Comercial", "MEO"),
                                                     .reference: Self.usage(.reference, "invoice FT 2026/1")]
        let read = try await w.interpret(Self.request, vocabulary: vocabulary)
        #expect(read.plan == Self.edp2025 && read.model == Self.chat && read.problem == nil, "the answer is the plan")
        let request = try #require(await w.mock.chatRequests.first)
        let text = request.allText
        #expect(text.contains("- senders: EDP Comercial; MEO"), "the archive's senders are listed, the most used first")
        #expect(!text.contains("invoice FT 2026/1"), "a kind the effort's promptLabels does not list is not shown: references are each document's own")
        #expect(text.contains("## TODAY\n2026-07-05") && text.contains("## REQUEST\n" + Self.request),
                "with today's date and the request as written")
        let schema = JSON.string(try #require(request.format))
        #expect(schema.contains("\"group_by\"") && schema.contains("\"jurisdiction\"") && schema.contains("\"asked_as\""),
                "each label comes with the words that ask for it, and the arrangement is one of the kinds of label")
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
        #expect(step.status == .ok && step.output?.contains(TraceStep.exchangeKey) == true,
                "the reading is traced with its prompts and answer, which retention clears")
    }

    @Test func anEmptyArchiveIsNotDescribed() async throws {
        let w = try await world { _ in Self.answer() }
        defer { w.env.cleanup() }
        _ = try await w.interpret("invoices")
        #expect(await w.mock.chatRequests.first?.messages[1].content.hasPrefix("## TODAY") == true, "there is nothing to tell the model of")
    }

    @Test func anInvalidAnswerIsRepairedAndOneNeverRightGivesNoPlanWithTheReason() async throws {
        let repaired = try await world { request in request.messages.count > 2 ? Self.answer() : Self.answer(omitting: "words") }
        defer { repaired.env.cleanup() }
        #expect(try await repaired.interpret(Self.request).plan == Self.edp2025, "the second answer, after being told what was wrong")
        #expect(await repaired.mock.chatRequests.last?.messages.last?.content.contains("words is missing") == true, "the repair says what was missing")
        #expect(await repaired.sink.steps.first?.status == .warn, "and the trace shows it needed repairing")

        let never = try await world { _ in "not JSON" }
        defer { never.env.cleanup() }
        let read = try await never.interpret("EDP invoices")
        #expect(read.plan == nil && read.problem?.hasPrefix("the model gave no valid answer") == true,
                "without a valid answer there is no plan, and the task will say why rather than fail on an error")
    }

    // MARK: Effort and profile

    /// What reading `effort`'s request by `profile`, else by Settings', made of a model that never answers validly: the
    /// chat requests, what the task was left with, and the calls and input its trace recorded.
    private func requests(_ effort: TaskEffort, profile: ModelProfile? = nil) async throws
        -> (requests: [OllamaChatRequest], read: SearchInterpretation, calls: [ModelCall], input: JSONValue) {
        let w = try await world { _ in "not JSON" }
        defer { w.env.cleanup() }
        let read = try await w.interpret(Self.request, effort: effort, profile: profile)
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
        let input = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(step.input, "the step records its input").utf8))
        return (await w.mock.chatRequests, read, try step.exchange(), input)
    }

    @Test func eachEffortAsksTheProfilesModelAloneAsOftenAndAsLongAsItsPresetGives() async throws {
        let config = try PipelineConfig.bundledDefaults()
        for effort in TaskEffort.allCases {
            let preset = try config.tasks.preset(effort)
            let (requests, read, calls, input) = try await requests(effort)
            #expect(requests.map(\.model) == Array(repeating: Self.chat, count: preset.repairAttempts + 1),
                    "\(effort): the profile's chat model is asked, then again repairAttempts times with what was wrong, and no model after it")
            #expect(calls.map(\.reason) == [.primary] + Array(repeating: .repair, count: preset.repairAttempts),
                    "\(effort): the trace says which call read the request and which were sent back to repair it")
            #expect(requests.allSatisfy { $0.options["num_predict"] == .number(Double(preset.numPredict)) && $0.timeout == preset.timeout },
                    "\(effort): an answer may be as long, and take as long, as the effort allows")
            #expect(requests.allSatisfy { $0.options["num_ctx"] == .number(Double(config.analysis.numCtx)) && $0.keepAlive == config.ollama.keepAlive.chat },
                    "\(effort): with the context and keep-alive documents are read with, so the model they loaded is not loaded again")
            #expect(requests.allSatisfy { $0.think == nil }, "\(effort): a model that cannot think is not told whether to")
            #expect(calls.map(\.think) == requests.map(\.think), "\(effort): the trace records what each call was told about thinking")
            #expect(input["model"] == .string(Self.chat) && input["effort"] == .string(effort.rawValue) && input["think"] == preset.think.json,
                    "\(effort): the trace says with what effort the request was read, what it wanted the model told about thinking, and by which model: \(input)")
            #expect(read.plan == nil && read.problem != nil, "\(effort): without a valid answer the task says why")
        }
    }

    @Test func theRequestIsReadByTheChatModelOfTheProfileItIsGiven() async throws {
        let high = try #require(try PipelineConfig.bundledDefaults().tasks.efforts[.high])
        let mine = Self.profile(reading: Self.thinker)
        let (careful, _, _, input) = try await requests(.high, profile: mine)
        #expect(careful.map(\.model) == Array(repeating: Self.thinker, count: high.repairAttempts + 1),
                "the profile's chat model is asked, then again repairAttempts times, and neither its vision model nor Settings' in its place")
        #expect(input["model"] == .string(Self.thinker), "and the trace says which model read the request: \(input)")

        let w = try await world { _ in Self.answer() }
        defer { w.env.cleanup() }
        let read = try await w.interpret(Self.request, profile: mine)
        #expect(read.model == Self.thinker && read.plan == Self.edp2025, "the task records the model that read it")
    }

    /// The effort says how much a model thinks before it answers, and each model is told it as its `/api/show` allows
    /// (`OllamaShowResponse.think(sending:)`, https://docs.ollama.com/capabilities/thinking).
    @Test func aModelThatThinksIsToldHowMuchByTheEffort() async throws {
        let efforts = try PipelineConfig.bundledDefaults().tasks.efforts
        let told: [(model: String, sent: [TaskEffort: OllamaThink?], why: String)] = [
            (Self.switcher, [.low: false, .medium: true, .high: true], "a model switched on and off is off at low, and on alike at medium and high"),
            (Self.thinker, [.low: false, .medium: true, .high: true], "and so is one an older server says only that it can think"),
            (Self.leveller, [.low: nil, .medium: "medium", .high: "high"],
             "a model with levels is told the effort's level, and nothing at low: it lists no off, so it thinks at its own default"),
            (Self.nonThinker, [.low: nil, .medium: nil, .high: nil], "a model that cannot think is told nothing at any effort"),
        ]
        for (model, sent, why) in told {
            for effort in TaskEffort.allCases {
                let wanted = try #require(efforts[effort]?.think)
                let expected = try #require(sent[effort], "the table says what \(model) is sent at \(effort)")
                let (requests, _, calls, input) = try await requests(effort, profile: Self.profile(reading: model))
                #expect(!requests.isEmpty && requests.allSatisfy { $0.model == model && $0.think == expected }, "\(model) at \(effort): \(why)")
                #expect(calls.map(\.think) == requests.map(\.think), "\(model) at \(effort): the trace's exchange keeps what each call was sent")
                #expect(input["think"] == wanted.json,
                        "\(model) at \(effort): and its input what the effort wanted, which stays when retention clears the exchange: \(input)")
            }
        }
    }

    @Test func anAnswerCutOffAtItsLengthLimitGoesBackSayingSo() async throws {
        let high = try #require(try PipelineConfig.bundledDefaults().tasks.efforts[.high])
        let w = try await world { request in request.messages.count > 2 ? Self.answer() : MockOllama.cutOff }
        defer { w.env.cleanup() }
        let read = try await w.interpret(Self.request, effort: .high, profile: Self.profile(reading: Self.thinker))
        #expect(read.plan == Self.edp2025, "the next answer, written more briefly, is read")
        let said = "The answer was cut off at its length limit of \(high.numPredict) tokens before it was complete; answer more briefly"
        #expect(await w.mock.chatRequests.last?.messages.last?.content.contains(said) == true,
                "the model is told it ran out of room, not that its empty answer is no JSON")
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
        #expect(step.status == .warn && step.output?.contains("cut off at its length limit") == true, "and so does the trace")
    }

    @Test func aProfileWhoseChatModelIsNotInstalledFailsTheTaskUnread() async throws {
        let w = try await world { _ in Self.answer() }
        defer { w.env.cleanup() }
        await #expect(throws: OllamaError.modelNotFound("llama-9:1t"), "no other model reads it in its place unasked, and the task says which it needs") {
            try await w.interpret(Self.request, profile: Self.profile(reading: "llama-9:1t"))
        }
        #expect(await w.mock.chatRequests.isEmpty, "no model was asked: asked what the model can do, Ollama said it does not have it")
    }

    @Test func aModelWhoseCapabilitiesCannotBeReadIsToldNothingOfThinkingUnlessOllamaIsAway() async throws {
        let w = try await world { _ in Self.answer() }
        defer { w.env.cleanup() }
        let mine = Self.profile(reading: Self.thinker)
        await w.mock.failShowing(Self.thinker, with: .http(status: 400, body: "unexpected"))
        let read = try await w.interpret(Self.request, effort: .high, profile: mine)
        let asked = await w.mock.chatRequests
        #expect(read.plan == Self.edp2025 && asked.map(\.model) == [Self.thinker] && asked.map(\.think) == [nil],
                "a model Ollama cannot say what it can do of still reads the request, told nothing about thinking, as it allows")
        await w.mock.failShowing(Self.thinker, with: .unreachable("connection refused"))
        await #expect(throws: OllamaError.unreachable("connection refused"), "a server that cannot be reached is an error, so the task waits") {
            try await w.interpret(Self.request, effort: .high, profile: mine)
        }
        #expect(await w.mock.chatRequests.count == 1, "and no model was asked while it was away")
    }

    @Test func eachEffortShowsTheModelAsMuchOfTheArchivesVocabularyAsItsPresetSays() async throws {
        let efforts = try PipelineConfig.bundledDefaults().tasks.efforts
        let most = try efforts.values.map { try #require($0.promptLabels[.sender]) }.max() ?? 0
        let senders = (1...most + 1).map { "Sender \($0)" }
        let vocabulary: [LabelKind: [LabelUsage]] = [.sender: senders.enumerated().map {
            LabelUsage(label: DocumentLabel(kind: .sender, value: $1), documents: senders.count - $0)
        }]
        for effort in TaskEffort.allCases {
            let w = try await world { _ in Self.answer() }
            defer { w.env.cleanup() }
            _ = try await w.interpret(Self.request, effort: effort, vocabulary: vocabulary)
            let limit = try #require(efforts[effort]?.promptLabels[.sender])
            let shown = try #require(await w.mock.chatRequests.first?.messages.last?.content
                .split(separator: "\n").first { $0.hasPrefix("- senders: ") }, "the request tells the model the archive's senders")
            #expect(shown == "- senders: " + senders.prefix(limit).joined(separator: "; "),
                    "\(effort): the \(limit) most used senders, no more")
        }
    }

    @Test func documentsAreStillReadWithoutThinking() async throws {
        let config = try PipelineConfig.bundledDefaults()
        let effort = LLMClassifier.Effort.documents(config)
        #expect(effort.think == config.analysis.think && effort.think == false && effort.timeout == nil
                    && effort.repairAttempts == config.analysis.repairAttempts && effort.options == config.analysis.llmOptions,
                "documents are read as before: analysis.think off, the chat timeout of ollama.timeouts, analysis's tries and options")
        #expect(effort.numCtx == config.analysis.numCtx && effort.keepAlive == config.ollama.keepAlive.chat,
                "with the context images are described with, and kept loaded as long as the chat keep-alive says")
    }

    /// What a model that thinks too long does: Ollama gives up on the request at its effort's `timeout`.
    static let tooLong = OllamaError.timeout("/api/chat")

    @Test func anAnswerThatTakesLongerThanItsEffortAllowsIsAFailedAnswerAskedOnce() async throws {
        let config = try PipelineConfig.bundledDefaults()
        let seconds = try config.tasks.preset(.medium).timeout
        #expect(seconds > 0, "an effort gives an answer a time of its own")
        let w = try await world(retryDelays: config.ollama.retryDelays) { request in
            if request.model == Self.thinker { throw Self.tooLong }
            return Self.answer()
        }
        defer { w.env.cleanup() }
        let read = try await w.interpret(Self.request, effort: .medium, profile: Self.profile(reading: Self.thinker))
        let said = AnswerValidationError.timedOut(seconds).localizedDescription
        #expect(read.plan == nil && read.problem?.hasPrefix("the model gave no valid answer") == true && read.problem?.contains(said) == true,
                "the task fails saying the answer took longer than its effort allows, so it can be asked again with less: \(read.problem ?? "")")
        #expect(await w.mock.chatRequests.map(\.model) == [Self.thinker],
                "asked once: not again after ollama.retryDelays, which would hold the model as long again each time, nor sent back, with no answer to repair")
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret }, "the reading is traced")
        let calls = try step.exchange()
        #expect(step.status == .error && calls.map(\.error) == [said] && calls.map(\.response) == [nil],
                "with the call that timed out and why, and no answer")
    }

    @Test func aTaskWhoseAnswerTakesLongerThanItsEffortAllowsFailsRatherThanWaits() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let w = try await world(h.env, retryDelays: h.env.config.ollama.retryDelays) { _ in throw Self.tooLong }
        let (queue, tasks) = h.searchTasks(w.interpreter)
        let asked = try await tasks.create(prompt: Self.request, effort: .high)
        await queue.drain()
        let task = try #require(try await tasks.store.task(id: asked.id))
        let seconds = try h.env.config.tasks.preset(.high).timeout
        #expect(task.state == .failed && task.problem?.contains(AnswerValidationError.timedOut(seconds).localizedDescription) == true,
                "the task fails saying why, rather than going back into the queue to take as long again: \(task.state) \(task.problem ?? "")")
        let traced = try #require(task.lastTrace, "the reading is traced")
        let trace = try #require(try await h.services.traces.trace(id: traced))
        #expect(trace.0.outcome == SearchTaskState.failed.rawValue && trace.1.map(\.stage) == [TraceStage.interpret.rawValue],
                "and its trace has the reading that failed")
        #expect(try await h.services.history.events(limit: 10, kinds: [.taskFailed]).count == 1, "and History says it failed")
        #expect(await w.mock.chatCount == 1, "the model was asked once")
    }

    @Test func aServerThatCannotBeReachedIsAnErrorSoTheTaskWaits() async throws {
        let w = try await world { _ in throw OllamaError.unreachable("connection refused") }
        defer { w.env.cleanup() }
        await #expect(throws: OllamaError.self, "the queue keeps the task and asks again later") { try await w.interpret("EDP invoices") }
    }
}
