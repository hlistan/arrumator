@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The model reads every document once, with the app's own prompt, picks out its signals, which become its labels
/// and all it is described by, and names its file.
@Suite struct DocumentAnalyzerTests {
    /// By default, few and short labels, so the limits show.
    static func validator(maxPerKind: Int = 3, maxValueChars: Int = 40) throws -> AnswerValidator {
        var labels = try PipelineConfig.bundledDefaults().labels
        labels.maxPerKind = maxPerKind
        labels.maxValueChars = maxValueChars
        return AnswerValidator(labels: labels)
    }

    static func defaultValidator() throws -> AnswerValidator {
        AnswerValidator(labels: try PipelineConfig.bundledDefaults().labels)
    }

    // MARK: Validation

    @Test func everyKindOfLabelIsReadAndNormalised() throws {
        let v = try Self.defaultValidator().validate("<think>hmm</think>" + Fixtures.answer())
        #expect(v.labels == Fixtures.edpLabels, "a day-first date becomes ISO, and kinds come in their order")
        #expect(v.fileName == "2026-07-05 EDP Comercial - Fatura eletricidade julho" && v.notes.isEmpty,
                "the file name is kept as the model gave it, and nothing is noted against a clean answer")
    }

    @Test func eachKindIsTidiedToOneLineWithoutRepeatsAndCappedMostSignificantFirst() throws {
        let answer = Fixtures.answer([
            .party: ["  Maria\n  Exemplo ", "MARIA EXEMPLO", "Mária Exemplo", "", "João Silva", "Ana Costa", "Rui Sá"],
            .object: ["apartment Rua das Flores 12, Porto, with garage and storage room",
                      "PT0002000012345678PT0002000012345678PT0002000012345678"],
        ])
        let validated = try Self.validator().validate(answer)
        #expect(validated.labels.values(.party) == ["Maria Exemplo", "João Silva", "Ana Costa"],
                "the same name however written is one label, and a kind keeps only the first maxPerKind")
        #expect(validated.notes.contains("parties: more than 3, the rest dropped"), "what was dropped is noted for the trace")
        #expect(validated.labels.values(.object) == ["apartment Rua das Flores 12, Porto, with", "PT0002000012345678PT0002000012345678PT00"],
                "a long label is cut after the last whole word that fits in maxValueChars, or at it when one word is longer")
    }

    @Test func eachKindKeepsOnlyWhatIsALabelOfThatKind() throws {
        let answer = Fixtures.answer([
            .type: ["invoice", "receipt"], .date: ["yesterday"], .deadline: ["31.07.2026", "soon"],
            .period: ["2025", "2026-06/2026-07", "2026-13", "Q3"], .amount: ["54.21 EUR", "free", "EUR 12.00", "25000.00: cny", "1.5 ABC"],
            .reference: ["invoice 2026/17", "tax assessment for 2025", "the customer's"],
            .topic: ["Electricity", "electricity"], .language: ["Portuguese", "POR", "ru", "Klingonese", "english"],
        ])
        let v = try Self.validator(maxPerKind: 5).validate(answer)
        #expect(v.labels.values(.type) == ["invoice"], "a document has one type")
        #expect(v.labels.values(.date).isEmpty && v.labels.values(.deadline) == ["2026-07-31"], "dates are ISO or nothing")
        #expect(v.labels.values(.period) == ["2025", "2026-06/2026-07"], "a period is a year, a month, a day or a span of them")
        #expect(v.labels.values(.amount) == ["54.21 EUR", "12.00 EUR", "25000.00 CNY", "1.5 ABC"],
                "an amount has a number, written before its currency code when it has one")
        #expect(v.labels.values(.reference) == ["invoice 2026/17", "tax assessment for 2025"], "a reference has a number")
        #expect(v.labels.values(.topic) == ["electricity"], "topics are lowercase, once")
        #expect(v.labels.values(.language) == ["pt", "ru", "en"], "a language named in English or by any ISO 639 code is its code, once")
        #expect(v.notes.contains("dates: “yesterday” is no date, dropped") && v.notes.contains("languages: “Klingonese” is no language, dropped"),
                "the trace says which values were dropped and why")
        #expect(v.notes.contains("types: more than 1, the rest dropped"), "and that a document has one type")
    }

    @Test func aDocumentShowingNothingSignificantHasNoLabels() throws {
        let empty = Dictionary(uniqueKeysWithValues: LabelKind.allCases.map { ($0, [String]()) })
        let validated = try Self.validator().validate(Fixtures.answer(empty))
        #expect(validated.labels.isEmpty && validated.notes.isEmpty, "empty lists are a valid answer, with nothing to note")
    }

    @Test func aMissingListOrAnAnswerThatIsNoJSONGoesBackToTheModel() throws {
        #expect(throws: AnswerValidationError.invalid(["jurisdictions is missing; give [] when the document shows none"]),
                "the model is told which list is missing and what to give instead") {
            try Self.validator().validate(Fixtures.answer(omitting: .jurisdiction))
        }
        #expect("an answer that is no JSON is sent back as such") {
            try Self.validator().validate("Maria Exemplo, Portugal")
        } throws: { error in
            if case AnswerValidationError.notJSON = error { true } else { false }
        }
    }

    @Test func theSchemaAsksForEveryKindTheFactsFirstAndTheNameLast() throws {
        let config = try PipelineConfig.bundledDefaults()
        let schema = ClassificationSchema.analysis(maxPerKind: config.labels.maxPerKind)
        let body = OllamaChatRequest(model: "m", messages: [.user("hi")], format: schema, options: [:], keepAlive: "1m", think: false)
            .body.serialized()
        let keys = ClassificationSchema.answerOrder.map(ClassificationSchema.labelsKey) + [ClassificationSchema.fileNameKey]
        let positions = try keys.map { key in try #require(body.range(of: "\"\(key)\"")?.lowerBound, "\(key) is asked for") }
        #expect(positions == positions.sorted(), "the model writes the sender, type and date before the rest, and the name last")
        #expect(Set(ClassificationSchema.answerOrder) == Set(LabelKind.allCases) && ClassificationSchema.answerOrder.count == LabelKind.allCases.count,
                "the schema asks for every kind, once")
        #expect(schema["properties"]?["types"]?["maxItems"] == .number(1) && schema["properties"]?["dates"]?["maxItems"] == .number(1),
                "one type and one date")
        #expect(schema["properties"]?["topics"]?["maxItems"] == .number(Double(config.labels.maxPerKind)), "other kinds up to labels.maxPerKind")
        #expect(schema["properties"]?["types"]?["items"]?["enum"]?.arrayValue?.contains(.string("other")) == false,
                "a document no type fits has none, rather than \"other\"")
    }

    // MARK: Asking the model

    @Test func theModelReadsTheDocumentWithTheAppsOwnPrompt() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer() }
        defer { h.env.cleanup() }
        let outcome = try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        #expect(outcome.labels == Fixtures.edpLabels, "the document is described by the labels the model gave")
        #expect(outcome.analysis == DocumentAnalysis(fileName: "2026-07-05 EDP Comercial - Fatura eletricidade julho", model: "ministral-3:14b"),
                "and named as the model named it, by the model that read it")
        let embedded = try #require(await h.mock.embedRequests.first?.input.first)
        #expect(outcome.embedding == VectorCodec.normalized(MockOllama.hashEmbedding(embedded, dimension: 256)),
                "and its embedding, of the text sent to the embedding model, is made for search by meaning")

        let request = try #require(await h.mock.chatRequests.first)
        #expect(await h.mock.chatCount == 1, "one model call per document")
        let system = request.messages[0].content
        for key in ClassificationSchema.answerOrder.map(ClassificationSchema.labelsKey) + ["file_name"] {
            #expect(system.contains("- \(key):"), "the prompt explains \(key)")
        }
        #expect(system.contains("no folders") && !system.contains("{{"), "written for labelling, every placeholder filled")
        #expect(request.messages[1].content.contains("NIF 503504564   Cliente: Maria Exemplo"), "the model reads the document's text")
        #expect(!request.messages[1].content.contains("## THIS ARCHIVE"), "an archive without labels has nothing to tell it")

        let steps = await h.steps(.analyse)
        #expect(steps.map(\.status) == [.ok], "the exchange is recorded in the trace")
        #expect(steps.first?.output?.contains("Portugal") == true && steps.first?.output?.contains("\"system\"") == true,
                "the trace holds the answer and the raw prompt")
        let output = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(steps.first?.output).utf8))
        #expect(output[TraceStep.exchangeKey]?.arrayValue?.count == 1 && output["answer"] != nil,
                "the prompt and raw answer sit under the key retention clears, apart from the answer it keeps")
    }

    @Test func aDocumentQuotingATemplatePlaceholderIsReadAsWritten() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer() }
        defer { h.env.cleanup() }
        let newsletter = "Dear {{first_name}}, your {{document}} and {{archive}} are ready.\n" + Fixtures.edpText
        let outcome = try await h.analyse(Fixtures.content("newsletter.eml", text: newsletter))
        #expect(outcome.labels == Fixtures.edpLabels,
                "a merge field left unrendered in an e-mail is the document's text, not a placeholder of the app's prompt")
        let user = try #require(await h.mock.chatRequests.first?.messages[1].content)
        #expect(user.contains("Dear {{first_name}}, your {{document}} and {{archive}} are ready."),
                "the model reads the text exactly as the document has it, and no value is substituted into it")
    }

    @Test func theModelIsToldTheArchivesLabelsAndTheUsersDecisions() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer() }
        defer { h.env.cleanup() }
        let guidance = LabelGuidance(
            used: [.sender: ["EDP", "MEO"], .topic: ["electricity"]],
            preferred: [LabelPreference(from: DocumentLabel(kind: .sender, value: "EDP Comercial"), to: "EDP")],
            unwanted: [DocumentLabel(kind: .topic, value: "document")])
        _ = try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText), guidance: guidance)
        let request = try #require(await h.mock.chatRequests.first)
        let user = request.messages[1].content
        #expect(user.hasPrefix("## THIS ARCHIVE"), "before the document")
        #expect(user.contains("- senders: EDP; MEO\n- topics: electricity"), "the labels in use, by the answer's name for their kind")
        #expect(user.contains("- senders: EDP Comercial → EDP"), "how the user wants a label written")
        #expect(user.contains("- topics: document"), "a label the user does not want")
        #expect(user.contains("## DOCUMENT") && !user.contains("{{"), "every placeholder filled")
        #expect(request.messages[0].content.contains("THIS ARCHIVE"), "the system prompt says how to use it")

        _ = try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText), guidance: LabelGuidance(used: [.sender: ["EDP"]]))
        let second = try #require(await h.mock.chatRequests.last?.messages[1].content)
        #expect(second.contains("Labels its owner does not want:\n-\n"), "an empty list says so")
    }

    @Test func anInvalidAnswerIsRepairedByTheModel() async throws {
        let h = try await ClassifyHarness.make { request in
            request.messages.count > 2 ? Fixtures.answer() : Fixtures.answer(omitting: .language)
        }
        defer { h.env.cleanup() }
        let outcome = try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        #expect(outcome.labels == Fixtures.edpLabels, "the repaired answer is the one kept")
        let repair = try #require(await h.mock.chatRequests.last?.messages.last?.content)
        #expect(repair.contains("languages is missing"), "the model is told what was wrong")
        #expect(await h.steps(.analyse).map(\.status) == [.warn], "a repaired answer is flagged in the trace")
    }

    @Test func withoutAValidAnswerTheDocumentWaitsForTheUserUnlabelled() async throws {
        let h = try await ClassifyHarness.make { _ in "I cannot tell." }
        defer { h.env.cleanup() }
        let outcome = try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        #expect(outcome.labels == nil, "nil, not an empty list: the document was not labelled, rather than labelled with nothing")
        #expect(outcome.analysis == DocumentAnalysis(problems: ["the model gave no valid answer"]), "and it keeps its own name")
        let steps = await h.steps(.analyse)
        #expect(steps.map(\.status) == [.error] && steps.first?.error?.contains("No valid answer") == true,
                "the trace records the failed reading and why")
    }

    @Test func aDocumentWithNoTextWaitsForTheUserUnderItsOwnName() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer() }
        defer { h.env.cleanup() }
        let outcome = try await h.analyse(Fixtures.content("blank.pdf", text: "  \n"))
        #expect(outcome.analysis.problems == ["no text could be read"] && outcome.analysis.fileName == nil,
                "a document that waits for the user keeps its own name")
    }

    @Test func aModelThatCannotBeReachedIsNoAnswerTheDocumentWaitsForIt() async throws {
        let h = try await ClassifyHarness.make { _ in throw OllamaError.unreachable("connection refused") }
        defer { h.env.cleanup() }
        await #expect(throws: OllamaError.unreachable("connection refused"), "the document waits for the model instead of being filed unread") {
            try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        }
    }
}
