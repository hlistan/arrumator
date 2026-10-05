@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// The model answers a question about a task's documents from what it is shown of them (docs/how-it-works.md#talking-with-a-tasks-documents):
/// the documents with their text under their numbers, those listed by name, the conversation so far, the day and the
/// question, in a fixed schema whose answer is checked against what was shown, streamed as it is written, and kept as
/// far as it came when it is cut off.
@Suite struct TaskAnswererTests {
    static let chat = ClassifyHarness.chatModel
    static let thinker = "qwen3.5:9b"
    static let question = "Qual é o total das faturas?"

    /// Two documents shown with their text, one listed by name, and two more not shown at all.
    static let context = TaskContext(
        documents: [
            ContextDocument(id: 42, name: "EDP 2025-03.pdf", date: "2025-03-05",
                            labels: [DocumentLabel(kind: .sender, value: "EDP Comercial"), DocumentLabel(kind: .type, value: "invoice"),
                                     DocumentLabel(kind: .date, value: "2025-03-05"), DocumentLabel(kind: .tag, value: "Taxes 2024")],
                            text: "Fatura EDP, total 54,21 EUR"),
            ContextDocument(id: 7, name: "Águas 2025-05.pdf", date: nil, labels: [], text: "Fatura da água, total 18,40 EUR"),
            ContextDocument(id: 9, name: "MEO 2025-01.pdf", date: "2025-01-20", labels: [DocumentLabel(kind: .type, value: "invoice")], text: nil),
        ],
        unlisted: 2,
        conversation: [Exchange(question: "Quantas faturas há?", answer: "Duas.")])

    static func answer(_ text: String = "Somam **72,61 EUR**.", sources: [String] = ["42", "[7]"], find: String = "") throws -> String {
        try JSON.string(JSONValue.orderedObject([JSONEntry("answer", .string(text)), JSONEntry("sources", .array(sources.map(JSONValue.string))),
                                             JSONEntry("find", .string(find))]))
    }

    private struct World {
        let env: TestEnvironment
        let mock: MockOllama
        let answerer: TaskAnswerer
        let sink = MemoryTraceSink()

        /// Answers `question` from `context` by `profile`, else by the one Settings uses; what the answer was as it was
        /// written, too.
        func answer(_ question: String = TaskAnswererTests.question, context: TaskContext = TaskAnswererTests.context,
                    effort: TaskEffort = .medium, profile: ModelProfile? = nil,
                    config: PipelineConfig? = nil) async throws -> (TaskAnswer, [AnswerProgress]) {
            let profile = if let profile { profile } else { try await env.settings.current.modelProfile() }
            let written = Written()
            let answer = try await answerer.answer(question, context: context, effort: effort, profile: profile, today: Self.today,
                                                   config: config ?? env.config, trace: TraceContext(traceID: 1, sink: sink)) { await written.add($0) }
            return (answer, await written.all)
        }

        func step() async throws -> TraceStep { try #require(await sink.steps.first { $0.stage == .answer }) }

        static let today = "2026-07-05"

        /// The configuration with a context that holds `chars` characters of a prompt at medium effort, a character a token.
        func holding(_ chars: Int) throws -> PipelineConfig {
            var config = env.config
            config.ollama.charsPerToken = 1
            config.conversation.numCtx = try config.conversation.effort(.medium).numPredict + chars
            return config
        }

        /// How many characters the prompt of `question` about `context` holds, system and user together.
        func promptSize(_ question: String = TaskAnswererTests.question, context: TaskContext = TaskAnswererTests.context) throws -> Int {
            try answerer.library.render("conversation-system", [:]).count
                + answerer.userPrompt(question, context: context, today: Self.today,
                                      language: LanguageDetector(config: env.config.extraction).name(of: question)).count
        }
    }

    actor Written {
        private(set) var all: [AnswerProgress] = []
        func add(_ progress: AnswerProgress) { all.append(progress) }
    }

    private func world(retryDelays: [Double] = [], _ handler: @escaping MockOllama.ChatHandler) async throws -> World {
        let env = try await TestEnvironment.make()
        let mock = MockOllama(installed: [Self.chat, Self.thinker, "bge-m3"],
                              modelCapabilities: [Self.thinker: MockOllama.thinkingCapabilities, "bge-m3": ["embedding"]], handler: handler)
        let answerer = TaskAnswerer(gate: InferenceGate(api: mock, retryDelays: retryDelays, time: env.time),
                                    models: ModelManager(api: mock, config: env.config.ollama), library: try PromptLibrary.bundled())
        return World(env: env, mock: mock, answerer: answerer)
    }

    // MARK: The model's context

    @Test func whatAnAnswerIsShownIsCutToFitTheContextTheLeastNeededFirstAndTheTraceSaysSo() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        let full = try w.promptSize()
        _ = try await w.answer(config: try w.holding(full - 1))
        let request = try #require(await w.mock.chatRequests.first)
        #expect(request.messages[0].content == (try w.answerer.library.render("conversation-system", [:])),
                "the app's own instructions are sent whole, never the start Ollama would drop from a prompt too long")
        let user = request.messages[1].content
        #expect(user.count + request.messages[0].content.count <= full - 1, "the prompt fits the context beside the answer")
        #expect(!user.contains("Fatura da água") && user.contains("[7] Águas 2025-05.pdf") && user.contains("Fatura EDP"),
                "the last document shown with its text is listed by name instead, the one the question concerns most keeping its text")
        let input = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(try await w.step().input).utf8))
        #expect(input["trimmed"]?["textsLeftOut"] == .number(1) && input["read"] == .number(1),
                "the trace says what was left out so it fit: \(input)")

        await #expect(throws: PromptError.tooLong(template: "conversation-user", chars: try w.promptSize(context: TaskContext(documents: [], unlisted: 0, conversation: [])),
                                                  room: 10),
                      "a question that does not fit even alone fails, saying so, rather than losing the start of its prompt") {
            _ = try await w.answer(config: try w.holding(10))
        }
    }

    @Test func theTraceKeepsTheTokensEachPromptTookAndSaysWhenTheContextWasFull() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        _ = try await w.answer()
        var step = try await w.step()
        var output = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(step.output).utf8))
        #expect(output["promptTokens"] == .array([.number(10)]) && step.status == .ok && step.error == nil,
                "how many tokens Ollama counted the prompt took is kept, which retention does not clear")
        var config = w.env.config
        // Ollama counts 10 tokens of a context that holds 10 beside the answer, though the estimate let the prompt in; the
        // prompt is not fitted again here (`ollama.refitAttempts`), which the test after this one looks at.
        config.ollama.charsPerToken = 100_000
        config.ollama.refitAttempts = 0
        config.conversation.numCtx = try config.conversation.effort(.medium).numPredict + 10
        let full = try await world { _ in try Self.answer() }
        defer { full.env.cleanup() }
        _ = try await full.answer(config: config)
        step = try await full.step()
        output = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(step.output).utf8))
        #expect(step.status == .warn && step.error?.contains("the model's context was full") == true && output["promptTokens"] == .array([.number(10)]),
                "a prompt that took all the room says so, as the estimate of characters a token was wrong for it")
        let answered = try await full.answer(config: config).0
        #expect(answered.problem == PromptBudget.contextFullProblem, "and so does the answer, which may not have read all it was shown")
    }

    /// Text in other scripts, or many, holds fewer characters a token than `ollama.charsPerToken` reckons: a prompt Ollama
    /// counts filling the context is fitted again at what it counted, and asked again, rather than answered from a prompt
    /// the model did not read whole (QA 2026-10-04, CNV-5).
    @Test func aPromptOllamaCountsFillingTheContextIsFittedAgainAtWhatItCountedAndAskedAgain() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        // A character a token, a third of what the estimate reckons.
        await w.mock.countPromptTokens { request in request.messages.reduce(0) { $0 + $1.content.count } }
        var config = w.env.config
        config.conversation.numCtx = try config.conversation.effort(.medium).numPredict + w.promptSize() - 1
        let (answer, _) = try await w.answer(config: config)
        let requests = await w.mock.chatRequests
        #expect(requests.count == 2 && requests[0].messages[1].content.contains("Fatura da água")
                    && !requests[1].messages[1].content.contains("Fatura da água") && requests[1].messages[1].content.contains("Fatura EDP"),
                "asked again with the last document shown by its text listed by name, as the prompt fits at a character a token")
        #expect(answer.problem == nil && answer.text == "Somam **72,61 EUR**.", "the answer to the prompt that fit is no less for it")
        let step = try await w.step()
        let input = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(step.input).utf8))
        #expect(input["refitted"] == .array([.number(1)]) && input["trimmed"]?["textsLeftOut"] == .number(1),
                "the trace keeps the characters a token it was fitted at, and what that left out: \(input)")
        let calls = try step.exchange()
        #expect(step.status == .warn && step.error?.contains("fitted again 1 time") == true && calls.count == 2,
                "and says so, with both calls: \(step.error ?? "")")
    }

    @Test func whatIsLeftOutFirstIsTheEarlierConversationThenTextsThenTheLatestExchangeThenNames() throws {
        var context = Self.context
        context.conversation = [Exchange(question: "First?", answer: "One."), Exchange(question: "Then?", answer: "Two.")]
        var trim = ContextTrim()
        var shown: [TaskContext] = []
        var current = context
        while let less = trim.less(of: current) {
            shown.append(less)
            current = less
        }
        #expect(shown.map(\.conversation.count) == [1, 1, 1, 0, 0, 0, 0], "the exchanges before the latest go first, the latest after the texts")
        #expect(shown.map(\.read.count) == [2, 1, 0, 0, 0, 0, 0], "the texts from the last shown, the one the question concerns most last")
        #expect(shown.map(\.documents.count) == [3, 3, 3, 3, 2, 1, 0] && current.unlisted == Self.context.unlisted + 3,
                "and the names last, each counted among those not shown")
        #expect(trim == ContextTrim(textsLeftOut: 2, exchangesLeftOut: 2, namesLeftOut: 3), "the trace says how much of each")
    }

    // MARK: Ollama away

    @Test func aServerThatIsAwayIsLeftToTheQueueRatherThanAskedAgainMeanwhile() async throws {
        let asked = Mutex(0)
        let w = try await world(retryDelays: [2, 8, 30]) { _ in
            asked.withLock { $0 += 1 }
            throw OllamaError.unreachable("down")
        }
        defer { w.env.cleanup() }
        await #expect(throws: OllamaError.unreachable("down"), "the question waits in its queue, which says so and when it tries again") {
            _ = try await w.answer()
        }
        #expect(asked.withLock { $0 } == 1, "asked once: retrying here would show the question as answered while nothing answers it")
    }

    @Test func aModelThatThinksIsSaidToThinkUntilItsAnswerBeginsAndItsThoughtsAreNoAnswer() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        let thoughts = "Somo as duas faturas."
        await w.mock.think(thoughts)
        let (answer, written) = try await w.answer()
        let thinking = written.prefix { $0.thinking }
        #expect(thinking.count >= MockOllama.words(thoughts).count && thinking.allSatisfy { $0.text.isEmpty && $0.begun },
                "while the model thinks, the question says so, as the model at work, and nothing of its thoughts is the answer: \(written)")
        #expect(written.dropFirst(thinking.count).allSatisfy { !$0.thinking } && written.last?.text == answer.text,
                "then the answer is given as it is written")
        #expect(answer.text == "Somam **72,61 EUR**.", "and it holds none of the thoughts")
    }

    @Test func whatIsWrittenSaysTheModelHasBegun() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        let (_, written) = try await w.answer()
        #expect(!written.isEmpty && written.allSatisfy(\.begun), "every word streamed is the model at work, not still waiting for it")
    }

    // MARK: Checking an answer

    @Test func anAnswerNamesDocumentsWhereTheModelWroteTheirNumbers() throws {
        let validator = ConversationAnswerValidator(names: [42: "EDP 2025-03.pdf", 7: "Águas 2025-05.pdf"])
        let written = "Somam **[42] EDP 2025-03.pdf** e [7], segundo [ 42 ]; o [99] não foi mostrado."
        let checked = try validator.validate(Self.answer(written, sources: ["42"]))
        #expect(checked.text == "Somam **EDP 2025-03.pdf** e Águas 2025-05.pdf, segundo EDP 2025-03.pdf; o [99] não foi mostrado.",
                "the person never sees the numbers: one before its document's name goes, one alone becomes the name, one never shown stays")
    }

    @Test func aNumberInBracketsThatIsMarkdownOfItsOwnIsLeftAsWritten() throws {
        let validator = ConversationAnswerValidator(names: [42: "EDP 2025-03.pdf", 7: "Águas 2025-05.pdf"])
        let written = "Ver [42](https://x.example/42), a nota [7]: total, `lista[7]` e\n\n```\nitens[42]\n```\n\nmas [42] sim."
        let checked = try validator.validate(try Self.answer(written, sources: ["42"]))
        #expect(checked.text == "Ver [42](https://x.example/42), a nota [7]: total, `lista[7]` e\n\n```\nitens[42]\n```\n\nmas EDP 2025-03.pdf sim.",
                "a link's words, a reference and code keep their numbers; a number standing for a document is its name")
    }

    @Test func anAnswerKeepsOnlyTheSourcesItWasShownAndItsRequestForMoreOnOneLine() throws {
        let validator = ConversationAnswerValidator(shown: [42, 7])
        let checked = try validator.validate("<think>sum them</think>" + Self.answer(sources: ["42", "[7]", "#42", "99", "the bill"],
                                                                                     find: "  the EDP contract\nand its amendments "))
        #expect(checked.text == "Somam **72,61 EUR**." && checked.sources == [42, 7],
                "a document shown is a source however its number is written, once; one not shown, or no number, is not")
        #expect(checked.notes == ["sources: “99” is no document the answer was shown, dropped",
                                  "sources: “the bill” is no document the answer was shown, dropped"], "what is dropped is noted for the trace")
        #expect(checked.find == "the EDP contract and its amendments" && checked.incomplete == nil, "the request for more is on one line")
        #expect(try validator.validate(Self.answer(find: " ")).find == nil, "an empty request asks for nothing more")
    }

    @Test func anAnswerWithoutTextOrAListOrThatIsNoJSONGoesBack() {
        let validator = ConversationAnswerValidator(shown: [42])
        #expect(throws: AnswerValidationError.invalid(["answer is empty"]), "an answer needs words") {
            try validator.validate(Self.answer(" \n "))
        }
        #expect(throws: AnswerValidationError.invalid(["sources is missing; give \"\" or [] when there is nothing to give"]),
                "and every list") { try validator.validate(#"{"answer": "Yes", "find": ""}"#) }
        #expect("and to be JSON") { try validator.validate("Yes, they do.") } throws: { error in
            if case .notJSON = error as? AnswerValidationError { true } else { false }
        }
    }

    /// An answer that only begins one, a heading and a rule, or a sentence announcing what follows and nothing after it,
    /// is no answer: it goes back to the model, told so by its Markdown alone, in any language (QA 2026-10-04, CNV-5).
    @Test func anAnswerThatOnlyAnnouncesWhatFollowsGoesBack() throws {
        let validator = ConversationAnswerValidator(shown: [42])
        let headings = AnswerValidationError.invalid(["answer holds only headings or rules: give the answer itself, in full"])
        let announces = AnswerValidationError.invalid(["answer announces what follows and ends there: give what it announces, in full"])
        #expect(throws: headings, "a title in bold and a rule, as the model answered every time") {
            try validator.validate(Self.answer("**Detailed Breakdown of Each Electricity Bill**\n\n---", sources: ["42"]))
        }
        #expect(throws: headings, "headings alone") { try validator.validate(Self.answer("# Resumo\n\n## Faturas\n\n***")) }
        #expect(try validator.validate(Self.answer("**72,61 EUR**")).text == "**72,61 EUR**", "an answer in bold, with no rule after it, is an answer")
        #expect(throws: announces, "a sentence ending with a colon") {
            try validator.validate(Self.answer("Here are the full translations of every document in the provided set into English:"))
        }
        #expect(throws: announces, "after a heading, in another script") { try validator.validate(Self.answer("## 翻译\n\n以下是全部译文：")) }
        let whole = try validator.validate(Self.answer("Os totais:\n\n- EDP: 54,21 EUR\n- Águas: 18,40 EUR\n\nTotal: **72,61 EUR**."))
        #expect(whole.text.hasSuffix("**72,61 EUR**."), "a colon that introduces what follows it is no announcement")
        #expect(try validator.validate(Self.answer("Ver o código:\n\n```\nU-2653\n```")).text.hasSuffix("```"),
                "nor one followed by code")
    }

    /// An answer that gives something and ends with a colon, as a document's own field or a total does, or a heading that
    /// carries a figure, is an answer: only one that is nothing but a lead-in, or headings and rules with no figure, goes
    /// back (review of 2026-10-04, finding 13).
    @Test func anAnswerThatEndsWithAColonOrIsAFigureInAHeadingIsAnAnswer() throws {
        let validator = ConversationAnswerValidator(shown: [42])
        for answer in [
            "A declaração foi traduzida por inteiro.\n\nNome: Maria Exemplo\n\nAssinatura:",
            "电费 54,21 EUR，水费 18,40 EUR。\n\n合计：",
            "# 340 € in total",
            "**72,61 EUR**\n\n---",
            "Os totais:\n\n- EDP: 54,21 EUR\n- Águas:",
        ] {
            #expect(try validator.validate(Self.answer(answer)).text == answer, "“\(answer)” gives what was asked")
        }
        #expect(throws: AnswerValidationError.invalid(["answer announces what follows and ends there: give what it announces, in full"]),
                "the stub of QA 2026-10-04 as the model wrote it") {
            try validator.validate(Self.answer("Here are the full translations of every document in the provided set into English, in the order "
                + "they appear, preserving all names, numbers, and details:"))
        }
    }

    @Test func theAnswerIsReadAsItStreamsItsEscapesDecoded() {
        let whole = #"{"answer": "Linha 1\nLinha \"2\" é é 😀\\", "sources": []}"#
        #expect(StreamedAnswer.text(in: whole) == "Linha 1\nLinha \"2\" é é 😀\\", "the field as written, escapes decoded, up to its end")
        #expect(StreamedAnswer.text(in: #"{"answer": "Linha 1\nLin"#) == "Linha 1\nLin", "what has come of it before it ends")
        #expect(StreamedAnswer.text(in: #"{"answer": "Caf\u00"#) == "Caf", "an escape not complete yet waits for the rest")
        #expect(StreamedAnswer.text(in: #"{"answer": "Fim\"#) == "Fim", "and so does a backslash at the end")
        #expect(StreamedAnswer.text(in: #"{"ans"#).isEmpty && StreamedAnswer.text(in: #"{"answer": "#).isEmpty, "nothing before the field begins")
        #expect(StreamedAnswer.text(in: #"<think>{"answer": "no"#).isEmpty, "nor while the model thinks aloud")
        #expect(StreamedAnswer.text(in: #"<think>"answer": "no"</think>{"answer": "yes"#) == "yes", "and after, only what it answers")
    }

    // MARK: Asking the model

    @Test func theModelIsShownTheDocumentsTheConversationTodayAndTheQuestionAndAnswersInTheSchema() async throws {
        let w = try await world { _ in try Self.answer(find: "o contrato da EDP") }
        defer { w.env.cleanup() }
        let (answer, written) = try await w.answer()
        #expect(answer == TaskAnswer(text: "Somam **72,61 EUR**.", sources: [42, 7], find: "o contrato da EDP", model: Self.chat, problem: nil),
                "the checked answer, by the model of the profile")
        let request = try #require(await w.mock.chatRequests.first)
        let user = try #require(request.messages.last?.content)
        #expect(request.model == Self.chat && request.messages.first?.content.hasPrefix("You are Arrumator") == true,
                "the profile's chat model is asked with the app's prompt")
        #expect(user.contains(#"### [42] EDP 2025-03.pdf"# + "\n" + #"sender: "EDP Comercial"; type: "invoice"; date: "2025-03-05""# + "\n\nFatura EDP, total 54,21 EUR")
                    && user.contains("### [7] Águas 2025-05.pdf\n-\n\nFatura da água"),
                "each document shown with its text under its number, with its labels: \(user)")
        #expect(user.contains(#"- [9] MEO 2025-01.pdf · type: "invoice""#) && user.contains("2 more documents"),
                "the others listed by name, and how many are not shown")
        #expect(!user.contains("Taxes 2024"), "never the user's own tags: the model is shown only the kinds it gives")
        #expect(user.contains("The person asked: Quantas faturas há?\nYou answered: Duas.") && user.contains("## TODAY\n2026-07-05")
                    && user.contains("## QUESTION\n\(Self.question)\n\n") && user.hasSuffix("Return the JSON object now."),
                "the conversation so far, the day and the question")
        #expect(user.contains("## DOCUMENTS\nDocuments in the set: 5,"),
                "and how many documents the set holds, those not shown too, so an answer about them all counts every one")
        let config = w.env.config
        let preset = try config.conversation.effort(.medium)
        #expect(request.format == ConversationSchema.answer && request.timeout == preset.timeout, "in the schema, as long as the effort allows")
        #expect(request.options["num_ctx"] == .number(Double(config.conversation.numCtx))
                    && request.options["num_predict"] == .number(Double(preset.numPredict))
                    && request.options["temperature"] == .number(config.conversation.sampling.temperature),
                "in the conversation's context, with the effort's length, sampled as writing is")
        #expect(written.map(\.text).last == answer.text && written.count > 1 && written.allSatisfy { !$0.thinking },
                "the answer is given as it is written, word by word")
        let step = try await w.step()
        #expect(step.status == .ok && step.input?.contains("\"read\":2") == true && step.input?.contains("\"unlisted\":2") == true
                    && step.output?.contains(TraceStep.exchangeKey) == true,
                "the answer is traced with what it was shown and the exchange")
    }

    /// An answer is written in the question's language, which the model is told, as the conversation before it may be in
    /// another (QA 2026-10-04, CNV-3).
    @Test func theModelIsToldTheLanguageTheQuestionIsWrittenIn() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        _ = try await w.answer("What does the dentist booking confirmation say?")
        let user = try #require(await w.mock.chatRequests.first?.messages.last?.content)
        #expect(user.contains("The question is written in English: answer in English"), "\(user)")
        let input = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(try await w.step().input).utf8))
        #expect(input["language"] == .string("English"), "and the trace says what it was told: \(input)")
        _ = try await w.answer("2025?")
        let unknown = try #require(await w.mock.chatRequests.last?.messages.last?.content)
        #expect(!unknown.contains("is written in"), "a question without words says nothing of a language")
    }

    @Test func anEmptySetIsSaidToBeEmpty() async throws {
        let w = try await world { _ in try Self.answer(sources: []) }
        defer { w.env.cleanup() }
        _ = try await w.answer(context: TaskContext(documents: [], unlisted: 0, conversation: []))
        let user = try #require(await w.mock.chatRequests.first?.messages.last?.content)
        #expect(user.contains("## DOCUMENTS\nThe set holds no documents.") && !user.contains("CONVERSATION SO FAR"),
                "the model is told there is nothing to draw on, and no conversation before")
    }

    @Test func eachEffortTellsAModelThatThinksHowMuchToAndOneThatCannotNothing() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        let mine = ModelProfile(name: "Mine", position: 4, chatModel: Self.thinker, visionModel: Self.chat, embedModel: "bge-m3")
        for effort in TaskEffort.allCases { _ = try await w.answer(effort: effort, profile: mine) }
        _ = try await w.answer(effort: .high)
        let requests = await w.mock.chatRequests
        #expect(requests.prefix(3).map(\.think) == [.off, .on, .on] && requests.prefix(3).allSatisfy { $0.model == Self.thinker },
                "a model that thinks does not at low, and does at medium and high")
        #expect(requests.last?.think == nil, "a model that cannot think is told nothing")
    }

    @Test func anAnswerCutOffIsKeptAsFarAsItCameSayingSoAndNoneIsNoAnswer() async throws {
        let w = try await world { _ in MockOllama.cutOff(after: #"{"answer": "Tradução: a fatura [42] da EDP so"#) }
        defer { w.env.cleanup() }
        let (answer, _) = try await w.answer()
        let preset = try w.env.config.conversation.effort(.medium)
        #expect(answer.text == "Tradução: a fatura EDP 2025-03.pdf da EDP so" && answer.sources.isEmpty && answer.find == nil,
                "what came of the answer is kept, a document it names by number named as a whole answer's is")
        #expect(answer.problem == AnswerValidationError.cutOff(preset.numPredict).localizedDescription, "saying it was cut off")
        #expect(await w.mock.chatCount == 1, "and it is not asked for again, as the same would be cut off again")
        #expect(try await w.step().status == .warn, "the trace marks it")

        let nothing = try await world { _ in MockOllama.cutOff }
        defer { nothing.env.cleanup() }
        await #expect("a model that thought until it ran out wrote no answer") { try await nothing.answer() } throws: { error in
            if case .exhausted = error as? ModelAnswerError { true } else { false }
        }
    }

    @Test func anAnswerThatCannotBeReadGoesBackOnceAndAModelThatIsMissingThrows() async throws {
        let w = try await world { request in request.messages.count > 2 ? try Self.answer() : "Somam 72,61 EUR." }
        defer { w.env.cleanup() }
        let (answer, written) = try await w.answer()
        let requests = await w.mock.chatRequests
        #expect(answer.text == "Somam **72,61 EUR**." && requests.count == 2, "an answer that is no JSON goes back with what was wrong")
        #expect(requests.last?.messages.last?.content.hasPrefix("Your previous answer was not valid") == true, "with the repair prompt")
        #expect(written.last?.text == answer.text, "and the answer as written starts again")

        let never = try await world { _ in "never JSON" }
        defer { never.env.cleanup() }
        await #expect("an answer never valid is no answer") { try await never.answer() } throws: { error in
            if case .exhausted = error as? ModelAnswerError { true } else { false }
        }
        #expect(try await never.step().status == .error, "and is traced as such")

        let missing = ModelProfile(name: "Gone", position: 4, chatModel: "absent:1b", visionModel: Self.chat, embedModel: "bge-m3")
        await #expect(throws: OllamaError.modelNotFound("absent:1b"), "a model Ollama does not have is thrown, so the question fails naming it") {
            try await w.answer(profile: missing)
        }
    }
}
