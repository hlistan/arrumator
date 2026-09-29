@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The model picks a document's signals out of its text with a prompt of its own, and the app keeps them as labels:
/// whom and what the document concerns, the jurisdictions it falls under, the languages it is written in.
@Suite struct LabelExtractorTests {
    /// Few and short labels, so the limits show.
    static var config: LabelsConfig {
        get throws {
            var config = try PipelineConfig.bundledDefaults().labels
            config.maxPerKind = 3
            config.maxValueChars = 40
            return config
        }
    }

    /// An answer naming the signals of each kind; a kind passed as nil is left out of the answer.
    static func answer(subjects: [String]? = ["Maria Exemplo"], objects: [String]? = ["electricity supply point PT0002000012345678"],
                       jurisdictions: [String]? = ["Portugal"], languages: [String]? = ["pt"]) -> String {
        let lists = [("subjects", subjects), ("objects", objects), ("jurisdictions", jurisdictions), ("languages", languages)]
            .compactMap { key, values in values.map { (key, $0) } }
        return JSON.string(Dictionary(uniqueKeysWithValues: lists))
    }

    struct Extraction {
        let harness: ClassifyHarness
        let extractor: LabelExtractor
        let sink = MemoryTraceSink()

        var trace: TraceContext { TraceContext(traceID: 1, sink: sink) }

        func labels(_ content: ExtractedContent) async throws -> [DocumentLabel]? {
            try await extractor.labels(for: content, settings: harness.settings, config: harness.env.config, trace: trace)
        }

        func labelSteps() async -> [TraceStep] { await sink.steps.filter { $0.stage == .label } }
    }

    static func extraction(_ handler: @escaping MockOllama.ChatHandler) async throws -> Extraction {
        let harness = try await ClassifyHarness.make(handler: handler)
        let prompts = PromptBuilder(library: try PromptLibrary.bundled(), config: harness.env.config.classification,
                                    naming: harness.env.config.naming)
        return Extraction(harness: harness, extractor: LabelExtractor(gate: InferenceGate(api: harness.mock, retryDelays: []),
                                                                      models: ModelManager(api: harness.mock, config: harness.env.config.ollama),
                                                                      prompts: prompts))
    }

    // MARK: Validation

    @Test func eachKindIsTidiedToOneLineWithoutRepeatsAndCappedMostSignificantFirst() throws {
        let answer = Self.answer(subjects: ["  Maria\n  Exemplo ", "MARIA EXEMPLO", "Mária Exemplo", "", "João Silva", "Ana Costa", "Rui Sá"],
                                 objects: ["apartment Rua das Flores 12, Porto, with garage and storage room",
                                           "PT0002000012345678PT0002000012345678PT0002000012345678"])
        let validated = try LabelValidator(config: try Self.config).validate(answer)
        #expect(validated.labels.filter { $0.kind == .subject }.map(\.value) == ["Maria Exemplo", "João Silva", "Ana Costa"],
                "the same name however written is one label, and a kind keeps only the first maxPerKind")
        #expect(validated.notes.contains { $0.contains("subjects: more than 3") }, "what was dropped is noted for the trace")
        #expect(validated.labels.filter { $0.kind == .object }.map(\.value)
                    == ["apartment Rua das Flores 12, Porto, with", "PT0002000012345678PT0002000012345678PT00"],
                "a long label is cut after the last whole word that fits in maxValueChars, or at it when one word is longer")
        #expect(validated.labels.map(\.kind) == [.subject, .subject, .subject, .object, .object, .jurisdiction, .language],
                "labels come kind by kind, in the order the model ranked them")
    }

    @Test func languagesBecomeTheirISOCodeAndWhatIsNoLanguageIsDropped() throws {
        let validated = try LabelValidator(config: try Self.config)
            .validate(Self.answer(languages: ["Portuguese", "POR", "ru", "Klingonese", "english"]))
        #expect(validated.labels.filter { $0.kind == .language }.map(\.value) == ["pt", "ru", "en"],
                "a language named in English or by any ISO 639 code is its ISO 639-1 code, once")
        #expect(validated.notes == ["languages: “Klingonese” is not an ISO 639 language, dropped"])
    }

    @Test func aDocumentShowingNothingSignificantHasNoLabels() throws {
        let validated = try LabelValidator(config: try Self.config).validate(Self.answer(subjects: [], objects: [], jurisdictions: [], languages: []))
        #expect(validated.labels.isEmpty && validated.notes.isEmpty)
    }

    @Test func aMissingListOrAnAnswerThatIsNoJSONGoesBackToTheModel() throws {
        #expect(throws: AnswerValidationError.invalid(["jurisdictions is missing; give [] when the document shows none"])) {
            try LabelValidator(config: try Self.config).validate(Self.answer(jurisdictions: nil))
        }
        #expect {
            try LabelValidator(config: try Self.config).validate("Maria Exemplo, Portugal")
        } throws: { error in
            if case AnswerValidationError.notJSON = error { true } else { false }
        }
    }

    // MARK: Asking the model

    @Test func theModelReadsTheDocumentWithTheSignalsPromptAndNotTheArchivesLogic() async throws {
        let e = try await Self.extraction { _ in Self.answer() }
        defer { e.harness.env.cleanup() }
        let labels = try await e.labels(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        #expect(labels == StubLabeler.edpBill)

        let request = try #require(await e.harness.mock.chatRequests.first)
        #expect(await e.harness.mock.chatCount == 1)
        let properties = request.format?["properties"]
        for key in ["subjects", "objects", "jurisdictions", "languages"] {
            #expect(properties?[key]?["maxItems"] == .number(Double(e.harness.env.config.labels.maxPerKind)),
                    "the schema asks for each kind of signal, at most maxPerKind of each")
        }
        let system = request.messages[0].content
        #expect(system.contains("signals") && system.contains("jurisdictions:") && system.contains("ISO 639-1"),
                "the model is asked with the prompt written for picking out signals")
        #expect(!system.contains("{{"), "every placeholder is filled")
        let logic = try await e.harness.logic.current()?.body ?? ""
        #expect(!logic.isEmpty && !system.contains(logic), "labels say what a document concerns, whatever the logic files it by")
        #expect(request.messages[1].content.contains("NIF 503504564   Cliente: Maria Exemplo"), "the model reads the document's text")

        let steps = await e.labelSteps()
        #expect(steps.map(\.status) == [.ok], "the exchange is recorded in the trace")
        #expect(steps.first?.output?.contains("Portugal") == true && steps.first?.output?.contains("\"system\"") == true,
                "the trace holds the labels and the raw prompt")
    }

    @Test func anInvalidAnswerIsRepairedByTheModel() async throws {
        let e = try await Self.extraction { request in
            request.messages.count > 2 ? Self.answer() : Self.answer(languages: nil)
        }
        defer { e.harness.env.cleanup() }
        let labels = try await e.labels(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        #expect(labels == StubLabeler.edpBill)
        let repair = try #require(await e.harness.mock.chatRequests.last?.messages.last?.content)
        #expect(repair.contains("languages is missing"), "the model is told what was wrong")
        #expect(await e.labelSteps().map(\.status) == [.warn], "a repaired answer is flagged in the trace")
    }

    @Test func withoutAValidAnswerTheDocumentHasNoLabelsAndTheTraceSaysWhy() async throws {
        let e = try await Self.extraction { _ in "I cannot tell." }
        defer { e.harness.env.cleanup() }
        let labels = try await e.labels(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        #expect(labels == nil, "nil, not an empty list: the document was not labelled, rather than labelled with nothing")
        let steps = await e.labelSteps()
        #expect(steps.map(\.status) == [.error] && steps.first?.error?.contains("No valid answer") == true)
    }

    @Test func aModelThatCannotBeReachedIsNoAnswerTheDocumentWaitsForIt() async throws {
        let e = try await Self.extraction { _ in throw OllamaError.unreachable("connection refused") }
        defer { e.harness.env.cleanup() }
        await #expect(throws: OllamaError.unreachable("connection refused")) {
            try await e.labels(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        }
    }
}
