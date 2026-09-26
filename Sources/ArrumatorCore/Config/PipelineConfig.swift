import Foundation

/// Every tunable of the pipeline. Values come from bundled `Defaults/pipeline.json`, deep-merged with the user's
/// `pipeline.json` and `ARRUMATOR_PIPELINE_CONFIG`; `ARRUMATOR_OLLAMA_URL` overrides the endpoint.
public struct PipelineConfig: Sendable, Codable, Hashable {
    public var ollama: OllamaConfig
    public var modelProfiles: [String: ModelProfile]
    public var watcher: WatcherConfig
    public var taxonomy: TaxonomyConfig
    public var records: RecordsConfig
    public var ingest: IngestConfig
    public var extraction: ExtractionConfig
    public var entities: EntityConfig
    public var classification: ClassificationConfig
    public var calibration: CalibrationConfig
    public var learning: LearningConfig
    public var naming: NamingConfig
    public var search: SearchConfig
    public var logging: LoggingConfig
    public var power: PowerConfig
    public var stats: StatsConfig
    public var interface: InterfaceConfig
    public var rethink: RethinkConfig

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

    public var all: [String] { Array(Set([chat, vision, embed, fast])).sorted() }

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

public struct TaxonomyConfig: Sendable, Codable, Hashable {
    /// Per-folder description file (visible, sorts first in Finder).
    public var aboutFileName: String
    /// In every directory holding filed documents: one entry per document there. See docs/storage.md.
    public var documentsFileName: String
    /// Machine-owned index at the archive root.
    public var indexFileName: String
    public var recentTitlesPerFolder: Int
    /// Characters of the `_about.md` body included in a folder's embedding.
    public var embeddingBodyChars: Int
    public var embeddingExampleLimit: Int
    /// Recent file names kept in each folder's learned block.
    public var learnedExamplesLimit: Int
    /// Most frequent correspondents kept in each folder's learned block.
    public var learnedCorrespondentsLimit: Int
    /// App-managed area holding the system folders; created only when first needed.
    public var systemArea: SystemFolderSpec
    public var systemFolders: [SystemFolderSpec]
    /// The deepest a folder can be, counted from the top of the archive; year folders do not count. The logic decides
    /// how deep the tree goes, up to this.
    public var maxDepth: Int
    /// Files the app or macOS leave in a folder that do not stop it counting as empty (besides `_about.md`).
    public var prunableLeftovers: [String]

    public func systemFolder(_ role: FolderRole) -> SystemFolderSpec? { systemFolders.first { $0.role == role } }
}

/// The files in the system area that hold what the app learned and the archive's logic; see docs/storage.md. History
/// files are named per month, with the watcher's managed-file prefix so nothing ingests them.
public struct RecordsConfig: Sendable, Codable, Hashable {
    public var sendersFileName: String
    public var rulesFileName: String
    public var correctionsFileName: String
    public var memoriesFileName: String
    /// The archive's logic, in the Logic system folder: the prompt is the file's text.
    public var logicFileName: String
    /// Added to the name of a database that could not be opened when it is moved aside.
    public var setAsideSuffix: String
}

public struct SystemFolderSpec: Sendable, Codable, Hashable {
    public var role: FolderRole?
    public var code: String
    public var name: String
    public var description: String
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

public struct CandidateWeights: Sendable, Codable, Hashable {
    public var similarity: Double
    public var knn: Double
}

public struct CalibrationWeights: Sendable, Codable, Hashable {
    public var llm: Double
    public var knn: Double
    /// Document ↔ chosen folder description similarity.
    public var similarity: Double
    /// Last level of the model's ideal path ↔ chosen folder similarity.
    public var ideal: Double
}

public struct ClassificationConfig: Sendable, Codable, Hashable {
    /// Maps the model's ideal path onto the actual folder tree. A level that may be a folder already there under another
    /// name is canonicalized: the folders beside it are ranked by embedding and the model picks which one it is, if any.
    public struct PlacementGuard: Sendable, Codable, Hashable {
        /// A level of the model's path whose name is at least this similar to a folder in the same place is that
        /// folder, rather than a new one beside it, without asking the model.
        public var duplicateAbove: Double
        /// A folder beside the level is offered to the model as the one it may be only when its name, or its name with
        /// its description, is at least this similar to the level's.
        public var offerAbove: Double
        /// Folders offered to the model in one question, the most alike first.
        public var choices: Int
        /// The k of reciprocal rank fusion, 1 / (k + rank), which merges the ranking by names with the ranking by names
        /// with descriptions.
        public var rankFusionK: Double
        /// Questions put to the model for one document at most.
        public var maxJudgements: Int
        /// A level whose name is at least this similar to the document's sender (or subject), when the two are not
        /// written alike, stands for that party: the same name in another language.
        public var partyAbove: Double
    }
    public struct KNN: Sendable, Codable, Hashable {
        public var k: Int
        public var maxPerFolder: Int
        public var halfLifeDays: Double
        public var recencyFloor: Double
    }
    public struct LLMOptions: Sendable, Codable, Hashable {
        public var temperature: Double
        public var topK: Int
        public var topP: Double
        public var numPredict: Int
        public var seed: Int
    }
    public struct CorrespondentStrength: Sendable, Codable, Hashable {
        public var stableKey: Double
        public var domain: Double
        public var alias: Double
        public var ruleMinimum: Double
    }
    public var promptVersion: Int
    /// Longest text the logic may have, so the instructions leave room for the document in the model's context.
    public var logicMaxChars: Int
    public var excerptChars: Int
    public var embeddingSummaryChars: Int
    public var embeddingNumCtx: Int
    public var promptExamplesPerFolder: Int
    public var knn: KNN
    public var candidateWeights: CandidateWeights
    public var candidateWeightsNoMemory: CandidateWeights
    public var correspondentStrength: CorrespondentStrength
    public var correspondentScanChars: Int
    public var llmOptions: LLMOptions
    public var titleMaxChars: Int
    public var maxTags: Int
    public var vlmNumPredict: Int
    public var promptDatesLimit: Int
    public var promptIdentifiersLimit: Int
    public var alternativesCount: Int
    public var ruleTextScanChars: Int
    /// Re-asks after an invalid answer before falling back to the fast model.
    public var repairAttempts: Int
    public var placementGuard: PlacementGuard
}

public struct CalibrationConfig: Sendable, Codable, Hashable {
    public var weights: CalibrationWeights
    public var weightsNoMemory: CalibrationWeights
    /// Cosine similarities are mapped linearly from [floor, ceiling] to [0, 1].
    public var similarityFloor: Double
    public var similarityCeiling: Double
    /// Ideal-path ↔ folder name similarities are mapped linearly from [idealFloor, idealCeiling] to [0, 1].
    public var idealFloor: Double
    public var idealCeiling: Double
    public var ruleAgreeFloor: Double
    public var ruleAgreeBonus: Double
    public var ruleConflictPenalty: Double
    /// Confidence multiplier for decisions that create a new folder (no past evidence can back them yet).
    public var newFolderConfidenceScale: Double
    public var metadataOnlyPenalty: Double
    public var metadataOnlyCap: Double
    public var vlmOnlyCap: Double
    public var lowOCRThreshold: Double
    public var lowOCRPenalty: Double
    public var mtimeDatePenalty: Double
    public var unknownLanguagePenalty: Double
}

public struct LearningConfig: Sendable, Codable, Hashable {
    public struct MemoryWeights: Sendable, Codable, Hashable {
        /// Confident model decision.
        public var auto: Double
        public var approved: Double
        public var corrected: Double
        /// Uncertain model decision, or a placement derived from existing rules/filings (adds no new evidence).
        public var unconfirmed: Double
    }
    public struct DescriptionRefresh: Sendable, Codable, Hashable {
        public var minNewDocuments: Int
        public var intervalDays: Double
        public var sampleSize: Int
        public var excerptSamples: Int
        public var excerptChars: Int
        public var exampleCount: Int
        public var temperature: Double
    }
    public var memoryWeights: MemoryWeights
    /// Only memories at least this heavy count as evidence for rules and direct placement.
    public var trustedMemoryMinWeight: Double
    /// A filing nobody moved for this many days counts as evidence, so the app keeps learning without being asked.
    /// Zero switches implicit confirmation off.
    public var settleUnconfirmedAfterDays: Int
    public var maxMemoriesPerFolder: Int
    public var ruleMinSupport: Int
    public var ruleMaxContradictionShare: Double
    public var ruleStrictBelowSupport: Int
    public var ruleDisableAfterContradictions: Int
    /// Reliability an automatically disabled rule must regain from fresh filings before it is switched back on.
    public var ruleReenableReliability: Double
    public var ruleInducedPriority: Int
    public var correspondentRuleMinSupport: Int
    public var correspondentRulePriority: Int
    public var stableKeyMinFilings: Int
    public var defaultFolderMinWins: Int
    public var descriptionRefresh: DescriptionRefresh
    public var absorbSampleFiles: Int
    public var directPlacement: DirectPlacement

    /// When learned evidence is strong enough to place a document without asking the model.
    public struct DirectPlacement: Sendable, Codable, Hashable {
        /// Minimum rule reliability (agreeing filings vs. contradictions; uses of the rule do not count as evidence).
        public var ruleMinReliability: Double
        /// Past filings at least this similar, all in one folder, place the document directly.
        public var knnMinSimilarity: Double
        /// Such trusted filings needed. One is enough: a model, a small one especially, decides a recurring document
        /// under different names from one month to the next, and its predecessor's folder keeps it with the rest
        /// (kNN classification over the user's own filings; see docs/organizing-principles-sources.md).
        public var knnMinNeighbors: Int
        /// Near-identical past filings that must agree on a document type before rules may rely on it.
        public var typeEstimateMinNeighbors: Int
    }
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
    public var queryCacheSize: Int
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
    public var windowsDays: [Int]
    public var whatIfAutoThresholds: [Double]
    public var folderOverlapSimilarity: Double
    public var confusionPairsLimit: Int
    public var diagnosticsTraceLimit: Int
    public var funnel: FunnelConfig
}

/// Rethinking placement: processed documents are decided again from the archive's logic.
public struct RethinkConfig: Sendable, Codable, Hashable {
    /// Documents a trial of new logic decides, taken from across the archive's folders.
    public var trialSize: Int
    /// Past filings shown to the model while rethinking must weigh at least this much (user-confirmed ones), so the
    /// old arrangement does not simply repeat itself.
    public var memoryMinWeight: Double
    /// A rule follows its documents to a new folder when at least this share of them moved there together.
    public var followShare: Double
    /// How often planning checks again whether it may continue while new arrivals, a pause or the power state hold it.
    public var waitSeconds: Double
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
    /// How many periods the "documents placed without the model" trend is split into.
    public var trendBuckets: Int
    /// Below this many documents in the window, percentages are noise, so only counts are shown.
    public var minimumForShares: Int
    public var steps: [FunnelStepConfig]
}
