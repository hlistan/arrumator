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

    static let edpNIF = StableKey(kind: .ptNIF, value: "503504564")

    /// A model answer reading the document as an EDP bill to Maria Exemplo, with its signals; a list passed as nil is
    /// left out of the answer.
    static func answer(correspondent: String = "EDP Comercial", subjects: [String]? = ["Maria Exemplo"],
                       objects: [String]? = ["electricity supply point PT0002000012345678"], jurisdictions: [String]? = ["Portugal"],
                       languages: [String]? = ["pt"], fileName: String = "2026-07-05 EDP Comercial - Fatura eletricidade julho") -> String {
        var fields: [String: JSONValue] = [
            "correspondent": .string(correspondent), "document_type": "invoice", "document_date": "05/07/2026", "period_year": "",
            "title": "Fatura eletricidade julho", "file_name": .string(fileName),
        ]
        for (key, values) in [("subjects", subjects), ("objects", objects), ("jurisdictions", jurisdictions), ("languages", languages)] {
            if let values { fields[key] = .array(values.map(JSONValue.string)) }
        }
        return JSON.string(fields)
    }

    /// What the answer labels the document with.
    static let edpLabels = [
        DocumentLabel(kind: .subject, value: "Maria Exemplo"),
        DocumentLabel(kind: .object, value: "electricity supply point PT0002000012345678"),
        DocumentLabel(kind: .jurisdiction, value: "Portugal"),
        DocumentLabel(kind: .language, value: "pt"),
    ]
}

/// The analyzer and the sender learner over an empty temporary archive with a mock Ollama.
struct ClassifyHarness {
    let env: TestEnvironment
    let mock: MockOllama
    let senders: SenderStore
    let analyzer: DocumentAnalyzer
    let learner: SenderLearner
    let settings: AppSettings
    let sink = MemoryTraceSink()

    static func make(handler: @escaping MockOllama.ChatHandler) async throws -> ClassifyHarness {
        let env = try await TestEnvironment.make()
        let senders = SenderStore(database: env.database)
        let mock = MockOllama(installed: ["ministral-3:14b", "bge-m3"], handler: handler)
        let prompts = PromptBuilder(library: try PromptLibrary.bundled(), config: env.config.analysis, labels: env.config.labels,
                                    naming: env.config.naming)
        let analyzer = DocumentAnalyzer(senders: senders, gate: InferenceGate(api: mock, retryDelays: []),
                                        models: ModelManager(api: mock, config: env.config.ollama), prompts: prompts)
        let learner = SenderLearner(store: senders, config: env.config.senders, history: HistoryStore(database: env.database))
        return ClassifyHarness(env: env, mock: mock, senders: senders, analyzer: analyzer, learner: learner,
                               settings: await env.settings.current)
    }

    var trace: TraceContext { TraceContext(traceID: 1, sink: sink) }

    func analyse(_ content: ExtractedContent) async throws -> AnalysisOutcome {
        try await analyzer.analyse(content, settings: settings, config: env.config, trace: trace)
    }

    /// Reads the document and files it, as the pipeline does: stored with its content, then learned from.
    @discardableResult
    func file(_ content: ExtractedContent) async throws -> (id: Int64, analysis: DocumentAnalysis) {
        let analysis = try await analyse(content).analysis
        var record = DocumentRecord.arrived(path: content.source.path, sha256: content.source.sha256, size: 1, uttype: "com.adobe.pdf",
                                            inode: nil, modified: nil)
        record.status = .filed
        record.filedAt = Date()
        record.correspondent = analysis.correspondent
        record.correspondentId = analysis.correspondentID
        record.contentJson = DocumentStore.storedContentJSON(content)
        record.analysisJson = JSON.string(analysis)
        let id = try #require(try await DocumentStore(database: env.database).save(record).id)
        await learner.documentFiled(documentID: id, analysis: analysis, content: content, trace: .disabled)
        return (id, analysis)
    }

    func steps(_ stage: TraceStage) async -> [TraceStep] { await sink.steps.filter { $0.stage == stage } }
}
