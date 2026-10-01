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
        for kind in LabelKind.allCases { fields[ClassificationSchema.labelsKey(kind)] = .array([]) }
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

        func interpret(_ prompt: String, effort: TaskEffort = .medium, model: String? = nil,
                       vocabulary: [LabelKind: [LabelUsage]] = [:]) async throws -> SearchInterpretation {
            try await interpreter.interpret(prompt, effort: effort, model: model, vocabulary: vocabulary, today: "2026-07-05",
                                            settings: await env.settings.current, config: env.config,
                                            trace: TraceContext(traceID: 1, sink: sink))
        }
    }

    /// The profile's chat model, and the other models the Ollama double has: a fast one, one of the user's that thinks,
    /// and one that only embeds.
    static let chat = "ministral-3:14b"
    static let fast = "ministral-3:8b"
    static let thinker = "qwen3.5:9b"

    private func world(fast: String? = nil, _ handler: @escaping MockOllama.ChatHandler) async throws -> World {
        let env = try await TestEnvironment.make()
        if let fast { try await env.settings.update { $0.models.fastModel = fast } }
        let mock = MockOllama(installed: [Self.chat, Self.fast, Self.thinker, "bge-m3"],
                              modelCapabilities: [Self.thinker: ["completion", "thinking"], "bge-m3": ["embedding"]], handler: handler)
        let interpreter = SearchPromptInterpreter(gate: InferenceGate(api: mock, retryDelays: [], time: env.time),
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

    // MARK: Effort and model

    /// The chat requests `effort` makes of a model that never answers validly, and what the task was left with.
    private func requests(_ effort: TaskEffort, model: String? = nil) async throws -> (requests: [OllamaChatRequest], read: SearchInterpretation) {
        let w = try await world(fast: Self.fast) { _ in "not JSON" }
        defer { w.env.cleanup() }
        let read = try await w.interpret(Self.request, effort: effort, model: model)
        return (await w.mock.chatRequests, read)
    }

    @Test func eachEffortReadsWithTheModelsTriesAndLengthItsPresetGives() async throws {
        let efforts = try PipelineConfig.bundledDefaults().tasks.efforts
        let low = try #require(efforts[.low]), medium = try #require(efforts[.medium]), high = try #require(efforts[.high])
        #expect(low.model == .fast && !low.fallback && medium.model == .chat && medium.fallback && high.think && !medium.think,
                "the presets these expectations follow from")
        for (effort, preset) in [(TaskEffort.low, low), (.medium, medium), (.high, high)] {
            let (requests, read) = try await requests(effort)
            let first = preset.model == .fast ? Self.fast : Self.chat
            let models = [first] + (preset.fallback ? [Self.chat, Self.fast].filter { $0 != first } : [])
            #expect(requests.map(\.model) == models.flatMap { Array(repeating: $0, count: preset.repairAttempts + 1) },
                    "\(effort): each model the effort reads with is asked once and again repairAttempts times, in order")
            #expect(requests.allSatisfy { $0.options["num_predict"] == .number(Double(preset.numPredict)) && $0.timeout == preset.timeout },
                    "\(effort): an answer may be as long, and take as long, as the effort allows")
            #expect(requests.allSatisfy { $0.think == nil }, "\(effort): a model that cannot think is not told whether to")
            #expect(read.plan == nil && read.problem != nil, "\(effort): without a valid answer the task says why")
        }
    }

    @Test func aModelTheUserGaveTheTaskReadsItFirstAndThinksAsTheEffortSays() async throws {
        let efforts = try PipelineConfig.bundledDefaults().tasks.efforts
        let high = try #require(efforts[.high]), low = try #require(efforts[.low])
        let careful = try await requests(.high, model: Self.thinker).requests
        #expect(careful.first?.model == Self.thinker && careful.count == (high.repairAttempts + 1) * 3,
                "the user's model first, then the profile's chat and fast models as the effort falls back")
        #expect(careful.filter { $0.model == Self.thinker }.allSatisfy { $0.think == true }, "high effort lets a model that can think do so")
        let quick = try await requests(.low, model: Self.thinker).requests
        #expect(quick.map(\.model) == Array(repeating: Self.thinker, count: low.repairAttempts + 1) && quick.allSatisfy { $0.think == false },
                "low effort asks only the user's model, and not to think")

        let w = try await world { _ in Self.answer() }
        defer { w.env.cleanup() }
        let read = try await w.interpret(Self.request, model: Self.thinker)
        #expect(read.model == Self.thinker && read.plan == Self.edp2025, "the task records the model that read it")
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
        #expect(step.input?.contains("\"effort\":\"medium\"") == true && step.input?.contains(Self.thinker) == true,
                "the trace says with what effort and by which models the request was read: \(step.input ?? "")")
    }

    @Test func anAnswerCutOffAtItsLengthLimitGoesBackSayingSo() async throws {
        let high = try #require(try PipelineConfig.bundledDefaults().tasks.efforts[.high])
        let w = try await world { request in request.messages.count > 2 ? Self.answer() : MockOllama.cutOff }
        defer { w.env.cleanup() }
        let read = try await w.interpret(Self.request, effort: .high, model: Self.thinker)
        #expect(read.plan == Self.edp2025, "the next answer, written more briefly, is read")
        let said = "The answer was cut off at its length limit of \(high.numPredict) tokens before it was complete; answer more briefly"
        #expect(await w.mock.chatRequests.last?.messages.last?.content.contains(said) == true,
                "the model is told it ran out of room, not that its empty answer is no JSON")
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
        #expect(step.status == .warn && step.output?.contains("cut off at its length limit") == true, "and so does the trace")
    }

    @Test func aModelTheUserGaveThatIsNotInstalledFailsTheTaskUnread() async throws {
        let w = try await world { _ in Self.answer() }
        defer { w.env.cleanup() }
        await #expect(throws: OllamaError.modelNotFound("llama-9:1t"), "the profile's model does not read it in its place unasked") {
            try await w.interpret(Self.request, model: "llama-9:1t")
        }
        #expect(await w.mock.chatRequests.isEmpty, "no model was asked")
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
        let effort = LLMClassifier.Effort.documents(config.analysis)
        #expect(effort.think == config.analysis.think && !effort.think && effort.timeout == nil
                    && effort.repairAttempts == config.analysis.repairAttempts && effort.options == config.analysis.llmOptions,
                "documents are read as before: analysis.think off, the chat timeout of ollama.timeouts, analysis's tries and options")
    }

    @Test func aServerThatCannotBeReachedIsAnErrorSoTheTaskWaits() async throws {
        let w = try await world { _ in throw OllamaError.unreachable("connection refused") }
        defer { w.env.cleanup() }
        await #expect(throws: OllamaError.self, "the queue keeps the task and asks again later") { try await w.interpret("EDP invoices") }
    }
}
