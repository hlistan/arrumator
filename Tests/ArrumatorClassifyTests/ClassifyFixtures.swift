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
                                sha256: UUID().uuidString)
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
    /// out of the answer, and `overrides` replaces the signals of a kind.
    static func answer(omitting omitted: LabelKind? = nil, _ overrides: [LabelKind: [String]] = [:],
                       fileName: String = "2026-07-05 EDP Comercial - Fatura eletricidade julho") -> String {
        var fields: [String: JSONValue] = ["file_name": .string(fileName)]
        for kind in LabelKind.allCases where kind != omitted {
            let values = overrides[kind] ?? edpSignals[kind] ?? []
            fields[ClassificationSchema.labelsKey(kind)] = .array(values.map(JSONValue.string))
        }
        return JSON.string(fields)
    }

    /// What the model finds in the EDP bill, as it writes it.
    static let edpSignals: [LabelKind: [String]] = [
        .sender: ["EDP Comercial"], .party: ["Maria Exemplo"], .type: ["invoice"], .topic: ["utilities", "electricity"],
        .object: ["electricity supply point PT0002000012345678"], .reference: ["invoice FT 2026/926804564"],
        .date: ["05/07/2026"], .period: ["2026-06"], .deadline: ["2026-07-25"], .amount: ["54.21 EUR"],
        .jurisdiction: ["Portugal"], .language: ["pt"],
    ]

    /// What the answer labels the document with, kinds in their order.
    static let edpLabels = [
        DocumentLabel(kind: .sender, value: "EDP Comercial"), DocumentLabel(kind: .party, value: "Maria Exemplo"),
        DocumentLabel(kind: .type, value: "invoice"), DocumentLabel(kind: .topic, value: "utilities"),
        DocumentLabel(kind: .topic, value: "electricity"),
        DocumentLabel(kind: .object, value: "electricity supply point PT0002000012345678"),
        DocumentLabel(kind: .reference, value: "invoice FT 2026/926804564"), DocumentLabel(kind: .date, value: "2026-07-05"),
        DocumentLabel(kind: .period, value: "2026-06"), DocumentLabel(kind: .deadline, value: "2026-07-25"),
        DocumentLabel(kind: .amount, value: "54.21 EUR"), DocumentLabel(kind: .jurisdiction, value: "Portugal"),
        DocumentLabel(kind: .language, value: "pt"),
    ]
}

/// The analyzer over an empty temporary archive with a mock Ollama.
struct ClassifyHarness {
    let env: TestEnvironment
    let mock: MockOllama
    let analyzer: DocumentAnalyzer
    let settings: AppSettings
    let sink = MemoryTraceSink()

    static func make(handler: @escaping MockOllama.ChatHandler) async throws -> ClassifyHarness {
        let env = try await TestEnvironment.make()
        let mock = MockOllama(installed: ["ministral-3:14b", "bge-m3"], handler: handler)
        let prompts = PromptBuilder(library: try PromptLibrary.bundled(), config: env.config.analysis, labels: env.config.labels,
                                    naming: env.config.naming)
        let analyzer = DocumentAnalyzer(gate: InferenceGate(api: mock, retryDelays: []),
                                        models: ModelManager(api: mock, config: env.config.ollama), prompts: prompts)
        return ClassifyHarness(env: env, mock: mock, analyzer: analyzer, settings: await env.settings.current)
    }

    var trace: TraceContext { TraceContext(traceID: 1, sink: sink) }

    func analyse(_ content: ExtractedContent) async throws -> AnalysisOutcome {
        try await analyzer.analyse(content, settings: settings, config: env.config, trace: trace)
    }

    func steps(_ stage: TraceStage) async -> [TraceStep] { await sink.steps.filter { $0.stage == stage } }
}
