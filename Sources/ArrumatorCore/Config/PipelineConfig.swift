import Foundation

/// Every tunable of the pipeline. Values come from bundled `Defaults/pipeline.json`, deep-merged with the user's
/// `pipeline.json` and `ARRUMATOR_PIPELINE_CONFIG`; `ARRUMATOR_OLLAMA_URL` overrides the endpoint.
public struct PipelineConfig: Sendable, Codable, Hashable {
    public var ollama: OllamaConfig
    public var modelProfiles: [String: ModelProfile]
    public var watcher: WatcherConfig
    public var records: RecordsConfig
    public var ingest: IngestConfig
    public var extraction: ExtractionConfig
    public var entities: EntityConfig
    public var analysis: AnalysisConfig
    public var labels: LabelsConfig
    public var senders: SendersConfig
    public var naming: NamingConfig
    public var search: SearchConfig
    public var logging: LoggingConfig
    public var power: PowerConfig
    public var stats: StatsConfig
    public var interface: InterfaceConfig

    public static func load(paths: AppPaths, environment: RuntimeEnvironment = .current) throws -> PipelineConfig {
        var overrides: [JSONValue] = []
        if let user = try ConfigLoader.overrideValue(at: paths.pipelineOverrideURL) { overrides.append(user) }
        if let path = environment.pipelineOverridePath,
           let extra = try ConfigLoader.overrideValue(at: URL(fileURLWithPath: path)) { overrides.append(extra) }
        return try ConfigLoader.load(PipelineConfig.self, defaults: "pipeline", overrides: overrides)
    }

    public static func bundledDefaults() throws -> PipelineConfig {
        try ConfigLoader.load(PipelineConfig.self, defaults: "pipeline")
    }

    /// Resolves the effective model set for the user's selection.
    public func models(for selection: ModelSelection) throws -> ResolvedModels {
        guard let profile = modelProfiles[selection.profile] else {
            throw ConfigError.invalid(name: "pipeline", underlying: "unknown model profile '\(selection.profile)'")
        }
        return ResolvedModels(
            profileName: selection.profile,
            chat: selection.chatModel ?? profile.chatModel,
            vision: selection.visionModel ?? profile.visionModel,
            embed: selection.embedModel ?? profile.embedModel,
            fast: selection.fastModel ?? profile.fastModel,
            numCtx: profile.numCtx, fastNumCtx: profile.fastNumCtx,
            keepAliveChat: profile.keepAliveChat, keepAliveEmbed: profile.keepAliveEmbed,
            residentBudgetGB: profile.residentBudgetGB)
    }
}

public struct ModelProfile: Sendable, Codable, Hashable {
    public var label: String
    public var chatModel: String
    public var visionModel: String
    public var embedModel: String
    public var fastModel: String
    public var numCtx: Int
    public var fastNumCtx: Int
    public var keepAliveChat: String
    public var keepAliveEmbed: String
    public var residentBudgetGB: Double
}

public struct ResolvedModels: Sendable, Codable, Hashable {
    public var profileName: String
    public var chat: String
    public var vision: String
    public var embed: String
    public var fast: String
    public var numCtx: Int
    public var fastNumCtx: Int
    public var keepAliveChat: String
    public var keepAliveEmbed: String
    public var residentBudgetGB: Double

    /// The context images are described with: that of the role the vision model also plays, so Ollama keeps one
    /// loaded model instead of reloading it with another context for every image (a request without one gets the
    /// server's default, which can be far larger).
    public var visionNumCtx: Int { vision != chat && vision == fast ? fastNumCtx : numCtx }
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
    public var serveEnvironment: [String: String]
    public var timeouts: Timeouts
    public var retryDelays: [Double]
    public var healthPollStarting: Double
    public var healthPollSteady: Double
    public var startTimeout: Double
    public var restartBackoff: [Double]
    public var maxRestartsPerHour: Int
    public var requiredFreeDiskGBAfterPull: Double
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
    /// Prefix + extension of app-managed files (`_about.md`, `_INDEX.md`) that are never ingested.
    public var managedFilePrefix: String
    public var managedFileExtension: String
    /// How long the app's own file operations are ignored by the archive watcher (must exceed FSEvents latency).
    public var selfChangeTTLSeconds: Double
}

/// The archive's own files: a `_documents.md` beside the documents of each directory, and the `System` folder
/// holding what the app learned and its history (docs/storage.md). Documents are filed at the top of the archive.
public struct RecordsConfig: Sendable, Codable, Hashable {
    /// In every directory holding documents: one entry per document there.
    public var documentsFileName: String
    /// At the top of the archive; holds the folders below and nothing of the user's.
    public var systemFolderName: String
    /// In the system folder: the senders the app learned.
    public var learnedFolderName: String
    /// In the system folder: the history, one file per month named with the watcher's managed-file prefix.
    public var historyFolderName: String
    public var sendersFileName: String
    /// Added to the name of a database that could not be opened when it is moved aside.
    public var setAsideSuffix: String
}

public struct IngestConfig: Sendable, Codable, Hashable {
    public var maxAttempts: Int
    public var retryDelays: [Double]
    public var watchdogMinutes: Double
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
    public var languages: [String]
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
    public var companySuffixes: [String]
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
    /// How strongly each kind of evidence recognises a known sender.
    public struct CorrespondentStrength: Sendable, Codable, Hashable {
        public var stableKey: Double
        public var domain: Double
        public var alias: Double
    }
    /// Stamped on every trace, so a change to the prompt shows in what it recorded.
    public var promptVersion: Int
    public var excerptChars: Int
    public var embeddingSummaryChars: Int
    public var embeddingNumCtx: Int
    public var correspondentStrength: CorrespondentStrength
    public var correspondentScanChars: Int
    public var llmOptions: LLMOptions
    public var titleMaxChars: Int
    public var vlmNumPredict: Int
    public var promptDatesLimit: Int
    public var promptIdentifiersLimit: Int
    /// Re-asks after an invalid answer before falling back to the other model.
    public var repairAttempts: Int
}

public struct LabelsConfig: Sendable, Codable, Hashable {
    /// Labels of one kind a document keeps at most, the most significant first.
    public var maxPerKind: Int
    /// Longest a label may be; a longer one is cut at a word boundary.
    public var maxValueChars: Int
}

/// Learning who documents come from.
public struct SendersConfig: Sendable, Codable, Hashable {
    /// An identifier becomes a sender's own once it was on this many of the sender's documents and on no one else's.
    public var stableKeyMinFilings: Int
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
    /// BM25 weight of each full-text column, in `SearchService.columns` order: title, correspondent, file name, text,
    /// then one column per `LabelKind`.
    public var bm25Weights: [Double]
    public var snippetTokens: Int
    public var debounceMilliseconds: Int
    public var vectorSnippetChars: Int
}

public struct LoggingConfig: Sendable, Codable, Hashable {
    public var keepDays: Int
    public var maxBytes: Int64
    public var bufferLimit: Int
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
    public var windowsDays: [Int]
    public var diagnosticsTraceLimit: Int
    public var funnel: FunnelConfig
}

/// How much the app and the menu bar list at once.
public struct InterfaceConfig: Sendable, Codable, Hashable {
    /// Documents shown under "Just processed" on the Incoming page.
    public var recentlyProcessed: Int
    /// Rows loaded per page of a long list; "Show more" loads another page.
    public var pageSize: Int
    /// Recently processed documents listed in the menu bar.
    public var menuBarRecent: Int
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
