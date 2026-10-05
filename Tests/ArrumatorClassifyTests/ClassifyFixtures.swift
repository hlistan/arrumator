@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

enum Fixtures {
    static func content(_ name: String, text: String, keys: [StableKey] = [], language: String = "pt",
                        date: String? = "2026-07-05") -> ExtractedContent {
        let source = SourceFile(path: "/tmp/\(name)", originalFilename: name, fileExtension: (name as NSString).pathExtension,
                                utType: "com.adobe.pdf", byteSize: Int64(text.utf8.count), createdAt: nil, modifiedAt: nil,
                                sha256: name)
        let d = date.map { DetectedDate(date: $0, score: 3, source: .label, context: "Data de emissão") }
        return ExtractedContent(source: source, kind: .pdfText, textOrigin: .textLayer, text: text,
                                language: LanguageGuess(primary: language, confidence: 0.99),
                                entities: Entities(dates: d.map { [$0] } ?? [], documentDate: d, stableKeys: keys),
                                extractorName: "fixture")
    }

    static let edpText = """
    EDP Comercial — Fatura de eletricidade
    Data de emissão: 05/07/2026   Período de faturação: 01/06/2026 a 30/06/2026
    NIF 503504564   Cliente: Maria Exemplo   Referência Multibanco 12345 678 901
    Total a pagar: 54,21 €   Data limite de pagamento: 25/07/2026
    """

    /// A model answer reading the document as an EDP electricity bill to Maria Exemplo; the kind `omitting` names is left
    /// out of the answer, `overrides` replaces the signals of a kind, and `title` is what it is.
    /// What `text` grounds a reading in, as the bundled settings tell words apart.
    static func grounds(_ text: String, preferred: [LabelPreference] = []) throws -> ReadingGrounds {
        ReadingGrounds(text: text, letters: try PipelineConfig.bundledDefaults().labels.groundingLetters, preferred: preferred)
    }

    /// What `content` grounds a reading in, as the bundled settings tell words apart.
    static func grounds(_ content: ExtractedContent, guidance: LabelGuidance = .none) throws -> ReadingGrounds {
        ReadingGrounds(content: content, guidance: guidance, letters: try PipelineConfig.bundledDefaults().labels.groundingLetters)
    }

    /// A validator of `labels`, checking a reading against `grounds` as the bundled settings check its title.
    static func validator(_ labels: LabelsConfig, grounds: ReadingGrounds) throws -> AnswerValidator {
        let analysis = try PipelineConfig.bundledDefaults().analysis
        return AnswerValidator(labels: labels, titleGroundedShare: analysis.titleGroundedShare, partiesWithoutSender: analysis.partiesWithoutSender,
                               grounds: grounds)
    }

    static func answer(omitting omitted: LabelKind? = nil, _ overrides: [LabelKind: [String]] = [:],
                       title: String = "Fatura eletricidade julho") throws -> String {
        var fields: [String: JSONValue] = [ClassificationSchema.titleKey: .string(title)]
        for kind in ClassificationSchema.answerOrder where kind != omitted {
            let values = overrides[kind] ?? edpSignals[kind] ?? []
            fields[ClassificationSchema.labelsKey(kind)] = .array(values.map(JSONValue.string))
        }
        return try JSON.string(fields)
    }

    /// What the model finds in the EDP bill, as it writes it.
    static let edpSignals: [LabelKind: [String]] = [
        .sender: ["EDP Comercial"], .party: ["Maria Exemplo"], .type: ["invoice"], .topic: ["utilities", "electricity"],
        .object: ["electricity supply point PT0002000012345678"], .reference: ["invoice FT 2026/926804564"],
        .date: ["05/07/2026"], .period: ["2026-06"], .deadline: ["2026-07-25"], .amount: ["54.21 EUR"],
        .jurisdiction: ["Portugal"], .language: ["pt"],
    ]

    /// What the answer labels the document with, kinds in their order: the EDP bill every suite knows
    /// (`StubAnalyzer.edpBill`), with the broader topic the answer also gives before its own.
    static let edpLabels = StubAnalyzer.edpBill.flatMap { label in
        label == DocumentLabel(kind: .topic, value: "electricity") ? [DocumentLabel(kind: .topic, value: "utilities"), label] : [label]
    }
}

/// The analyzer over an empty temporary archive with a mock Ollama.
struct ClassifyHarness {
    let env: TestEnvironment
    let mock: MockOllama
    let analyzer: DocumentAnalyzer
    let settings: AppSettings
    let sink = MemoryTraceSink()

    /// The profile's chat model, which reads the documents.
    static let chatModel = "ministral-3:14b"

    /// With `thinking`, the chat model can think and says so with those values; without, it cannot think.
    static func make(thinking: OllamaShowResponse.Thinking? = nil, handler: @escaping MockOllama.ChatHandler) async throws -> ClassifyHarness {
        let env = try await TestEnvironment.make()
        let mock = MockOllama(installed: [chatModel, "bge-m3"],
                              modelCapabilities: thinking == nil ? [:] : [chatModel: MockOllama.thinkingCapabilities],
                              modelThinking: thinking.map { [chatModel: $0] } ?? [:], handler: handler)
        let prompts = PromptBuilder(library: try PromptLibrary.bundled(), config: env.config.analysis, labels: env.config.labels,
                                    naming: env.config.naming)
        let analyzer = DocumentAnalyzer(gate: InferenceGate(api: mock, retryDelays: [], time: env.time),
                                        models: ModelManager(api: mock, config: env.config.ollama), prompts: prompts)
        return ClassifyHarness(env: env, mock: mock, analyzer: analyzer, settings: await env.settings.current)
    }

    var trace: TraceContext { TraceContext(traceID: 1, sink: sink) }

    /// Reads `content` under the environment's settings, or under `settings` when given.
    func analyse(_ content: ExtractedContent, guidance: LabelGuidance = .none, settings: AppSettings? = nil) async throws -> AnalysisOutcome {
        try await analyzer.analyse(content, guidance: guidance, settings: settings ?? self.settings, config: env.config, trace: trace)
    }

    func steps(_ stage: TraceStage) async -> [TraceStep] { await sink.steps.filter { $0.stage == stage } }
}

extension TraceStep {
    /// The model calls this step recorded under `TraceStep.exchangeKey`, read back as the trace keeps them.
    func exchange() throws -> [ModelCall] {
        let recorded = try JSON.decoder.decode(JSONValue.self, from: Data(try #require(output, "the step recorded its output").utf8))
        let calls = try #require(recorded[TraceStep.exchangeKey], "a step that asked a model records its calls")
        return try JSON.decoder.decode([ModelCall].self, from: Data(calls.serialized().utf8))
    }
}
