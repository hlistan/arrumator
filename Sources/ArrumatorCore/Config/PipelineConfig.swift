import Foundation

/// Every tunable of the pipeline. Values come from bundled `Defaults/pipeline.json`, deep-merged with the user's
/// `pipeline.json` and `ARRUMATOR_PIPELINE_CONFIG`; `ARRUMATOR_OLLAMA_URL` overrides the endpoint.
public struct PipelineConfig: Sendable, Codable, Hashable, ValidatedConfiguration {
    public var ollama: OllamaConfig
    public var watcher: WatcherConfig
    public var records: RecordsConfig
    public var ingest: IngestConfig
    public var extraction: ExtractionConfig
    public var entities: EntityConfig
    public var analysis: AnalysisConfig
    public var labels: LabelsConfig
    public var naming: NamingConfig
    public var search: SearchConfig
    public var tasks: TasksConfig
    public var conversation: ConversationConfig
    public var logging: LoggingConfig
    public var power: PowerConfig
    public var stats: StatsConfig
    public var interface: InterfaceConfig
    public var maintenance: MaintenanceConfig
    public var database: DatabaseConfig

    public var problems: [String] {
        var problems: [String] = []
        if ingest.maxAttempts < 1 { problems.append("ingest.maxAttempts must be at least 1") }
        if analysis.repairAttempts < 0 { problems.append("analysis.repairAttempts cannot be negative") }
        if analysis.excerptTailDivisor < 2 { problems.append("analysis.excerptTailDivisor must be at least 2, so the head keeps the most") }
        if labels.maxPerKind < 1 { problems.append("labels.maxPerKind must be at least 1") }
        if !stats.windowsDays.all.contains(stats.defaultWindowDays) {
            problems.append("stats.defaultWindowDays must be one of stats.windowsDays")
        }
        if search.bm25Weights.count != SearchService.columns.count {
            problems.append("search.bm25Weights needs one weight for each of the \(SearchService.columns.count) full-text columns")
        }
        // The user's own labels are never merged unasked nor shown to the model, however the configuration is written.
        for kind in labels.vocabulary.kinds.keys where kind.isUsersOwn {
            problems.append("labels.vocabulary.kinds.\(kind.rawValue): the user's own labels are never kept one vocabulary; remove it")
        }
        problems += tasks.problems
        problems += conversation.problems
        return problems
    }

    public static func load(paths: AppPaths, environment: RuntimeEnvironment) throws -> PipelineConfig {
        var overrides: [JSONValue] = []
        if let user = try ConfigLoader.overrideValue(at: paths.pipelineOverrideURL) { overrides.append(user) }
        if let path = environment.pipelineOverridePath,
           let extra = try ConfigLoader.overrideValue(at: URL(fileURLWithPath: path)) { overrides.append(extra) }
        return try ConfigLoader.load(PipelineConfig.self, defaults: "pipeline", overrides: overrides)
    }

    public static func bundledDefaults() throws -> PipelineConfig {
        try ConfigLoader.load(PipelineConfig.self, defaults: "pipeline")
    }
}

public struct OllamaConfig: Sendable, Codable, Hashable {
    public struct Timeouts: Sendable, Codable, Hashable {
        public var meta: Double
        public var version: Double
        public var chat: Double
        public var embed: Double
        /// 0 = no timeout.
        public var pull: Double
    }
    public var appBundleIdentifier: String
    public var appBinarySubpath: String
    public var binarySearchPaths: [String]
    /// Variables `ollama serve` is started with besides `OLLAMA_HOST`, which is the address the app talks to.
    public var serveEnvironment: [String: String]
    public var timeouts: Timeouts
    public var retryDelays: [Double]
    public var healthPollStarting: Double
    public var healthPollSteady: Double
    public var startTimeout: Double
    public var restartBackoff: NonEmpty<Double>
    public var maxRestartsPerHour: Int
    public var requiredFreeDiskGBAfterPull: Double
    public var keepAlive: KeepAlive

    /// How long Ollama keeps a model loaded after its last request (`keep_alive`), so the next document does not wait
    /// for it to load again.
    public struct KeepAlive: Sendable, Codable, Hashable {
        /// The model that reads documents and requests and describes images.
        public var chat: String
        /// The model that makes the vectors search by meaning uses; search asks it at any time.
        public var embed: String
    }
}

public struct WatcherConfig: Sendable, Codable, Hashable {
    public var fsEventsLatency: Double
    public var stabilityPollInterval: Double
    public var stabilityRequiredPolls: Int
    public var zeroByteWaitSeconds: Double
    public var ignoredNamePrefixes: [String]
    public var ignoredNames: [String]
    public var ignoredExtensions: [String]
    public var ignoredNameSubstrings: [String]
    /// Prefix + extension of the archive's record files (`_documents.md`, `_labels.md`, history files), and of those
    /// earlier versions left, which are never read as documents.
    public var managedFilePrefix: String
    public var managedFileExtension: String
    /// How long the app's own file operations are ignored by the archive watcher (must exceed FSEvents latency).
    public var selfChangeTTLSeconds: Double
}

/// The archive's own files: a `_documents.md` beside the documents of each directory, and the `System` folder
/// holding its history and the user's rules for labels (docs/storage.md). Documents are filed at the top of the archive.
public struct RecordsConfig: Sendable, Codable, Hashable {
    /// In every directory holding documents: one entry per document there.
    public var documentsFileName: String
    /// At the top of the archive; holds the history and nothing of the user's.
    public var systemFolderName: String
    /// In the system folder: the history, one file per month named with the watcher's managed-file prefix.
    public var historyFolderName: String
    /// In the system folder, named with the watcher's managed-file prefix: the user's rules for labels.
    public var labelRulesFileName: String
    /// In the system folder, named with the watcher's managed-file prefix: the user's search tasks and their exports.
    public var searchTasksFileName: String
    /// In the system folder: the conversations about search tasks' documents, one file per task named with the
    /// watcher's managed-file prefix and the task's number.
    public var conversationsFolderName: String
    /// Added to the name of a database that could not be opened when it is moved aside.
    public var setAsideSuffix: String
}

public struct IngestConfig: Sendable, Codable, Hashable {
    public var maxAttempts: Int
    /// Seconds before each retry of a failed job, the last one for every retry after; also how long a job waits for
    /// Ollama to come back.
    public var retryDelays: NonEmpty<Double>
    /// Seconds the app, when it quits, waits for its work to stop, so the document in hand and the request being read
    /// stop where they carry on at the next start. A stop that takes longer goes on while the app quits.
    public var quitTimeout: Double
}

public struct ExtractionConfig: Sendable, Codable, Hashable {
    public struct PDF: Sendable, Codable, Hashable {
        public var textLayerHeadPages: Int
        public var textLayerTailPages: Int
        public var ocrHeadPages: Int
        public var ocrAllIfAtMost: Int
        public var ocrDPI: Double
        public var ocrDPILargePage: Double
        public var ocrDPISmallPage: Double
        /// Page area in pt² above which the large-page DPI applies (≈ A3).
        public var largePageArea: Double
        /// Page area in pt² below which the small-page DPI applies (≈ A6).
        public var smallPageArea: Double
        public var minPageChars: Int
        public var minLetterShare: Double
        public var maxReplacementShare: Double
        public var imagePageMaxChars: Int
        public var orientationRetryBelowConfidence: Double
        public var ocrPageTimeout: Double
        /// Share of the page area one image must cover for a low-text page to count as scanned.
        public var fullPageImageCoverage: Double
        /// Longest rendered side in pixels for page OCR, whatever the DPI (guards against huge media boxes).
        public var ocrMaxPixel: Int
    }
    public struct Image: Sendable, Codable, Hashable {
        public var ocrMaxPixel: Int
        public var vlmMaxPixel: Int
        public var jpegQuality: Double
        public var sparseChars: Int
        public var sparseWords: Int
        public var lowConfidence: Double
        public var vlmTimeout: Double
    }
    public struct OCR: Sendable, Codable, Hashable {
        public var lowConfidenceLine: Double
        /// Mean OCR confidence below which the document gets an `ocrLowConfidence` warning.
        public var lowConfidenceWarning: Double
        /// Contrast multiplier applied to grayscale page renders before OCR (1 = unchanged).
        public var contrast: Double
    }
    public struct XLSX: Sendable, Codable, Hashable {
        public var maxSheets: Int
        public var maxRows: Int
        public var maxColumns: Int
    }
    /// Languages text recognition is told to expect first, in this order. They are hints, not a limit: a document's
    /// own language, as detected, goes ahead of them, and Vision detects any other it can read.
    public var ocrLanguages: [String]
    public var languageSampleChars: Int
    public var languageMinConfidence: Double
    public var maxIndexChars: Int
    public var largeFileBytes: Int64
    public var perFileTimeout: Double
    public var toolTimeout: Double
    public var toolOutputCapBytes: Int
    public var plainTextReadCapBytes: Int
    public var pdf: PDF
    public var image: Image
    public var ocr: OCR
    public var csvMaxRows: Int
    public var xlsx: XLSX
    public var pptxMaxSlides: Int
    public var archiveMaxEntries: Int
    public var emailBodyCapBytes: Int
    public var quickLookPixel: Int
    public var tableSnippetChars: Int
    public var maxTables: Int
    public var candidateEncodings: [String]
    /// Minimum Russian plausibility (common-bigram hits minus in-word case flips, per visible character) for a Cyrillic
    /// single-byte decoding to override the detected encoding.
    public var cyrillicBigramMinShare: Double
    /// Seconds between SIGTERM and SIGKILL when an external tool times out.
    public var toolKillGrace: Double
    /// Maximum decompressed bytes read from one ZIP entry (OOXML parts).
    public var zipEntryCapBytes: Int
    /// Maximum MIME multipart nesting depth parsed in e-mails.
    public var emailMaxPartDepth: Int
    /// Maximum characters of text previews and metadata values written to trace steps.
    public var tracePreviewChars: Int
}

public struct EntityConfig: Sendable, Codable, Hashable {
    public struct Scores: Sendable, Codable, Hashable {
        public var label: Double
        public var firstPortion: Double
        public var plausibleYear: Double
        public var dueLabel: Double
        public var birthLabel: Double
        public var crowdedLine: Double
        public var matchesMetadata: Double
    }
    public var dateLabels: [String]
    public var dueLabels: [String]
    public var birthLabels: [String]
    public var labelWindowChars: Int
    public var yearsBack: Int
    public var yearsForward: Int
    public var scores: Scores
    public var firstPortionShare: Double
    /// Number of dates on one line from which the line counts as crowded (tables, statements).
    public var crowdedLineDates: Int
    /// Minimum score for a date found in the text to be chosen over metadata dates.
    public var minTextDateScore: Double
}

/// Reading a document with the local model: what it sees of it, how it is asked, and what its answer may be.
public struct AnalysisConfig: Sendable, Codable, Hashable {
    public struct LLMOptions: Sendable, Codable, Hashable {
        public var temperature: Double
        public var topK: Int
        public var topP: Double
        public var numPredict: Int
        public var seed: Int
    }
    /// Stamped on every trace, so a change to the prompt shows in what it recorded.
    public var promptVersion: Int
    public var excerptChars: Int
    /// The end of the document gets `1 / excerptTailDivisor` of `excerptChars`: totals and signatures are there.
    public var excerptTailDivisor: Int
    public var embeddingSummaryChars: Int
    /// Identifiers the text a document's embedding is made from lists, the first found first.
    public var embeddingIdentifiersLimit: Int
    public var embeddingNumCtx: Int
    /// The context a document, a search task's request and an image are read with: one context, so a model that reads
    /// and describes images stays loaded once. Ollama loads a model again for a request with another context, and gives
    /// one without the server's default, which can be far larger (docs/evaluation.md).
    public var numCtx: Int
    public var llmOptions: LLMOptions
    /// What a model that can think is told about thinking before it reads a document or describes an image: off, on or a
    /// level it names, sent as the model allows (`OllamaShowResponse.think(sending:)`). Both are done without: the
    /// answer's schema already orders the facts before the name, and thinking multiplies the time a document takes.
    public var think: OllamaThink
    public var vlmNumPredict: Int
    public var promptDatesLimit: Int
    public var promptIdentifiersLimit: Int
    /// Times an invalid answer goes back to the model, with what was wrong, before the document waits for the user.
    public var repairAttempts: Int
}

public struct LabelsConfig: Sendable, Codable, Hashable {
    /// Labels of one kind a document keeps at most, the most significant first.
    public var maxPerKind: Int
    /// Longest a label may be; a longer one is cut at a word boundary.
    public var maxValueChars: Int
    public var vocabulary: LabelVocabularyConfig
}

/// Keeping the archive's labels one vocabulary: what the model is shown of it, and which labels are one.
public struct LabelVocabularyConfig: Sendable, Codable, Hashable {
    /// The kinds kept consistent across the archive, and how. A kind whose values have one form (a type, a date, a period,
    /// a deadline, an amount, a language) needs no entry.
    public var kinds: [LabelKind: KindVocabularyConfig]
    /// Labels the user merged into others that the model is shown, newest first.
    public var promptPreferred: Int
    /// Labels the user does not want that the model is shown, newest first.
    public var promptUnwanted: Int
    /// Pairs of alike labels offered to the user at once, the most alike first.
    public var suggestionLimit: Int
}

public struct KindVocabularyConfig: Sendable, Codable, Hashable {
    /// `LabelSimilarity` from which a label the model gives becomes the archive's label: 1 only when written the same way.
    public var mergeSimilarity: Double
    /// `LabelSimilarity` from which two labels in use are offered to the user to merge.
    public var suggestSimilarity: Double
    /// Labels of the kind in use that the model is shown, the most used first; 0 shows none.
    public var promptLimit: Int
}

public struct NamingConfig: Sendable, Codable, Hashable {
    public var maxChars: Int
    public var maxBytes: Int
    public var forbiddenCharacters: [String]
    /// `String(format:)` pattern appended before the extension on collisions, e.g. `" (%d)"`.
    public var collisionFormat: String
}

public struct SearchConfig: Sendable, Codable, Hashable {
    public var rrfK: Double
    public var ftsCandidateLimit: Int
    public var resultLimit: Int
    public var minSemanticQueryChars: Int
    /// Cosine similarity a document needs to be found by meaning alone, without containing the query's words.
    public var semanticMinSimilarity: Double
    public var queryCacheSize: Int
    /// BM25 weight of each full-text column, in `SearchService.columns` order: file name, text, then one column per
    /// `LabelKind`, the user's tags last.
    public var bm25Weights: [Double]
    public var snippetTokens: Int
    public var debounceMilliseconds: Int
    public var vectorSnippetChars: Int
}

/// Search tasks: how the model is asked to read what a person asks for, how much a task finds, and how what it found is
/// exported (docs/how-it-works.md#search-tasks).
public struct TasksConfig: Sendable, Codable, Hashable {
    /// Stamped on every task's trace, so a change to the prompt shows in what it recorded.
    public var promptVersion: Int
    /// How much the model thinks before it answers a request at each effort, with the budget thinking needs
    /// (`EffortPreset`): every `TaskEffort` has one.
    public var efforts: [TaskEffort: EffortPreset]
    /// Labels of one kind a plan asks for at most.
    public var maxValuesPerKind: Int
    /// Words a plan asks the text for at most.
    public var maxWords: Int
    /// Kinds a set is arranged by at most: the depth of an export's folders.
    public var maxGroupingDepth: Int
    /// Longest a task's name from the model may be; a longer one is cut at a word boundary.
    public var maxTitleChars: Int
    /// What a set is arranged by when neither the user nor the prompt says.
    public var defaultGrouping: [LabelKind]
    /// Documents a task finds at most: the newest by their own date (`DocumentOrder.documentDate`).
    public var maxDocuments: Int
    /// The name of an export's folder for the documents without a label of the kind its level is arranged by;
    /// `{{kind}}` is the kind.
    public var withoutLabelFolder: String

    /// The placeholder `withoutLabelFolder` names the kind with.
    public static let kindPlaceholder = "kind"

    /// The folder of the documents without a label of `kind`.
    public func withoutLabelFolder(_ kind: LabelKind) throws -> String {
        try PromptTemplates.fill(withoutLabelFolder, [Self.kindPlaceholder: kind.rawValue], name: "tasks.withoutLabelFolder")
    }

    /// How much the model thinks before it answers a request at `effort`, with the budget thinking needs.
    public func preset(_ effort: TaskEffort) throws -> EffortPreset {
        guard let preset = efforts[effort] else {
            throw ConfigError.invalid(name: "pipeline", underlying: "tasks.efforts.\(effort.rawValue) is missing")
        }
        return preset
    }

    var problems: [String] {
        var problems: [String] = []
        for effort in TaskEffort.allCases {
            guard let preset = efforts[effort] else {
                problems.append("tasks.efforts.\(effort.rawValue) is missing")
                continue
            }
            if preset.repairAttempts < 0 { problems.append("tasks.efforts.\(effort.rawValue).repairAttempts cannot be negative") }
            if preset.numPredict < 1 { problems.append("tasks.efforts.\(effort.rawValue).numPredict must be at least 1") }
            if preset.timeout <= 0 { problems.append("tasks.efforts.\(effort.rawValue).timeout must be more than 0") }
            for kind in preset.promptLabels.keys where kind.isUsersOwn {
                problems.append("tasks.efforts.\(effort.rawValue).promptLabels.\(kind.rawValue): the model is never shown the user's own labels; remove it")
            }
        }
        if maxValuesPerKind < 1 { problems.append("tasks.maxValuesPerKind must be at least 1") }
        if maxWords < 0 { problems.append("tasks.maxWords cannot be negative") }
        if maxGroupingDepth < 1 { problems.append("tasks.maxGroupingDepth must be at least 1") }
        if defaultGrouping.count > maxGroupingDepth { problems.append("tasks.defaultGrouping is deeper than tasks.maxGroupingDepth") }
        if maxTitleChars < 1 { problems.append("tasks.maxTitleChars must be at least 1") }
        if maxDocuments < 1 { problems.append("tasks.maxDocuments must be at least 1") }
        do { _ = try withoutLabelFolder(.sender) } catch {
            problems.append("tasks.withoutLabelFolder: \(error.localizedDescription)")
        }
        return problems
    }
}

/// How much the model thinks before it answers a search task's request (`TaskEffort`), with the budget thinking needs:
/// what it is told about thinking, how long an answer may be and take, how often a wrong answer goes back to it, and how
/// much of the archive's vocabulary it is shown. Which model reads is the profile's. More of each reads a request more
/// carefully and takes longer: answers improve with the computation spent on them at inference, by thinking first and by
/// being asked again (Snell et al., "Scaling LLM Test-Time Compute Optimally", 2024; Madaan et al., "Self-Refine", 2023;
/// docs/organizing-principles-sources.md#sources-for-search-tasks).
///
/// The bundled presets: Low does not think and reads at once, as every request was read before efforts thought, with one
/// repair and the answer length and time documents get. Medium and High think, and a model that thinks spends thousands
/// of tokens on it before it writes its answer: measured live with #11, `qwen3.5:9b` spent all of 4,096 thinking and
/// answered nothing, and answered with 8,192 in about 300 s against 61 s without thinking, so both get that budget; High
/// sends a wrong answer back once more. A model with thinking levels (gpt-oss: low, medium, high) is told the effort's,
/// one that only switches thinking on and off thinks the same at Medium and High, and one that cannot think is told
/// nothing, so for it the efforts differ by repairs and by how much of the vocabulary it is shown
/// (`OllamaShowResponse.think(sending:)`; Ollama, "Thinking", https://docs.ollama.com/capabilities/thinking).
public struct EffortPreset: Sendable, Codable, Hashable {
    /// What a model that can think is told about thinking before it answers: off, on or a level it names, sent as the
    /// model allows (`OllamaShowResponse.think(sending:)`).
    public var think: OllamaThink
    /// Times an invalid answer goes back to the model, with what was wrong, before the task says it could not be read.
    public var repairAttempts: Int
    /// Tokens an answer may take, its thinking included.
    public var numPredict: Int
    /// Seconds one answer may take, in place of `ollama.timeouts.chat`: thinking takes longer.
    public var timeout: Double
    /// Labels of each kind in use the model is shown, the most used first, so it asks for them as the archive writes
    /// them; a kind not listed is shown none.
    public var promptLabels: [LabelKind: Int]

    /// Sampling as documents are read, with this effort's length of answer.
    public func options(over base: AnalysisConfig.LLMOptions) -> AnalysisConfig.LLMOptions {
        var options = base
        options.numPredict = numPredict
        return options
    }
}

/// How the model answers what is asked about a search task's documents (docs/how-it-works.md#talking-with-a-tasks-documents):
/// the context it answers in, how much of the set and of the conversation so far it is shown there, how it writes, and
/// how much it thinks at the task's effort. Which model answers is the task's profile's.
///
/// What it is shown is retrieved, as retrieval-augmented generation does (Lewis et al., "Retrieval-Augmented Generation
/// for Knowledge-Intensive NLP Tasks", NeurIPS 2020): of a set larger than the context holds, the text of the documents
/// most relevant to the question, and the rest by name; a long context is also used worst in its middle (Liu et al.,
/// "Lost in the Middle", TACL 2024), so it is kept to what the question needs
/// (docs/organizing-principles-sources.md#sources-for-conversations).
public struct ConversationConfig: Sendable, Codable, Hashable {
    /// Stamped on every answer's trace, so a change to the prompt shows in what it recorded.
    public var promptVersion: Int
    /// The context an answer is asked in (`num_ctx`): the documents' text, the conversation so far, the question and the
    /// answer, its thinking included, must fit in it, or Ollama drops the start of the prompt. A context other than
    /// `analysis.numCtx` has Ollama load the model again whenever it goes from reading documents to answering.
    public var numCtx: Int
    /// Characters of the set's text an answer is shown at most, the documents the question concerns most first.
    public var contextChars: Int
    /// Characters of one document's text shown at most: its start and its end, as a document is read
    /// (`analysis.excerptTailDivisor`).
    public var documentChars: Int
    /// Documents shown by their name, date and labels alone, those whose text does not fit, at most.
    public var maxListed: Int
    /// Characters of the conversation so far shown with a question, the latest exchanges kept.
    public var historyChars: Int
    /// Longest a question may be.
    public var maxQuestionChars: Int
    /// Documents outside the set an answer suggests at most, when it was asked to find more.
    public var maxSuggested: Int
    /// How an answer is sampled. Writing is not reading: greedy decoding, which reads documents the same each time,
    /// repeats itself over a long text (Holtzman et al., "The Curious Case of Neural Text Degeneration", ICLR 2020).
    public var sampling: Sampling
    /// How much the model thinks before it answers at each effort, with the budget that needs: every `TaskEffort` has one.
    public var efforts: [TaskEffort: Effort]

    public struct Sampling: Sendable, Codable, Hashable {
        public var temperature: Double
        public var topK: Int
        public var topP: Double
        public var seed: Int
    }

    /// What the model is told about thinking at an effort, sent as the model allows (`OllamaShowResponse.think(sending:)`),
    /// how often an answer that cannot be read goes back to it, how long an answer may be, its thinking included, and how
    /// many seconds it may take, in place of `ollama.timeouts.chat`.
    public struct Effort: Sendable, Codable, Hashable {
        public var think: OllamaThink
        public var repairAttempts: Int
        public var numPredict: Int
        public var timeout: Double
    }

    /// How the model answers at `effort`.
    public func effort(_ effort: TaskEffort) throws -> Effort {
        guard let preset = efforts[effort] else {
            throw ConfigError.invalid(name: "pipeline", underlying: "conversation.efforts.\(effort.rawValue) is missing")
        }
        return preset
    }

    /// The sampling an answer is asked with at `effort`, with the length it may take.
    public func options(_ effort: Effort) -> AnalysisConfig.LLMOptions {
        AnalysisConfig.LLMOptions(temperature: sampling.temperature, topK: sampling.topK, topP: sampling.topP,
                                  numPredict: effort.numPredict, seed: sampling.seed)
    }

    var problems: [String] {
        var problems: [String] = []
        for effort in TaskEffort.allCases {
            guard let preset = efforts[effort] else {
                problems.append("conversation.efforts.\(effort.rawValue) is missing")
                continue
            }
            if preset.repairAttempts < 0 { problems.append("conversation.efforts.\(effort.rawValue).repairAttempts cannot be negative") }
            if preset.numPredict < 1 { problems.append("conversation.efforts.\(effort.rawValue).numPredict must be at least 1") }
            if preset.numPredict >= numCtx { problems.append("conversation.efforts.\(effort.rawValue).numPredict leaves no room in conversation.numCtx") }
            if preset.timeout <= 0 { problems.append("conversation.efforts.\(effort.rawValue).timeout must be more than 0") }
        }
        if contextChars < 1 { problems.append("conversation.contextChars must be at least 1") }
        if documentChars < 1 { problems.append("conversation.documentChars must be at least 1") }
        if maxListed < 0 { problems.append("conversation.maxListed cannot be negative") }
        if historyChars < 0 { problems.append("conversation.historyChars cannot be negative") }
        if maxQuestionChars < 1 { problems.append("conversation.maxQuestionChars must be at least 1") }
        if maxSuggested < 1 { problems.append("conversation.maxSuggested must be at least 1") }
        return problems
    }
}

public struct LoggingConfig: Sendable, Codable, Hashable {
    public var keepDays: Int
    public var maxBytes: Int64
    public var bufferLimit: Int
    /// Seconds between looks for new lines while `arrumatorcli logs --follow` runs.
    public var followInterval: Double
}

public enum ThermalLevel: String, Sendable, Codable, Hashable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public struct PowerConfig: Sendable, Codable, Hashable {
    public var pauseBelowBatteryPercent: Int
    public var pauseAtThermalState: ThermalLevel
    public var recheckSeconds: Double
}

public struct StatsConfig: Sendable, Codable, Hashable {
    /// The periods, in days, Statistics offers to look back over.
    public var windowsDays: NonEmpty<Int>
    /// The period Statistics and `arrumatorcli funnel` show unless told otherwise; one of `windowsDays`.
    public var defaultWindowDays: Int
    public var diagnosticsTraceLimit: Int
    public var funnel: FunnelConfig
}

/// How much the app and the menu bar list at once.
public struct InterfaceConfig: Sendable, Codable, Hashable {
    /// Documents shown under "Just processed" on the Incoming page.
    public var recentlyProcessed: Int
    /// Rows loaded per page of a long list; "Show more" loads another page.
    public var pageSize: Int
    /// Labels of each kind the sidebar lists, the most used first, before "Show More" lists the rest.
    public var sidebarLabelsPerKind: Int
    /// Labels the sidebar lists in one list, when they are not grouped by kind, the most used first, before "Show More"
    /// lists the rest.
    public var sidebarLabels: Int
    /// Recently processed documents listed in the menu bar.
    public var menuBarRecent: Int
    /// The latest filings, and documents waiting for the user, looked at for notifications each time the history grows.
    public var notificationEvents: Int
    /// Characters of a file's text `arrumatorcli extract` prints.
    public var extractPreviewChars: Int
}

/// The app's housekeeping: pruning logs, trimming model exchanges from old traces, writing record files a change marked,
/// and looking for jobs another process queued.
public struct MaintenanceConfig: Sendable, Codable, Hashable {
    /// Seconds between rounds.
    public var interval: Double
}

/// The archive's index (docs/storage.md).
public struct DatabaseConfig: Sendable, Codable, Hashable {
    /// Seconds a write waits for another process holding the index, the app or `arrumatorcli`, before it fails.
    public var busyTimeout: Double
}

/// One step of the processing funnel: the trace stages it covers, and how it is described to the user.
public struct FunnelStepConfig: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var stages: [TraceStage]
    /// Log categories whose lines say something about this step, for the diagnostics view.
    public var logCategories: [LogCategory]
    /// Job states that mean a document is inside this step right now.
    public var jobStates: [JobState]
}

public struct FunnelConfig: Sendable, Codable, Hashable {
    /// Below this many documents in the window, percentages are noise, so only counts are shown.
    public var minimumForShares: Int
    public var steps: [FunnelStepConfig]
}

extension PipelineConfig {
    /// What extraction is given for a file under `settings`: its tunables, and the vision model of the profile in use when
    /// images may be described. The ingest pipeline and `arrumatorcli ingest --dry-run` extract alike with it.
    public func extractionContext(settings: AppSettings) throws -> ExtractionContext {
        ExtractionContext(config: extraction, entities: entities, vision: settings.enableVLM ? try visionOptions(settings: settings) : nil)
    }

    /// Images are described with the context and keep-alive documents are read with (`analysis.numCtx`,
    /// `ollama.keepAlive.chat`): a profile that reads and describes images with one model keeps it loaded once, rather
    /// than Ollama loading it again with another context for every image. The model thinks as it does reading a
    /// document (`analysis.think`).
    private func visionOptions(settings: AppSettings) throws -> VisionModelOptions {
        VisionModelOptions(model: try settings.modelProfile().visionModel, keepAlive: ollama.keepAlive.chat,
                           numPredict: analysis.vlmNumPredict, numCtx: analysis.numCtx, options: analysis.llmOptions,
                           think: analysis.think)
    }
}
