@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
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
        let full = try w.interpreter.userPrompt(Self.request, vocabulary: vocabulary, limits: preset.promptLabels, today: World.today)
        config.ollama.charsPerToken = 1
        config.analysis.numCtx = preset.numPredict + system.count + full.count - 1
        _ = try await w.interpret(Self.request, vocabulary: vocabulary, config: config)
        let user = try #require(await w.mock.chatRequests.first?.messages[1].content)
        #expect(user.contains("EDP Comercial; Águas do Porto") && !user.contains("MEO") && user.contains("electricity"),
                "the least used label of the kind shown most is left out first, so the request fits beside the app's prompt")
        let step = try #require(await w.sink.steps.first { $0.stage == .interpret })
        let input = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(step.input).utf8))
        #expect(input["labelsLeftOut"] == .number(1), "and the trace says how many were left out: \(input)")
    }

    static func usage(_ kind: LabelKind, _ values: String...) -> [LabelUsage] {
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
        let user = try w.interpreter.userPrompt(Self.request, vocabulary: [:], limits: preset.promptLabels, today: World.today)
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
