@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The model reads every document once, with the app's own prompt, and says what it is, picks out its signals, which
/// become its labels, and names its file.
@Suite struct DocumentAnalyzerTests {
    /// By default, few and short labels, so the limits show.
    static func validator(maxPerKind: Int = 3, maxValueChars: Int = 40) throws -> AnswerValidator {
        let config = try PipelineConfig.bundledDefaults()
        var labels = config.labels
        labels.maxPerKind = maxPerKind
        labels.maxValueChars = maxValueChars
        return AnswerValidator(config: config.analysis, labels: labels, entities: config.entities)
    }

    // MARK: Validation

    @Test func theAnswerIsNormalised() throws {
        let defaults = try PipelineConfig.bundledDefaults().labels
        let v = try Self.validator(maxPerKind: defaults.maxPerKind, maxValueChars: defaults.maxValueChars)
            .validate("<think>hmm</think>" + Fixtures.answer())
        #expect(v.correspondent == "EDP Comercial" && v.documentType == .invoice && v.documentDate == "2026-07-05",
                "a day-first date becomes ISO")
        #expect(v.title == "Fatura eletricidade julho" && v.fileName == "2026-07-05 EDP Comercial - Fatura eletricidade julho")
        #expect(v.labels == Fixtures.edpLabels && v.periodYear == nil)
    }

    @Test func eachKindIsTidiedToOneLineWithoutRepeatsAndCappedMostSignificantFirst() throws {
        let answer = Fixtures.answer(subjects: ["  Maria\n  Exemplo ", "MARIA EXEMPLO", "Mária Exemplo", "", "João Silva", "Ana Costa", "Rui Sá"],
                                     objects: ["apartment Rua das Flores 12, Porto, with garage and storage room",
                                               "PT0002000012345678PT0002000012345678PT0002000012345678"])
        let validated = try Self.validator().validate(answer)
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
        let validated = try Self.validator().validate(Fixtures.answer(languages: ["Portuguese", "POR", "ru", "Klingonese", "english"]))
        #expect(validated.labels.filter { $0.kind == .language }.map(\.value) == ["pt", "ru", "en"],
                "a language named in English or by any ISO 639 code is its ISO 639-1 code, once")
        #expect(validated.notes == ["languages: “Klingonese” is not an ISO 639 language, dropped"])
    }

    @Test func aDocumentShowingNothingSignificantHasNoLabels() throws {
        let validated = try Self.validator().validate(Fixtures.answer(subjects: [], objects: [], jurisdictions: [], languages: []))
        #expect(validated.labels.isEmpty && validated.notes.isEmpty)
    }

    @Test func aMissingListOrAnAnswerThatIsNoJSONGoesBackToTheModel() throws {
        #expect(throws: AnswerValidationError.invalid(["jurisdictions is missing; give \"\" or [] when the document shows none"])) {
            try Self.validator().validate(Fixtures.answer(jurisdictions: nil))
        }
        #expect {
            try Self.validator().validate("Maria Exemplo, Portugal")
        } throws: { error in
            if case AnswerValidationError.notJSON = error { true } else { false }
        }
    }

    // MARK: Asking the model

    @Test func theModelReadsTheDocumentWithTheAppsOwnPrompt() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer() }
        defer { h.env.cleanup() }
        let outcome = try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        #expect(outcome.labels == Fixtures.edpLabels)
        let a = outcome.analysis
        #expect(a.correspondent == "EDP Comercial" && a.documentType == .invoice && a.documentDate == "2026-07-05" && a.dateSource == .label)
        #expect(a.fileName == "2026-07-05 EDP Comercial - Fatura eletricidade julho" && a.language == "pt" && a.model == "ministral-3:14b")
        #expect(a.problems.isEmpty && outcome.embedding != nil, "and its embedding is made for search by meaning")

        let request = try #require(await h.mock.chatRequests.first)
        #expect(await h.mock.chatCount == 1, "one model call per document")
        let properties = request.format?["properties"]
        for key in ["correspondent", "document_type", "document_date", "title", "file_name"] {
            #expect(properties?[key] != nil, "the schema asks for \(key)")
        }
        for key in ["subjects", "objects", "jurisdictions", "languages"] {
            #expect(properties?[key]?["maxItems"] == .number(Double(h.env.config.labels.maxPerKind)),
                    "the schema asks for each kind of signal, at most maxPerKind of each")
        }
        let system = request.messages[0].content
        #expect(system.contains("signals") && system.contains("jurisdictions:") && system.contains("ISO 639-1") && system.contains("no folders"),
                "the model is asked with the prompt written for picking out signals")
        #expect(!system.contains("{{"), "every placeholder is filled")
        #expect(request.messages[1].content.contains("NIF 503504564   Cliente: Maria Exemplo"), "the model reads the document's text")

        let steps = await h.steps(.analyse)
        #expect(steps.map(\.status) == [.ok], "the exchange is recorded in the trace")
        #expect(steps.first?.output?.contains("Portugal") == true && steps.first?.output?.contains("\"system\"") == true,
                "the trace holds the answer and the raw prompt")
    }

    @Test func aKnownSenderIsNamedAsTheAppKnowsIt() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer(correspondent: "EDP") }
        defer { h.env.cleanup() }
        let edp = try await h.senders.saveCorrespondent(Correspondent(canonicalName: "EDP Comercial", stableKeys: [Fixtures.edpNIF.token],
                                                                      origin: .learned))
        let outcome = try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText, keys: [Fixtures.edpNIF]))
        #expect(outcome.analysis.correspondent == "EDP Comercial" && outcome.analysis.correspondentID == edp.id,
                "the model wrote it short; the document shows the known sender's tax number")
        let user = try #require(await h.mock.chatRequests.first?.messages[1].content)
        #expect(user.contains("KNOWN CORRESPONDENTS FOUND: EDP Comercial (by stableKey)"), "the model is told whom the app recognised")
    }

    @Test func anInvalidAnswerIsRepairedByTheModel() async throws {
        let h = try await ClassifyHarness.make { request in
            request.messages.count > 2 ? Fixtures.answer() : Fixtures.answer(languages: nil)
        }
        defer { h.env.cleanup() }
        let outcome = try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        #expect(outcome.labels == Fixtures.edpLabels)
        let repair = try #require(await h.mock.chatRequests.last?.messages.last?.content)
        #expect(repair.contains("languages is missing"), "the model is told what was wrong")
        #expect(await h.steps(.analyse).map(\.status) == [.warn], "a repaired answer is flagged in the trace")
    }

    @Test func withoutAValidAnswerTheDocumentWaitsForTheUserUnlabelled() async throws {
        let h = try await ClassifyHarness.make { _ in "I cannot tell." }
        defer { h.env.cleanup() }
        let outcome = try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        #expect(outcome.labels == nil, "nil, not an empty list: the document was not labelled, rather than labelled with nothing")
        #expect(outcome.analysis.problems == ["the model gave no valid answer"] && outcome.analysis.model == nil)
        #expect(outcome.analysis.title == "fatura" && outcome.analysis.fileName == nil && outcome.analysis.documentDate == "2026-07-05",
                "it keeps its own name, with the date the extractor found")
        let steps = await h.steps(.analyse)
        #expect(steps.map(\.status) == [.error] && steps.first?.error?.contains("No valid answer") == true)
    }

    @Test func aDocumentWithNoTextWaitsForTheUser() async throws {
        let h = try await ClassifyHarness.make { _ in Fixtures.answer(subjects: [], objects: [], jurisdictions: [], languages: []) }
        defer { h.env.cleanup() }
        let outcome = try await h.analyse(Fixtures.content("blank.pdf", text: "  \n"))
        #expect(outcome.analysis.problems == ["no text could be read"] && outcome.labels == [])
        #expect(outcome.analysis.fileName == nil, "a document that waits for the user keeps its own name")
    }

    @Test func aModelThatCannotBeReachedIsNoAnswerTheDocumentWaitsForIt() async throws {
        let h = try await ClassifyHarness.make { _ in throw OllamaError.unreachable("connection refused") }
        defer { h.env.cleanup() }
        await #expect(throws: OllamaError.unreachable("connection refused")) {
            try await h.analyse(Fixtures.content("fatura.pdf", text: Fixtures.edpText))
        }
    }
}

@Suite struct CorrespondentResolverTests {
    let config: PipelineConfig
    init() throws { config = try PipelineConfig.bundledDefaults() }

    func resolver(_ list: [Correspondent]) -> CorrespondentResolver {
        CorrespondentResolver(correspondents: list, config: config.analysis, entities: config.entities)
    }

    @Test func learnedIdentifierBeatsName() {
        let edp = Correspondent(id: 1, canonicalName: "EDP", aliases: ["EDP Comercial"], stableKeys: ["ptNIF:503504564"], origin: .learned)
        let other = Correspondent(id: 2, canonicalName: "Galp", origin: .learned)
        let c = Fixtures.content("f.pdf", text: Fixtures.edpText, keys: [Fixtures.edpNIF])
        let matches = resolver([edp, other]).resolve(c)
        #expect(matches.first?.correspondent.id == 1 && matches.first?.matchedBy == .stableKey)
        #expect(!matches.contains { $0.correspondent.id == 2 })
    }

    @Test func namesMatchAcrossScriptsIgnoringLegalForms() {
        let sber = Correspondent(id: 3, canonicalName: "Сбербанк", origin: .learned)
        let c = Fixtures.content("v.pdf", text: "ПАО Сбербанк России. Выписка по счёту", language: "ru")
        #expect(resolver([sber]).resolve(c).first?.matchedBy == .name)
        #expect(resolver([sber]).known("ПАО Сбербанк")?.id == 3)
    }

    @Test func shortNamesNeedExactCase() {
        let nos = Correspondent(id: 4, canonicalName: "NOS", origin: .learned)
        #expect(resolver([nos]).resolve(Fixtures.content("a.pdf", text: "Enviamos para nos todos")).isEmpty)
        #expect(resolver([nos]).resolve(Fixtures.content("a.pdf", text: "Fatura NOS Comunicações")).first?.correspondent.id == 4)
    }
}
