@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation

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

    static func answer(folder: String, newArea: String = "", idealArea: String = "Home", idealCategory: String = "Utilities",
                       idealDescription: String = "Electricity, gas and water bills.", yearly: String = "yes",
                       confidence: Double = 0.93, fileName: String = "2026-07-05 EDP - Fatura eletricidade junho") -> String {
        """
        {"rationale":"EDP electricity invoice","correspondent":"EDP Comercial","document_type":"invoice","document_date":"05/07/2026","period_year":"","language":"pt","title":"Fatura eletricidade junho","tags":["energy","Energy"],"ideal_area":"\(idealArea)","ideal_area_description":"\(idealArea) documents.","ideal_category":"\(idealCategory)","ideal_category_description":"\(idealDescription)","ideal_year_folders":"\(yearly)","folder_code":"\(folder)","new_folder_area_code":"\(newArea)","file_name":"\(fileName)","confidence":\(confidence)}
        """
    }

    /// Picks `code` when the schema allows it, otherwise creates the ideal "Home / Utilities" folder.
    static func answering(code: String?) -> MockOllama.ChatHandler {
        { request in
            let allowed = request.format?["properties"]?["folder_code"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if let code, allowed.contains(code) { return answer(folder: code) }
            return answer(folder: "NEW", newArea: "NEW")
        }
    }
}

/// Classifier and learner over an empty temporary archive with a mock Ollama.
struct ClassifyHarness {
    let env: TestEnvironment
    let mock: MockOllama
    let store: GRDBLearningStore
    let logic: LogicStore
    let memories: MemoryIndex
    let classifier: FilingClassifier
    let learner: Learner
    let settings: AppSettings

    static func make(handler: @escaping MockOllama.ChatHandler) async throws -> ClassifyHarness {
        let env = try await TestEnvironment.make()
        let store = GRDBLearningStore(database: env.database)
        let mock = MockOllama(installed: ["gemma4:latest", "gemma3:4b", "bge-m3"], handler: handler)
        let gate = InferenceGate(api: mock, retryDelays: [])
        let models = ModelManager(api: mock, config: env.config.ollama)
        let library = try PromptLibrary.bundled()
        let prompts = PromptBuilder(library: library, config: env.config.classification, naming: env.config.naming)
        let logic = LogicStore(database: env.database, maxChars: env.config.classification.logicMaxChars)
        try await logic.sync(builtin: try prompts.builtinLogic())
        let memories = MemoryIndex(store: store)
        let classifier = FilingClassifier(store: store, logic: logic, memories: memories, gate: gate, models: models, prompts: prompts)
        let skip = SkipRules(watcher: env.config.watcher, taxonomy: env.config.taxonomy)
        let learner = Learner(store: store, memories: memories, settings: env.settings, config: env.config, taxonomy: env.taxonomy,
                              refresher: DescriptionRefresher(store: store, gate: gate, library: library,
                                                              config: env.config.learning.descriptionRefresh),
                              absorber: FolderAbsorber(store: store, gate: gate, library: library, config: env.config.learning, skip: skip),
                              history: HistoryStore(database: env.database))
        return ClassifyHarness(env: env, mock: mock, store: store, logic: logic, memories: memories, classifier: classifier, learner: learner,
                               settings: await env.settings.current)
    }

    func taxonomy() async throws -> TaxonomySnapshot { try await env.taxonomy.snapshot(root: env.archive) }

    func document(_ name: String, folderID: Int64? = nil, correspondent: String? = nil) async throws -> Int64 {
        var record = DocumentRecord.arrived(path: "/tmp/\(name)", sha256: UUID().uuidString, size: 1, uttype: "com.adobe.pdf",
                                            inode: nil, modified: nil)
        record.folderId = folderID
        record.correspondent = correspondent
        if folderID != nil { record.status = .filed; record.filedAt = Date() }
        return try await DocumentStore(database: env.database).save(record).id ?? 0
    }

    func classify(_ content: ExtractedContent, mode: ClassificationMode = .arrival,
                  trace: TraceContext = .disabled) async throws -> ClassificationOutcome {
        try await classifier.classify(content, taxonomy: try await taxonomy(), settings: settings, config: env.config, mode: mode,
                                      trace: trace)
    }

    /// Files without the user saying anything, the way an uncertain automatic placement happens.
    func fileUnconfirmed(_ content: ExtractedContent, into folder: TaxonomyFolder, band: Band = .check) async throws {
        var outcome = try await classify(content)
        outcome.decision.folderCode = folder.code
        outcome.decision.confidence.band = band
        let docID = try await document(content.source.originalFilename, folderID: folder.id, correspondent: "EDP")
        await learner.documentFiled(documentID: docID, folderID: folder.id, outcome: outcome, content: content,
                                    confirmedByUser: false, trace: .disabled)
    }

    /// Pretends the memories were written some days ago, so settling can be exercised without waiting.
    func ageMemories(byDays days: Int) async throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).unixSeconds
        try await env.database.writer.write { db in
            try db.execute(sql: "UPDATE memories SET created_at = ?", arguments: [cutoff])
        }
    }

    /// Classifies and records the filing as the ingest pipeline would.
    func fileConfirmed(_ content: ExtractedContent, into folder: TaxonomyFolder) async throws {
        var outcome = try await classify(content)
        outcome.decision.folderCode = folder.code
        let docID = try await document(content.source.originalFilename, folderID: folder.id, correspondent: "EDP")
        await learner.documentFiled(documentID: docID, folderID: folder.id, outcome: outcome, content: content,
                                    confirmedByUser: true, trace: .disabled)
    }
}
