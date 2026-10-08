@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// The model judges two labels that look alike, one label written two ways or two (docs/how-it-works.md#keeping-labels-one-vocabulary):
/// shown each with how many documents have it and the names of some, it says why, then which, in a fixed schema whose
/// answer is checked by its structure.
@Suite struct LabelPairJudgeTests {
    static let pair = LabelSuggestion(kind: .party, value: "Mario Silva", into: "Maria Silva", similarity: 0.93, reason: .writtenAlike)
    static let use = LabelPairUse(valueDocuments: 1, valueNames: ["2026-03-02 Payslip March.pdf"],
                                  intoDocuments: 4, intoNames: ["2026-07-05 EDP - Fatura, julho.pdf", "2026-06-05 EDP - Fatura junho.pdf"])

    static func answer(_ answer: String, reason: String = "Two first names, Maria and Mario: two people.") throws -> String {
        try JSON.string(JSONValue.orderedObject([JSONEntry("reason", .string(reason)), JSONEntry("answer", .string(answer))]))
    }

    private struct World {
        let env: TestEnvironment
        let judge: LabelPairJudge
        let sink = MemoryTraceSink()

        static func make(_ handler: @escaping MockOllama.ChatHandler) async throws -> World {
            let env = try await TestEnvironment.make()
            let mock = MockOllama(installed: [ClassifyHarness.chatModel, "bge-m3"], handler: handler)
            let judge = LabelPairJudge(gate: InferenceGate(api: mock, retryDelays: [], time: env.time),
                                       models: ModelManager(api: mock, config: env.config.ollama), library: try PromptLibrary.bundled())
            return World(env: env, judge: judge)
        }

        func judge() async throws -> LabelVerdict {
            try await judge.judge(LabelPairJudgeTests.pair, use: LabelPairJudgeTests.use, profile: try await env.settings.current.modelProfile(),
                                  config: env.config, trace: TraceContext(traceID: 1, sink: sink))
        }

        func step() async throws -> TraceStep { try #require(await sink.steps.first { $0.stage == .judge }) }
    }

    // MARK: The answer

    @Test(arguments: [("same", LabelJudgement.same), ("different", .different), (" Different\n", .different), ("SAME", .same)])
    func eitherAnswerIsKeptHoweverItIsCasedOrSpaced(_ written: String, _ judgement: LabelJudgement) throws {
        let judged = try LabelPairValidator.validate(try Self.answer(written, reason: "  Two  people. "))
        #expect(judged == JudgedPair(judgement: judgement, reason: "Two people."), "“\(written)” is \(judgement), its reason on one line")
    }

    @Test func anAnswerOfNeitherOrWithoutAReasonGoesBackSayingWhatItMustBe() throws {
        #expect(throws: AnswerValidationError.invalid(["\"answer\" is “maybe”; it must be \"same\" or \"different\""]), "neither answer") {
            try LabelPairValidator.validate(try Self.answer("maybe"))
        }
        #expect(throws: AnswerValidationError.invalid(["\"reason\" is blank; say in one sentence what makes them one or tells them apart"]),
                "an answer without a reason") {
            try LabelPairValidator.validate(try Self.answer("same", reason: " \n "))
        }
        #expect(performing: { try LabelPairValidator.validate("{\"answer\": \"same\"}") }, throws: { error in
            if case AnswerValidationError.notJSON = error { true } else { false }
        })
        #expect(performing: { try LabelPairValidator.validate("same") }, throws: { error in
            if case AnswerValidationError.notJSON = error { true } else { false }
        })
    }

    @Test func theSchemaAsksForTheReasonFirstThenOneOfTheTwoAnswers() {
        let schema = LabelPairSchema.judgement.serialized()
        #expect(schema.range(of: "\"reason\"").map(\.lowerBound) ?? schema.endIndex < schema.range(of: "\"answer\"").map(\.lowerBound) ?? schema.startIndex,
                "the reason comes first, so the answer follows from it: \(schema)")
        #expect(schema.contains("\"enum\":[\"same\",\"different\"]"), "and the answer is one of the two: \(schema)")
    }

    // MARK: The prompt

    @Test func theModelIsShownEachLabelWithHowManyDocumentsHaveItAndTheNamesOfSome() async throws {
        let w = try await World.make { _ in "" }
        defer { w.env.cleanup() }
        let user = try w.judge.userPrompt(Self.pair, use: Self.use)
        #expect(user.contains("Kind: party"), "the kind: \(user)")
        #expect(user.contains("First label: \"Mario Silva\", on 1 document, such as: \"2026-03-02 Payslip March.pdf\""),
                "each label as a JSON string, with its documents: \(user)")
        #expect(user.contains("Second label: \"Maria Silva\", on 4 documents, such as: \"2026-07-05 EDP - Fatura, julho.pdf\", "
                + "\"2026-06-05 EDP - Fatura junho.pdf\""), "a name holding a comma reads as one: \(user)")
        let unnamed = try w.judge.userPrompt(Self.pair, use: LabelPairUse(valueDocuments: 2, valueNames: [], intoDocuments: 3, intoNames: []))
        #expect(unnamed.contains("First label: \"Mario Silva\", on 2 documents\n") && !unnamed.contains("such as"),
                "without names, only how many: \(unnamed)")
    }

    /// The examples the system prompt gives: each a kind, two labels and the answer.
    static func examples() throws -> [(LabelKind, String, String, String)] {
        try PromptLibrary.bundled().render("alike-system", [:]).components(separatedBy: "\n").compactMap { line in
            guard let match = line.wholeMatch(of: /- (\w+) "([^"]+)" and "([^"]+)": (\w+)/), let kind = LabelKind(rawValue: String(match.output.1))
            else { return nil }
            return (kind, String(match.output.2), String(match.output.3), String(match.output.4))
        }
    }

    @Test func everyExampleIsTwoLabelsInTheirKindsFormOfAKindTheModelGivesAndOneOfTheTwoAnswers() throws {
        let examples = try Self.examples()
        #expect(examples.count >= 8, "the prompt gives examples: \(examples.count)")
        for (kind, a, b, answer) in examples {
            #expect(LabelKind.modelKinds.contains(kind) && !kind.isUsersOwn, "\(kind) is a kind the model gives, never the user's tag")
            for value in [a, b] {
                #expect(DocumentLabel.normalized(value, kind: kind)?.value == value, "“\(value)” is a \(kind) as validation keeps it")
            }
            #expect(LabelJudgement(rawValue: answer) != nil, "“\(answer)” is one of the answers")
        }
        let answers = Set(examples.map(\.3))
        #expect(answers == ["same", "different"], "both answers are shown")
        let scripts = Set(examples.flatMap { [$0.1, $0.2] }.compactMap { $0.unicodeScalars.first { $0.properties.isAlphabetic && !$0.isASCII } })
        #expect(!scripts.isEmpty, "and examples are not all in English, as the model copies an example's language too")
    }

    /// The pairs `arrumatorcli eval` measures the judge by, as `expected.json` holds them.
    static func measured() throws -> [Evaluation.PairCase] {
        let corpus = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/expected.json", directoryHint: .notDirectory)
        return try JSONDecoder().decode(Evaluation.Corpus.self, from: Data(contentsOf: corpus)).labelPairs
    }

    @Test func noLabelTheJudgeIsMeasuredByIsAnExampleOfItsPrompt() throws {
        // Every quoted value of the prompt, in its list of examples and in its prose alike.
        let prompt = try PromptLibrary.bundled().render("alike-system", [:])
        let shown = Set(prompt.matches(of: /"([^"\n]+)"/).map { String($0.output.1) })
        let measured = try Self.measured()
        let labels = Set(measured.flatMap { [$0.value, $0.into] })
        #expect(shown.isDisjoint(with: labels), "a model told the answer is not measured: \(shown.intersection(labels).sorted())")
        let words = Set(measured.flatMap { ($0.value + " " + $0.into).split(separator: " ").map(String.init) })
        #expect(shown.isDisjoint(with: words), "nor a name of it shown on its own: \(shown.intersection(words).sorted())")
        // A pair held out is of a kind the prompt does not show: no word of it is a word of a value the prompt quotes, as
        // "Ana Sofia Costa" beside "Ana Ferreira" would be the example's kind again.
        let folded = { (text: String) in Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)) }
        let quoted = shown.reduce(into: Set<String>()) { $0.formUnion(folded($1)) }
        for pair in measured where pair.heldOut {
            let own = folded(pair.value + " " + pair.into)
            #expect(own.isDisjoint(with: quoted), "held out, “\(pair.value)” / “\(pair.into)” shares no word with an example: \(own.intersection(quoted).sorted())")
        }
    }

    // MARK: Asking

    @Test func theJudgementIsTheModelsAndEveryCallIsTraced() async throws {
        let w = try await World.make { _ in try Self.answer("different") }
        defer { w.env.cleanup() }
        let verdict = try await w.judge()
        #expect(verdict == LabelVerdict(judgement: .different, reason: "Two first names, Maria and Mario: two people.",
                                        model: ClassifyHarness.chatModel, problem: nil), "the model judged them two")
        let step = try await w.step()
        let exchange = try step.exchange()
        #expect(step.status == .ok && exchange.count == 1, "one call, traced with what was sent and came back")
        let call = try #require(exchange.first)
        #expect(call.system.contains("When you cannot tell a slip from another name, the answer is \"different\"") && call.user.contains("Mario Silva"),
                "the app's own prompt and the pair")
        #expect(step.input?.contains("\"intoDocuments\":4") == true, "and what it was shown of each, in the trace's input")
    }

    @Test func anInvalidAnswerGoesBackAndNoValidOneLeavesNoJudgementSayingWhy() async throws {
        let calls = Mutex(0)
        let w = try await World.make { _ in
            calls.withLock { $0 += 1 }
            return try Self.answer("perhaps")
        }
        defer { w.env.cleanup() }
        let verdict = try await w.judge()
        #expect(verdict.judgement == nil && verdict.problem?.contains("no valid answer") == true, "no judgement, and why: \(verdict)")
        #expect(calls.withLock { $0 } == w.env.config.analysis.repairAttempts + 1, "the answer went back as often as a document's would")
        #expect(try await w.step().status == .error, "the trace says it failed")
    }

    @Test func anAwayServerIsThrownSoThePairWaits() async throws {
        let w = try await World.make { _ in throw OllamaError.unreachable("connection refused") }
        defer { w.env.cleanup() }
        await #expect(throws: OllamaError.self, "the server being away is the caller's to wait out") { try await w.judge() }
    }
}
