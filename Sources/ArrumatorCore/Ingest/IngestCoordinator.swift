import Foundation
import GRDB

public struct IngestStatus: Sendable, Hashable {
    public var paused: Bool
    /// Files waiting to be filed.
    public var queued: Int
    /// Filed documents waiting to have their text read again, after the index was rebuilt from the archive.
    public var reindexing: Int
    public var currentPath: String?
    public var currentStage: JobState?
    public var waitingForOllama: Bool
    public var powerPauseReason: String?
    public var lastError: String?

    public static let idle = IngestStatus(paused: false, queued: 0, reindexing: 0, currentPath: nil, currentStage: nil,
                                          waitingForOllama: false, powerPauseReason: nil, lastError: nil)
}

/// Everything the pipeline needs, assembled by the composition root (app or CLI).
public struct PipelineServices: Sendable {
    public var database: AppDatabase
    public var config: PipelineConfig
    public var settings: SettingsStore
    public var taxonomy: TaxonomyStore
    public var extractor: any ContentExtracting
    public var classifier: any DocumentClassifier
    public var learner: any LearningSink
    public var filer: DocumentFiler
    public var traces: TraceRecorder
    public var vectors: VectorIndex
    public var appVersion: String

    public init(database: AppDatabase, config: PipelineConfig, settings: SettingsStore, taxonomy: TaxonomyStore,
                extractor: any ContentExtracting, classifier: any DocumentClassifier, learner: any LearningSink,
                filer: DocumentFiler, traces: TraceRecorder, vectors: VectorIndex, appVersion: String) {
        self.database = database
        self.config = config
        self.settings = settings
        self.taxonomy = taxonomy
        self.extractor = extractor
        self.classifier = classifier
        self.learner = learner
        self.filer = filer
        self.traces = traces
        self.vectors = vectors
        self.appVersion = appVersion
    }

    public var documents: DocumentStore { DocumentStore(database: database) }
    public var jobs: JobStore { JobStore(database: database) }
    public var history: HistoryStore { HistoryStore(database: database) }
    public var index: IndexStore { IndexStore(database: database) }
    public var logic: LogicStore { LogicStore(database: database, maxChars: config.classification.logicMaxChars) }

    /// Starts a trace stamped with the prompt, logic and folder-tree versions in force.
    public func startTrace(docID: Int64?, jobID: Int64?, attempt: Int, source: TraceSource,
                           settings: AppSettings) async throws -> TraceContext {
        try await traces.start(TraceHeader(
            docID: docID, jobID: jobID, attempt: attempt, source: source, promptVersion: config.classification.promptVersion,
            logicVersion: LogicStore.version(of: try await logic.current()), taxonomyVersion: try await taxonomy.version(),
            models: try? config.models(for: settings.models), settings: settings))
    }
}

/// Runs ingest jobs one at a time through hashing → extracting → classifying → filing.
/// Every transition is persisted, so a crash or restart resumes from the last completed stage.
public actor IngestCoordinator {
    private let services: PipelineServices
    private var worker: Task<Void, Never>?
    private let kick: AsyncStream<Void>.Continuation
    private let kicks: AsyncStream<Void>
    private var statusContinuations: [UUID: AsyncStream<IngestStatus>.Continuation] = [:]
    public private(set) var status = IngestStatus.idle {
        didSet { if status != oldValue { for c in statusContinuations.values { c.yield(status) } } }
    }

    /// Floor for loop sleeps so a job due "now" does not spin.
    static let minimumWait = 0.2

    public init(services: PipelineServices) {
        self.services = services
        (kicks, kick) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func statusUpdates() -> AsyncStream<IngestStatus> {
        let id = UUID()
        let (stream, c) = AsyncStream<IngestStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(status)
        statusContinuations[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.removeStatus(id) } }
        return stream
    }

    private func removeStatus(_ id: UUID) { statusContinuations[id] = nil }

    // MARK: Control

    public func start() async {
        await recoverInterruptedJobs()
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.runLoop() }
        kick.yield()
    }

    /// Stops the worker and waits until it has, so no job is still running once this returns. A job in hand is
    /// interrupted and carries on from its last finished stage the next time the worker starts.
    public func stop() async {
        guard let worker else { return }
        worker.cancel()
        await worker.value
        self.worker = nil
    }

    public func wake() { kick.yield() }

    /// Called by the Incoming watcher for each stable file.
    @discardableResult
    public func enqueue(_ url: URL) async -> Int64? {
        let path = url.standardizedFileURL.path
        do {
            if let known = try await services.documents.document(path: path),
               [.held, .undone].contains(known.status) {
                Log.debug(.ingest, "Ignoring held document", ["path": path, "doc": String(known.id ?? 0)])
                return nil
            }
            let id = try await services.jobs.enqueue(path: path, kind: .ingest)
            try await services.history.record(.arrived, job: id, summary: url.lastPathComponent, payload: ["path": path])
            Log.info(.ingest, "Queued", ["path": path, "job": id.map(String.init) ?? "-"])
            await refreshQueueCount()
            kick.yield()
            return id
        } catch {
            Log.error(.ingest, "Could not queue file", ["path": path, "error": error.localizedDescription])
            return nil
        }
    }

    /// Processes due jobs until none are left (CLI and tests).
    public func drain() async {
        while let job = try? await services.jobs.nextDue(now: Date()) {
            await process(job)
        }
        await refreshQueueCount()
    }

    // MARK: Loop

    private func runLoop() async {
        while !Task.isCancelled {
            let settings = await services.settings.current
            status.paused = settings.paused
            let powerReason = PowerState.current().pauseReason(settings: settings, config: services.config.power)
            status.powerPauseReason = powerReason
            if !settings.paused, powerReason == nil, FileManager.default.fileExists(atPath: settings.archiveURL.path) {
                if let job = try? await services.jobs.nextDue(now: Date()) {
                    await process(job)
                    continue
                }
            }
            await refreshQueueCount()
            let nextDue = (try? await services.jobs.earliestPending()) ?? nil
            var wait = nextDue.map { $0.timeIntervalSinceNow }
            if powerReason != nil { wait = services.config.power.recheckSeconds }
            await waitForKick(timeout: wait.map { max(Self.minimumWait, $0) })
        }
    }

    private func waitForKick(timeout: Double?) async {
        let kicks = kicks
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var it = kicks.makeAsyncIterator()
                _ = await it.next()
            }
            if let timeout {
                group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func refreshQueueCount() async {
        let active = (try? await services.jobs.active()) ?? []
        status.queued = active.filter { $0.kind != .reindex }.count
        status.reindexing = active.filter { $0.kind == .reindex }.count
    }

    /// Jobs interrupted mid-stage are made due again; their persisted payload lets them skip finished work.
    private func recoverInterruptedJobs() async {
        do {
            for var job in try await services.jobs.active() where job.state != .pending {
                if job.state == .filing, let target = job.payload.targetPath, !FileManager.default.fileExists(atPath: job.sourcePath),
                   FileManager.default.fileExists(atPath: target) {
                    Log.warning(.ingest, "Recovered job interrupted after move", ["job": String(job.id ?? 0), "target": target])
                }
                job.nextRunAt = Date()
                try await services.jobs.update(job)
            }
        } catch {
            Log.error(.ingest, "Job recovery failed", ["error": error.localizedDescription])
        }
    }

    // MARK: Job processing

    private func process(_ initial: JobRecord) async {
        var job = initial
        let settings = await services.settings.current
        status.currentPath = job.sourcePath
        status.currentStage = job.state
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Filing \(URL(fileURLWithPath: job.sourcePath).lastPathComponent)")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            status.currentPath = nil
            status.currentStage = nil
        }
        let trace: TraceContext
        do {
            trace = try await services.startTrace(docID: job.docId, jobID: job.id, attempt: job.attempt, source: .ingest,
                                                  settings: settings)
        } catch {
            Log.error(.db, "Could not start trace", ["error": error.localizedDescription])
            trace = .disabled
        }
        var payload = job.payload
        payload.traceID = trace.traceID
        do {
            try await runStages(&job, payload: &payload, settings: settings, trace: trace)
            status.lastError = nil
            status.waitingForOllama = false
            await services.traces.finish(trace, outcome: job.state.rawValue, docID: job.docId)
        } catch {
            await handleFailure(&job, payload: payload, error: error, trace: trace)
        }
        await refreshQueueCount()
    }

    private func save(_ job: inout JobRecord, _ payload: JobPayload, state: JobState) async throws {
        job.state = state
        job.setPayload(payload)
        try await services.jobs.update(job)
        status.currentStage = state
    }

    private func runStages(_ job: inout JobRecord, payload: inout JobPayload, settings: AppSettings,
                           trace: TraceContext) async throws {
        if job.kind == .reindex { return try await reindex(&job, payload: payload, settings: settings, trace: trace) }
        let source = URL(fileURLWithPath: job.sourcePath)
        if job.state == .pending || job.state == .hashing {
            try await save(&job, payload, state: .hashing)
            guard FileManager.default.fileExists(atPath: source.path) else {
                try await save(&job, payload, state: .cancelled)
                try await services.history.record(.missing, doc: job.docId, job: job.id, trace: trace.traceID,
                                                  summary: "\(source.lastPathComponent) disappeared before processing")
                return
            }
            let (fingerprint, sha) = try await trace.measure(.hash, input: ["path": source.path],
                                                             output: { (r: (FileFingerprint, String)) in ["sha256": r.1, "size": String(r.0.size)] }) {
                (try FileFingerprint.of(source), try HashService.sha256(of: source))
            }
            payload.sha256 = sha
            payload.size = fingerprint.size
            payload.mtime = fingerprint.modified
            payload.inode = fingerprint.inode
            let document = try await ensureDocument(for: job, source: source, sha: sha, fingerprint: fingerprint)
            job.docId = document.id
            if try await handleDuplicate(document: document, job: &job, payload: payload, settings: settings, trace: trace) {
                return
            }
            try await save(&job, payload, state: .extracting)
        }
        guard let docID = job.docId, let sha = payload.sha256 else { throw IngestError.documentNotPersisted }

        if job.state == .extracting {
            let context = ExtractionContext(config: services.config.extraction, entities: services.config.entities,
                                            vision: settings.enableVLM ? try visionOptions(settings) : nil)
            let content = try await services.extractor.extract(source, sha256: sha, context: context, trace: trace)
            payload.content = content
            try await storeExtraction(docID: docID, content: content)
            try await services.history.record(.extracted, doc: docID, job: job.id, trace: trace.traceID,
                                              summary: "\(content.kind.rawValue), \(content.text.count) chars, \(content.language.primary)",
                                              payload: ["warnings": content.warnings.map(\.code.rawValue).joined(separator: ",")])
            try await save(&job, payload, state: .classifying)
        }
        guard let content = payload.content else { throw IngestError.contentUnavailable(docID) }

        if job.state == .classifying {
            try await decide(&job, payload: &payload, docID: docID, content: content, settings: settings, trace: trace)
        }
        guard var outcome = payload.outcome else { throw IngestError.invalidState("classification missing") }

        if job.state == .filing {
            // The folder tree can change while the model decides, as when the last other document in the chosen folder
            // is undone and the folder removed. A decision naming a folder that is gone is made again against the
            // tree as it is now, which creates the folder the document needs afresh.
            if let code = outcome.decision.folderCode,
               try await services.taxonomy.snapshot(root: settings.archiveURL).folder(code: code) == nil {
                Log.info(.ingest, "Chosen folder removed while deciding; deciding again", ["doc": String(docID), "folder": code])
                try await services.history.record(.retry, doc: docID, job: job.id, trace: trace.traceID,
                                                  summary: "Folder \(code) was removed while this was being decided; deciding again")
                outcome = try await decide(&job, payload: &payload, docID: docID, content: content, settings: settings, trace: trace)
            }
            try await fileDocument(&job, payload: &payload, docID: docID, content: content, outcome: outcome,
                                   settings: settings, trace: trace)
        }
    }

    /// Asks the classifier where the document goes, against the folder tree as it is now, and keeps the answer for
    /// filing.
    @discardableResult
    private func decide(_ job: inout JobRecord, payload: inout JobPayload, docID: Int64, content: ExtractedContent,
                        settings: AppSettings, trace: TraceContext) async throws -> ClassificationOutcome {
        let taxonomy = try await services.taxonomy.snapshot(root: settings.archiveURL)
        var outcome = try await services.classifier.classify(content, taxonomy: taxonomy, settings: settings,
                                                             config: services.config, mode: .arrival, trace: trace)
        if let userFolder = payload.userFolderID, let folder = taxonomy.folder(id: userFolder) {
            outcome.decision = userConfirmed(outcome.decision, folderCode: folder.code, settings: settings)
        }
        payload.outcome = outcome
        let d = outcome.decision
        try await services.history.record(.classified, doc: docID, job: job.id, trace: trace.traceID,
                                          summary: "\(taxonomy.destination(of: d).map { ($0.isNew ? "new " : "") + $0.path } ?? "review") · \(d.band.rawValue) · \(String(format: "%.2f", d.confidence.final))",
                                          payload: d)
        try await save(&job, payload, state: .filing)
        return outcome
    }

    private func visionOptions(_ settings: AppSettings) throws -> VisionModelOptions {
        let models = try services.config.models(for: settings.models)
        return VisionModelOptions(model: models.vision, keepAlive: models.keepAliveChat,
                                  numPredict: services.config.classification.vlmNumPredict,
                                  options: services.config.classification.llmOptions)
    }

    private func userConfirmed(_ decision: FilingDecision, folderCode: String, settings: AppSettings) -> FilingDecision {
        var d = decision
        d.folderCode = folderCode
        d.decidedBy = .user
        d.proposedNewFolder = nil
        d.confidence = ConfidenceReport(llm: decision.confidence.llm, knnAgreement: decision.confidence.knnAgreement,
                                        simAgreement: decision.confidence.simAgreement, ruleHit: decision.confidence.ruleHit,
                                        modifiers: decision.confidence.modifiers.merging(["userChoice": 1], uniquingKeysWith: { $1 }),
                                        final: 1, band: .auto, thresholds: settings.thresholds)
        return d
    }

    private func ensureDocument(for job: JobRecord, source: URL, sha: String, fingerprint: FileFingerprint) async throws -> DocumentRecord {
        if let id = job.docId, let existing = try await services.documents.document(id: id) { return existing }
        let uttype = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier) ?? "public.data"
        let record = DocumentRecord.arrived(path: source.path, sha256: sha, size: fingerprint.size, uttype: uttype,
                                            inode: fingerprint.inode, modified: fingerprint.modified)
        return try await services.documents.save(record)
    }

    /// Returns true when the file was handled as a duplicate of an existing document.
    private func handleDuplicate(document: DocumentRecord, job: inout JobRecord, payload: JobPayload,
                                 settings: AppSettings, trace: TraceContext) async throws -> Bool {
        guard job.kind != .adopt, let docID = document.id else { return false }
        let original = try await trace.measure(.dedupe, input: ["sha256": document.sha256],
                                               output: { (d: DocumentRecord?) in ["duplicateOf": d?.id.map(String.init) ?? "none"] }) {
            try await services.documents.existing(sha256: document.sha256, excluding: docID)
        }
        guard let original else { return false }
        var doc = document
        doc.duplicateOf = original.id
        doc.status = .duplicate
        if settings.duplicateAction == .moveToDuplicates {
            let folder = try await services.taxonomy.ensureSystemFolder(.duplicates, root: settings.archiveURL)
            let taxonomy = try await services.taxonomy.snapshot(root: settings.archiveURL)
            let decision = FilingDecision(folderCode: folder.code, title: document.originalFilename,
                                          confidence: ConfidenceReport(final: 1, band: .auto, thresholds: settings.thresholds),
                                          decidedBy: .rule, rationale: "Identical bytes to document \(original.id ?? 0): \(original.filename)")
            doc = try await services.documents.save(doc)
            let source = SourceFile(path: doc.path, originalFilename: doc.originalFilename,
                                    fileExtension: (doc.originalFilename as NSString).pathExtension, utType: doc.uttype,
                                    byteSize: doc.size, createdAt: nil, modifiedAt: doc.fileMtime, sha256: doc.sha256)
            let result = try await services.filer.file(doc, source: source, decision: decision, folderCode: folder.code,
                                                       status: .duplicate, userChosen: false, inPlace: false,
                                                       taxonomy: taxonomy, settings: settings, trace: trace)
            doc = result.document
        } else {
            doc = try await services.documents.save(doc)
        }
        try await services.history.record(.duplicate, doc: docID, job: job.id, trace: trace.traceID,
                                          summary: "\(document.originalFilename) duplicates \(original.filename)",
                                          payload: ["original": String(original.id ?? 0), "path": doc.path])
        try await save(&job, payload, state: .duplicate)
        return true
    }

    /// Reads a filed document's text and computes its embedding again, deciding and moving nothing: what a document
    /// needs for search after the index was rebuilt from the archive.
    private func reindex(_ job: inout JobRecord, payload: JobPayload, settings: AppSettings, trace: TraceContext) async throws {
        guard let docID = job.docId, let document = try await services.documents.document(id: docID),
              FileManager.default.fileExists(atPath: document.path) else {
            try await save(&job, payload, state: .cancelled)
            return
        }
        try await save(&job, payload, state: .extracting)
        let context = ExtractionContext(config: services.config.extraction, entities: services.config.entities,
                                        vision: settings.enableVLM ? try visionOptions(settings) : nil)
        let content = try await services.extractor.extract(document.url, sha256: document.sha256, context: context, trace: trace)
        try await storeExtraction(docID: docID, content: content)
        try await services.index.updateHeader(docID: docID, title: document.title ?? "", correspondent: document.correspondent ?? "",
                                              filename: document.filename)
        if let (vector, model) = try await services.classifier.embedding(for: content, sender: document.correspondent,
                                                                          settings: settings, config: services.config, trace: trace) {
            let text = content.embeddingSummary(correspondentHint: document.correspondent,
                                                maxChars: services.config.classification.embeddingSummaryChars)
            try await trace.measure(.index, input: ["model": model]) {
                try await services.index.upsertEmbedding(docID: docID, model: model, vector: vector, sourceText: text)
                await services.vectors.upsert(docID: docID, vector: vector, model: model)
            }
            await services.learner.documentReembedded(documentID: docID, vector: vector, model: model)
        }
        try await save(&job, payload, state: .done)
    }

    private func storeExtraction(docID: Int64, content: ExtractedContent) async throws {
        guard var doc = try await services.documents.document(id: docID) else { throw IngestError.documentNotFound(docID) }
        doc.language = content.language.primary
        doc.pageCount = content.pageCount
        doc.extractedAt = Date()
        doc.contentJson = DocumentStore.storedContentJSON(content)
        _ = try await services.documents.save(doc)
        try await services.index.upsertText(docID: docID, title: "", correspondent: "", filename: doc.filename,
                                            body: content.text, summary: content.visual?.description,
                                            metadata: content.metadata,
                                            extractorVersion: "\(content.extractorName)/\(content.extractorVersion)")
    }

    private func fileDocument(_ job: inout JobRecord, payload: inout JobPayload, docID: Int64, content: ExtractedContent,
                              outcome: ClassificationOutcome, settings: AppSettings, trace: TraceContext) async throws {
        guard let document = try await services.documents.document(id: docID) else { throw IngestError.documentNotFound(docID) }
        let root = settings.archiveURL
        var decision = outcome.decision
        let userChosen = payload.userFolderID != nil
        let lowConfidence = decision.band == .review && settings.lowConfidenceAction == .holdForReview
        let targetCode: String
        let status: DocumentStatus
        if lowConfidence && !userChosen {
            targetCode = try await services.taxonomy.ensureSystemFolder(.needsReview, root: root).code
            status = .needsReview
        } else if let code = decision.folderCode {
            targetCode = code
            status = .filed
        } else if let spec = decision.proposedNewFolder, settings.autoCreateFolders {
            let created = try await trace.measure(.place, input: ["create": spec], output: { (f: TaxonomyFolder) in
                ["code": f.code, "path": f.relativePath]
            }) {
                try await services.taxonomy.materialize(spec, root: root, origin: .learned)
            }
            decision.folderCode = created.code
            decision.proposedNewFolder = nil
            payload.outcome?.decision = decision
            targetCode = created.code
            status = .filed
        } else {
            targetCode = try await services.taxonomy.ensureSystemFolder(.needsReview, root: root).code
            status = .needsReview
        }
        let taxonomy = try await services.taxonomy.snapshot(root: root)
        if job.kind != .adopt, document.path != job.sourcePath || !FileManager.default.fileExists(atPath: document.path) {
            if let target = payload.targetPath, FileManager.default.fileExists(atPath: target), document.path == target {
                Log.info(.ingest, "Filing already completed before interruption", ["doc": String(docID)])
            } else if !FileManager.default.fileExists(atPath: document.path) {
                throw IngestError.sourceMissing(document.path)
            }
        }
        let result = try await services.filer.file(document, source: content.source, decision: decision, folderCode: targetCode,
                                                   status: status, userChosen: userChosen, inPlace: job.kind == .adopt,
                                                   taxonomy: taxonomy, settings: settings, trace: trace)
        payload.targetPath = result.document.path
        if var doc = try await services.documents.document(id: docID) {
            doc.lastTraceId = trace.traceID
            _ = try await services.documents.save(doc)
        }
        if let embedding = outcome.embedding, let model = outcome.embeddingModel {
            let text = content.embeddingSummary(correspondentHint: decision.correspondent,
                                                maxChars: services.config.classification.embeddingSummaryChars)
            try await trace.measure(.index, input: ["model": model]) {
                try await services.index.upsertEmbedding(docID: docID, model: model, vector: embedding, sourceText: text)
                await services.vectors.upsert(docID: docID, vector: embedding, model: model)
            }
        }
        if status == .filed, let folderID = result.document.folderId {
            // Every placement is recorded so repeated patterns turn into rules; user confirmations weigh more.
            var learned = outcome
            learned.decision = decision
            var filed = content
            filed.source.path = result.document.path
            await services.learner.documentFiled(documentID: docID, folderID: folderID, outcome: learned, content: filed,
                                                 confirmedByUser: userChosen || job.kind == .adopt, trace: trace)
        }
        try await save(&job, payload, state: status == .needsReview ? .needsReview : .done)
        Log.info(.ingest, status == .needsReview ? "Held for review" : "Filed", [
            "doc": String(docID), "folder": targetCode, "band": decision.band.rawValue,
            "confidence": String(format: "%.2f", decision.confidence.final), "path": result.document.path,
        ])
    }

    // MARK: Failures

    private func handleFailure(_ job: inout JobRecord, payload: JobPayload, error: any Error, trace: TraceContext) async {
        // Stopping interrupts the job; that is no failure. Its saved stage lets it resume where it stopped.
        guard !Task.isCancelled else {
            Log.info(.ingest, "Job interrupted by stopping", ["job": String(job.id ?? 0), "stage": job.state.rawValue])
            return
        }
        let message = error.localizedDescription
        status.lastError = message
        let config = services.config.ingest
        let ollamaDown = (error as? OllamaError).map { $0.isTransient } ?? false
        job.lastError = message
        job.setPayload(payload)
        if case OllamaError.modelNotFound = error {
            job.state = .held
            try? await services.jobs.update(job)
            _ = try? await services.history.record(.error, doc: job.docId, job: job.id, trace: trace.traceID,
                                               summary: "Model missing: \(message)")
            await services.traces.finish(trace, outcome: "held", docID: job.docId)
            Log.error(.ingest, "Model missing; job held", ["job": String(job.id ?? 0), "error": message])
            return
        }
        if ollamaDown {
            status.waitingForOllama = true
            job.nextRunAt = Date().addingTimeInterval(config.retryDelays.last ?? 0)
            try? await services.jobs.update(job)
            _ = try? await services.history.record(.retry, doc: job.docId, job: job.id, trace: trace.traceID,
                                               summary: "Waiting for Ollama: \(message)")
            await services.traces.finish(trace, outcome: "waiting", docID: job.docId)
            Log.warning(.ingest, "Ollama unavailable; will retry", ["job": String(job.id ?? 0), "error": message])
            return
        }
        job.attempt += 1
        if job.attempt < config.maxAttempts {
            let delay = config.retryDelays[min(job.attempt - 1, config.retryDelays.count - 1)]
            job.nextRunAt = Date().addingTimeInterval(delay)
            try? await services.jobs.update(job)
            _ = try? await services.history.record(.retry, doc: job.docId, job: job.id, trace: trace.traceID,
                                               summary: "Attempt \(job.attempt) failed: \(message)")
            await services.traces.finish(trace, outcome: "retry", docID: job.docId)
            Log.warning(.ingest, "Stage failed; retrying", ["job": String(job.id ?? 0), "stage": job.state.rawValue,
                                                            "attempt": String(job.attempt), "error": message])
            return
        }
        job.state = .failed
        try? await services.jobs.update(job)
        await parkFailedDocument(job: job, message: message, trace: trace)
        await services.traces.finish(trace, outcome: "failed", docID: job.docId)
        Log.error(.ingest, "Job failed", ["job": String(job.id ?? 0), "error": message])
    }

    /// Moves a file that could not be processed into Needs review so Incoming stays clean and nothing is lost.
    private func parkFailedDocument(job: JobRecord, message: String, trace: TraceContext) async {
        do {
            let settings = await services.settings.current
            let review = try await services.taxonomy.ensureSystemFolder(.needsReview, root: settings.archiveURL)
            let taxonomy = try await services.taxonomy.snapshot(root: settings.archiveURL)
            guard let docID = job.docId, let document = try await services.documents.document(id: docID) else {
                try await services.history.record(.failed, job: job.id, trace: trace.traceID, summary: message)
                return
            }
            if FileManager.default.fileExists(atPath: document.path), job.kind != .adopt {
                let decision = FilingDecision(folderCode: review.code, title: document.originalFilename,
                                              confidence: ConfidenceReport(final: 0, band: .review, thresholds: settings.thresholds),
                                              decidedBy: .review, rationale: "Processing failed: \(message)", reviewReasons: [message])
                let source = SourceFile(path: document.path, originalFilename: document.originalFilename,
                                        fileExtension: (document.originalFilename as NSString).pathExtension,
                                        utType: document.uttype, byteSize: document.size, createdAt: nil,
                                        modifiedAt: document.fileMtime, sha256: document.sha256)
                _ = try await services.filer.file(document, source: source, decision: decision, folderCode: review.code,
                                                  status: .failed, userChosen: false, inPlace: false, taxonomy: taxonomy,
                                                  settings: settings, trace: trace)
            }
            try await services.history.record(.failed, doc: docID, job: job.id, trace: trace.traceID,
                                              summary: "\(document.originalFilename): \(message)")
        } catch {
            Log.error(.ingest, "Could not park failed document", ["job": String(job.id ?? 0), "error": error.localizedDescription])
        }
    }
}
