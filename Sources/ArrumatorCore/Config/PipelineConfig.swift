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
    public var settingsLock: SettingsLockConfig

    public var problems: [String] {
        var problems: [String] = []
        if ingest.maxAttempts < 1 { problems.append("ingest.maxAttempts must be at least 1") }
        if !(ingest.modelRecheckSeconds > 0) { problems.append("ingest.modelRecheckSeconds must be more than 0") }
        if !(ingest.abandonedWorkSeconds > 0) { problems.append("ingest.abandonedWorkSeconds must be more than 0") }
        if !(ingest.heldElsewhereRecheckSeconds > 0) { problems.append("ingest.heldElsewhereRecheckSeconds must be more than 0") }
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
        problems += ollama.problems
        problems += watcher.problems
        problems += extraction.problems
        problems += entities.problems
        if database.observationRetry <= 0 { problems.append("database.observationRetry must be more than 0") }
        problems += tasks.problems
        problems += conversation.problems
        problems += limitProblems
        problems += promptRoomProblems
        return problems
    }

    public static func load(paths: AppPaths, environment: RuntimeEnvironment) throws -> PipelineConfig {
        var overrides: [JSONValue] = []
        var files: [URL] = []
        for url in [paths.pipelineOverrideURL] + (environment.pipelineOverridePath.map { [URL(fileURLWithPath: $0)] } ?? []) {
            let value: JSONValue?
            do { value = try ConfigLoader.overrideValue(at: url) } catch {
                throw ConfigError.invalidFile(name: "pipeline", paths: [url.path], underlying: error.localizedDescription, mend: Self.mend)
            }
            guard let value else { continue }
            files.append(url)
            overrides.append(value)
        }
        do {
            return try ConfigLoader.load(PipelineConfig.self, defaults: "pipeline", overrides: overrides)
        } catch let refused as ConfigError {
            throw refused.naming(files, mend: Self.mend)
        }
    }

    /// How a refused `pipeline.json` is mended, as its refusal says.
    static let mend = "Correct the key in that file, or take it out to use the value the app comes with"

    public static func bundledDefaults() throws -> PipelineConfig {
        try ConfigLoader.load(PipelineConfig.self, defaults: "pipeline")
    }
}

public struct OllamaConfig: Sendable, Codable, Hashable {
    /// Seconds a request may take: how long it may wait for more of the answer and, but for a download, how long the
    /// whole answer may take. 0 is no timeout.
    public struct Timeouts: Sendable, Codable, Hashable {
        public var meta: Double
        public var version: Double
        public var chat: Double
        public var embed: Double
        public var pull: Double
        /// Seconds a `.local` name of the server may take to be looked up (`OllamaEndpoint.resolved`), after which it is
        /// taken as not resolving; more than 0, as a lookup with no limit could hold what waits on it for ever.
        public var resolve: Double
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
    /// How many probes for the server's version in a row must time out before a server that was ready is taken to be
    /// away (`OllamaLifecycle.check`): one slow probe of a server busy reading is no server gone. At least 1; a server
    /// not yet seen ready, or one that refuses the connection, is away at its first failed probe.
    public var failedProbesBeforeAway: Int
    public var startTimeout: Double
    public var restartBackoff: NonEmpty<Double>
    public var maxRestartsPerHour: Int
    public var requiredFreeDiskGBAfterPull: Double
    public var keepAlive: KeepAlive
    /// The most bytes one answer of Ollama's may hold: a reply, or every line of an answer it streams together; a line
    /// of a download's progress may hold as many. A server that sends more is refused (`OllamaError.responseTooLarge`).
    public var maxResponseBytes: Int
    /// Seconds what the server said of where a model runs (`ModelLocation`) is trusted before it is asked again; 0 asks
    /// before every request. A model the server is told to run elsewhere meanwhile is sent nothing once this has passed.
    public var modelLocationMaxAge: Double
    /// How many characters of a prompt a token of a model's context is reckoned to hold, which ties a search task's and
    /// a question's prompt, written in characters, to the context it is read in (`num_ctx`, in tokens), so one that would
    /// not fit is cut to fit first (`PromptBudget`). An estimate, not a measurement: it fits text in Latin script and may
    /// not others, and the trace keeps how many tokens Ollama counted and says when the context was full, which fits the
    /// prompt again at what Ollama counted (`refitAttempts`).
    public var charsPerToken: Double
    /// How often a search task's request or a question is fitted again and asked again when Ollama counted its prompt
    /// filling the context beside the answer: fitted at the characters a token Ollama's count shows the prompt held,
    /// as text in another script holds fewer than `charsPerToken` (`PromptBudget.measured`). 0 never asks again.
    public var refitAttempts: Int

    /// How long Ollama keeps a model loaded after its last request (`keep_alive`), so the next document does not wait
    /// for it to load again.
    public struct KeepAlive: Sendable, Codable, Hashable {
        /// The model that reads documents and requests and describes images.
        public var chat: String
        /// The model that makes the vectors search by meaning uses; search asks it at any time.
        public var embed: String
    }
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
    /// Minutes since it was last written after which a record file's staged text (`StagedRecordFile`) is taken for one a
    /// crash left and removed: one younger may be another process's, about to take its record file's place.
    public var stagedLeftoverMinutes: Double
}

public struct IngestConfig: Sendable, Codable, Hashable {
    /// How many times a stage of a job is tried before the job fails; also how many starts a change in the archive that
    /// cannot be applied is tried at before it is given up (`ArchiveReconciler`).
    public var maxAttempts: Int
    /// Seconds before each retry of a failed job, the last one for every retry after; also how long a job waits for
    /// Ollama to come back.
    public var retryDelays: NonEmpty<Double>
    /// Seconds a job whose model is not installed waits before it looks again whether it is, spending no attempt.
    public var modelRecheckSeconds: Double
    /// Seconds a job waits for work a deadline gave up on, which does not notice cancellation, to end before the job
    /// fails rather than being worked on again beside it.
    public var abandonedWorkSeconds: Double
    /// Seconds an idle worker, of the ingest queue or the queues of tasks and questions, waits at most while another
    /// process holds items of its queue, before it looks again whether that process still runs (`IdleWait`).
    public var heldElsewhereRecheckSeconds: Double
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
        /// How wide a gap on a line of a page's text layer is, in times the height of the letters either side of it,
        /// for the text either side to stand apart, as two columns or a table's cells do: a tab between them, not a
        /// space (`PDFPageText`).
        public var columnGap: Double
    }
    public struct Image: Sendable, Codable, Hashable {
        public var ocrMaxPixel: Int
        public var vlmMaxPixel: Int
        public var jpegQuality: Double
        public var sparseChars: Int
        public var sparseWords: Int
        public var lowConfidence: Double
        public var vlmTimeout: Double
        /// Most pixels (width × height) an image may declare to be decoded; a larger one gives its metadata alone.
        public var maxPixels: Int
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
    /// Words a text has fewer of than this is short: a request or a question of a few words, which looks like many
    /// languages, so it is named one only at `languageShortTextMinConfidence` (`LanguageDetector.name(of:)`).
    public var languageShortTextWords: Int
    public var languageShortTextMinConfidence: Double
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
    /// Maximum bytes of an e-mail file read, its parts and their names among them; the rest is left, with a warning.
    public var emailReadCapBytes: Int
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
    /// Most entries a ZIP file (an archive or an Office document) may list; one with more is not opened.
    public var zipMaxEntries: Int
    /// Maximum MIME multipart nesting depth parsed in e-mails.
    public var emailMaxPartDepth: Int
    /// How many messages deep an e-mail with no text of its own is read through the messages it forwards.
    public var emailForwardsRead: Int
    /// Maximum characters of text previews and metadata values written to trace steps.
    public var tracePreviewChars: Int
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
    /// The share of a title's words of `labels.groundingLetters` letters or more the document must write, below which the
    /// answer goes back to the model once, naming those it does not (`AnswerValidator`).
    public var titleGroundedShare: Double
    /// Parties a reading with no sender names before it goes back to the model once, asking who issued the document, as
    /// a contract or a lease that names both its sides as parties and neither as its sender (`AnswerValidator`).
    public var partiesWithoutSender: Int
}

public struct LabelsConfig: Sendable, Codable, Hashable {
    /// Labels of one kind a document keeps at most, the most significant first.
    public var maxPerKind: Int
    /// Longest a label may be; a longer one is cut at a word boundary.
    public var maxValueChars: Int
    /// The letters a word needs to say on its own whether the document writes a name or a title (`ReadingGrounds`): a
    /// name's words this long must each be written in it, initials this long ground a name wherever the document writes
    /// them in capitals, and a title's words this long count toward `analysis.titleGroundedShare`.
    public var groundingLetters: Int
    /// The digits a word of an object needs to identify a thing, as a number, a plate or an address writes it, which a
    /// quantity or a size ("1L", "x6") does not: an object without one goes back to the model once (`AnswerValidator`).
    public var objectIdentifierDigits: Int
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
    /// What a reading's name is made of, in order (`FilenameBuilder.made`): the title, and the date and the sender when
    /// they are listed.
    public var parts: [NamePart]
    /// What follows each part of `parts` but the last, when a part the document has follows it: `separators[i]` after
    /// `parts[i]`.
    public var separators: [String]
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
    /// Words of a request at most between a word the model gives and the list of alternatives a kind's labels quote, for
    /// the word to carry the list on as one more of them, rather than a word every document must hold; 0 is right next
    /// to it. A word written between two of the alternatives is one of them however far (`SearchPlanValidator`).
    public var alternativesGap: Int
    /// Letters at the end of the shorter of two words that may differ while they are one word inflected, as a plural or a
    /// case inflects it ("квитанции" and "квитанция"): what a conversation's request for more documents is told against
    /// the person's question by (`SearchPlanValidator`).
    public var inflectionLetters: Int
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
    /// Seconds the app waits for macOS to answer its asking to show notifications before it says macOS would not let it
    /// ask: macOS may never answer, as for a build not signed for distribution.
    public var notificationAskTimeout: Double
    /// Seconds after starting before the app says whether its menu bar icon can be seen: macOS puts the icon in the
    /// screen's corner first, then where it goes.
    public var menuBarSettleSeconds: Double
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
    /// Seconds before the app watches the index again after watching it failed (`AppDatabase.activity()`,
    /// `pendingRecords()`): its lists, and the writer of the record files, hear of changes again after that.
    public var observationRetry: Double
}

/// How a change of `settings.json` waits for one another process is making (`SettingsLock`).
public struct SettingsLockConfig: Sendable, Codable, Hashable {
    /// Seconds a change waits for another process changing the settings before it fails, saying so.
    public var timeout: Double
    /// Seconds between asking again whether the other process is done.
    public var pollInterval: Double
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
