@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// A search request's prompt fits the context the model reads it in (`PromptBudget`): what it is shown of the archive's
/// labels, and what a repair sends back, are cut to fit, and the trace says so.
extension SearchInterpreterTests {
    @Test func theArchivesLabelsAreShownFewerTheLeastUsedFirstUntilTheRequestFitsTheContext() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        let vocabulary: [LabelKind: [LabelUsage]] = [.sender: Self.usage(.sender, "EDP Comercial", "Águas do Porto", "MEO"),
                                                     .topic: Self.usage(.topic, "electricity")]
        var config = w.env.config
        let preset = try config.tasks.preset(.medium)
        let system = try w.interpreter.library.render("search-system", [
            "max_per_kind": String(config.tasks.maxValuesPerKind), "max_words": String(config.tasks.maxWords),
            "max_depth": String(config.tasks.maxGroupingDepth), "max_title_chars": String(config.tasks.maxTitleChars)])
        let full = try w.interpreter.userPrompt(Self.request, vocabulary: vocabulary, limits: preset.promptLabels, today: World.today,
                                                language: try Self.language(of: Self.request))
        config.ollama.charsPerToken = 1
        config.analysis.numCtx = preset.numPredict + system.count + full.count - 1
        _ = try await w.interpret(Self.request, vocabulary: vocabulary, config: config)
        let user = try #require(await w.mock.chatRequests.first?.messages[1].content)
        #expect(user.contains(#""EDP Comercial", "Águas do Porto""#) && !user.contains("MEO") && user.contains("electricity"),
                "the least used label of the kind shown most is left out first, so the request fits beside the app's prompt")
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
        let input = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(step.input).utf8))
        #expect(input["labelsLeftOut"] == .number(1), "and the trace says how many were left out: \(input)")
    }

    /// The language the model is told `request` is written in, as the interpreter names it.
    static func language(of request: String) throws -> String? {
        LanguageDetector(config: try PipelineConfig.bundledDefaults().extraction).name(of: request)
    }

    /// A prompt Ollama counts as filling the context, as one in another script holds fewer characters a token than
    /// `ollama.charsPerToken` reckons, is fitted again at what Ollama counted and asked again, and the trace says so.
    @Test func aRequestOllamaCountsFillingTheContextIsFittedAgainAtWhatItCounted() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        // A character a token, a third of what the estimate reckons.
        await w.mock.countPromptTokens { request in request.messages.reduce(0) { $0 + $1.content.count } }
        let vocabulary: [LabelKind: [LabelUsage]] = [.sender: Self.usage(.sender, "EDP Comercial", "Águas do Porto", "MEO")]
        var config = w.env.config
        let preset = try config.tasks.preset(.medium)
        let system = try w.interpreter.library.render("search-system", [
            "max_per_kind": String(config.tasks.maxValuesPerKind), "max_words": String(config.tasks.maxWords),
            "max_depth": String(config.tasks.maxGroupingDepth), "max_title_chars": String(config.tasks.maxTitleChars)])
        let full = try w.interpreter.userPrompt(Self.request, vocabulary: vocabulary, limits: preset.promptLabels, today: World.today,
                                                language: try Self.language(of: Self.request))
        config.analysis.numCtx = preset.numPredict + system.count + full.count - 1
        let read = try await w.interpret(Self.request, vocabulary: vocabulary, config: config)
        #expect(read.plan == Self.edp2025, "the answer to the prompt fitted again is the plan")
        let requests = await w.mock.chatRequests
        #expect(requests.count == 2 && requests[0].messages[1].content.contains("MEO") && requests[1].messages[1].content.contains("Águas do Porto")
                    && !requests[1].messages[1].content.contains("MEO"),
                "asked again with the least used label left out, as the prompt fits at a character a token")
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
        let input = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(step.input).utf8))
        #expect(input["refitted"] == .array([.number(1)]) && input["labelsLeftOut"] == .number(1),
                "the trace keeps the characters a token it was fitted at again, and what that left out: \(input)")
        let calls = try step.exchange()
        #expect(step.status == .warn && step.error?.contains("fitted again 1 time") == true && calls.count == 2,
                "and says so, with both calls: \(step.error ?? "")")
        config.ollama.refitAttempts = 0
        let never = try await world { _ in try Self.answer() }
        defer { never.env.cleanup() }
        await never.mock.countPromptTokens { request in request.messages.reduce(0) { $0 + $1.content.count } }
        _ = try await never.interpret(Self.request, vocabulary: vocabulary, config: config)
        #expect(await never.mock.chatCount == 1, "ollama.refitAttempts of 0 never asks again")
    }

    /// A prompt fitted again is a fresh exchange, in which the model has been told of no word: an alternative it gave as
    /// a word again after being told before the refit, and gives as a word once more after it, goes back again rather
    /// than being kept as an answer to being told (second review of 2026-10-04, finding 2).
    @Test func aWordSentBackBeforeARefitIsSentBackAgainAfterIt() async throws {
        let request = "bills for electricity, water, insurance or rent"
        @Sendable func topics(_ values: String...) -> JSONValue { .array(values.map { Self.asked($0, $0) }) }
        let w = try await world { _ in
            try Self.answer(["senders": .array([]), "dates": .array([]), "types": .array([Self.asked("invoice", "bills")]),
                             "topics": topics("electricity", "water", "rent"), "words": Self.strings("insurance"), "group_by": .array([])])
        }
        defer { w.env.cleanup() }
        await w.mock.countPromptTokens { request in request.messages.reduce(0) { $0 + $1.content.count } }
        let vocabulary: [LabelKind: [LabelUsage]] = [.sender: Self.usage(.sender, "EDP Comercial", "Águas do Porto", "MEO")]
        var config = w.env.config
        let preset = try config.tasks.preset(.medium)
        let system = try w.interpreter.library.render("search-system", [
            "max_per_kind": String(config.tasks.maxValuesPerKind), "max_words": String(config.tasks.maxWords),
            "max_depth": String(config.tasks.maxGroupingDepth), "max_title_chars": String(config.tasks.maxTitleChars)])
        let full = try w.interpreter.userPrompt(request, vocabulary: vocabulary, limits: preset.promptLabels, today: World.today,
                                                language: try Self.language(of: request))
        config.analysis.numCtx = preset.numPredict + system.count + full.count - 1
        config.ollama.refitAttempts = 1
        let read = try await w.interpret(request, vocabulary: vocabulary, config: config)
        #expect(read.plan?.words == ["insurance"], "the model's word given again in the fresh exchange is its answer: \(String(describing: read.plan))")
        let requests = await w.mock.chatRequests
        #expect(requests.count == 4, "asked, told, refitted and asked afresh, then told again: \(requests.count) calls")
        #expect(requests.last?.messages.last?.content.contains("“insurance” sit among the topics") == true,
                "the fresh exchange sends the word back too, as the model was told nothing in it")
    }

    /// A prompt `world`'s model counts filling the context however often it is fitted again: each count a token more than
    /// the context holds beside the answer than the one before, as a tokenizer the estimate never catches up with. The
    /// config it is read with, its context just room for the prompt at a character a token, beside many senders to leave
    /// out.
    private func everFull(_ w: World) async throws -> (config: PipelineConfig, vocabulary: [LabelKind: [LabelUsage]]) {
        let vocabulary: [LabelKind: [LabelUsage]] = [.sender: Self.usage(.sender, (1...40).map { "Sender \($0) Lda" })]
        var config = w.env.config
        let preset = try config.tasks.preset(.medium)
        let system = try w.interpreter.library.render("search-system", [
            "max_per_kind": String(config.tasks.maxValuesPerKind), "max_words": String(config.tasks.maxWords),
            "max_depth": String(config.tasks.maxGroupingDepth), "max_title_chars": String(config.tasks.maxTitleChars)])
        let full = try w.interpreter.userPrompt(Self.request, vocabulary: vocabulary, limits: preset.promptLabels, today: World.today,
                                                language: try Self.language(of: Self.request))
        config.ollama.charsPerToken = 1
        config.analysis.numCtx = preset.numPredict + system.count + full.count + 10
        let context = config.analysis.numCtx - preset.numPredict
        let counted = Mutex(0)
        await w.mock.countPromptTokens { _ in counted.withLock { calls in defer { calls += 1 }; return context + calls } }
        return (config, vocabulary)
    }

    /// However often Ollama counts the prompt filling the context, it is fitted again only `ollama.refitAttempts` times,
    /// and every call made is in the trace (review of 2026-10-04, finding 15).
    @Test func aPromptThatKeepsFillingTheContextIsFittedAgainOnlyAsOftenAsRefitAttemptsAllows() async throws {
        for attempts in [2, 4] {
            let w = try await world { _ in try Self.answer() }
            defer { w.env.cleanup() }
            var (config, vocabulary) = try await everFull(w)
            config.ollama.refitAttempts = attempts
            let read = try await w.interpret(Self.request, vocabulary: vocabulary, config: config)
            #expect(read.plan == Self.edp2025, "the last answer is the plan, though its prompt still filled the context")
            #expect(await w.mock.chatCount == attempts + 1, "asked once, then once for each fitting again it allows, and no more")
            let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
            let input = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(step.input).utf8))
            guard case let .array(refitted) = input["refitted"] else { Issue.record("the trace keeps each fitting again: \(input)"); continue }
            #expect(refitted.count == attempts, "each fitting again is in the trace: \(input)")
            #expect(try step.exchange().count == attempts + 1 && step.error?.contains("fitted again \(attempts) times") == true
                        && step.error?.contains("the model's context was full: a prompt took") == true,
                    "every call is in the trace, which says the last prompt still filled the context: \(step.error ?? "")")
        }
    }

    /// A task stopped while its prompt is fitted again asks the model nothing more, and the trace keeps the calls made.
    @Test func aTaskStoppedWhileItsPromptIsFittedAgainAsksNothingMore() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        let (config, vocabulary) = try await everFull(w)
        await w.mock.hold(afterAnswering: 1)
        let reading = Task { try await w.interpret(Self.request, vocabulary: vocabulary, config: config) }
        #expect(await Patience.until { await w.mock.chatCount == 2 }, "the prompt, counted filling the context, is fitted again and sent")
        reading.cancel()
        await #expect(throws: CancellationError.self, "a stop ends the reading, not a failure of it") { try await reading.value }
        #expect(await w.mock.chatCount == 2, "and nothing more is asked once it is stopped")
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
        #expect(try step.exchange().count == 2, "both calls are in the trace")
    }

    /// The task is named in the request's language, which the model is told, as it otherwise names it in the language of
    /// the archive's labels (QA 2026-10-04, TSK-3).
    @Test func theModelIsToldTheLanguageTheRequestIsWrittenIn() async throws {
        let w = try await world { _ in try Self.answer() }
        defer { w.env.cleanup() }
        _ = try await w.interpret("documents from the tax authority in any country about income tax, by sender")
        let user = try #require(await w.mock.chatRequests.first?.messages[1].content)
        #expect(user.contains("The request is written in English: write the title in English."), "\(user)")
        _ = try await w.interpret("12345")
        let unknown = try #require(await w.mock.chatRequests.last?.messages[1].content)
        #expect(!unknown.contains("is written in"), "a request without words says nothing of a language: \(unknown)")
    }

    static func usage(_ kind: LabelKind, _ values: String...) -> [LabelUsage] { usage(kind, values) }

    /// `values` as labels of `kind` in use, the first the most used.
    static func usage(_ kind: LabelKind, _ values: [String]) -> [LabelUsage] {
        values.enumerated().map { LabelUsage(label: DocumentLabel(kind: kind, value: $1), documents: values.count - $0) }
    }

    @Test func aRepairSendsBackOnlyAsMuchOfACutOffAnswerAsTheContextHolds() async throws {
        let cut = String(repeating: "x ", count: 400)
        let w = try await world { request in request.messages.count > 2 ? try Self.answer() : MockOllama.cutOff(after: cut) }
        defer { w.env.cleanup() }
        var config = w.env.config
        let preset = try config.tasks.preset(.medium)
        let system = try w.interpreter.library.render("search-system", [
            "max_per_kind": String(config.tasks.maxValuesPerKind), "max_words": String(config.tasks.maxWords),
            "max_depth": String(config.tasks.maxGroupingDepth), "max_title_chars": String(config.tasks.maxTitleChars)])
        let user = try w.interpreter.userPrompt(Self.request, vocabulary: [:], limits: preset.promptLabels, today: World.today,
                                                language: try Self.language(of: Self.request))
        let repair = try w.interpreter.library.render("repair-user", ["errors": AnswerValidationError.cutOff(preset.numPredict).localizedDescription])
        let left = 50
        config.ollama.charsPerToken = 1
        config.analysis.numCtx = preset.numPredict + system.count + user.count + repair.count + left
        let read = try await w.interpret(Self.request, config: config)
        #expect(read.plan == Self.edp2025, "the repaired answer is read")
        let repaired = try #require(await w.mock.chatRequests.last)
        #expect(repaired.messages.reduce(0) { $0 + $1.content.count } <= system.count + user.count + repair.count + left,
                "the repair fits the model's context beside its answer, as the first call did")
        #expect(repaired.messages[2].content == String(cut.prefix(left)), "sending back as much of the cut-off answer as fits, from its start")
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
        #expect(try step.exchange().first?.cutWhenSentBack == cut.count - left, "and the trace says how much was left out")
    }
}
