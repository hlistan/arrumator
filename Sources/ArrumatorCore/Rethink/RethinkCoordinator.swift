import Foundation

/// Where a rethink stands, for the app and the command line.
public struct RethinkProgress: Sendable, Hashable {
    public var status: RethinkRunStatus?
    public var total: Int
    public var decided: Int
    /// Documents applying would move, as the plan is ticked now.
    public var moves: Int
    /// Documents the user can tick or untick: moves, and unsure documents the logic suggested a place for.
    public var choices: Int
    /// Why planning is waiting instead of deciding, when it is.
    public var waiting: String?

    public static let none = RethinkProgress(status: nil, total: 0, decided: 0, moves: 0, choices: 0, waiting: nil)

    public var isActive: Bool { status?.isActive ?? false }
}

/// Rethinks placement. Processed documents — a trial on a few from across the archive, or all of them — are decided
/// again from the archive's logic, with learned rules and past filings only advising; the result is a plan of moves
/// (documents keep their names) and new folders that the user applies or discards. Applying moves the files, removes the folders it
/// leaves empty and lets rules follow their documents. Planning runs one document at a time in the background and
/// always gives way to new arrivals.
public actor RethinkCoordinator {
    private let services: PipelineServices
    private let ingest: IngestCoordinator
    private let store: RethinkStore
    private var worker: Task<Void, Never>?
    private let kick: AsyncStream<Void>.Continuation
    private let kicks: AsyncStream<Void>
    private var continuations: [UUID: AsyncStream<RethinkProgress>.Continuation] = [:]
    public private(set) var progress = RethinkProgress.none {
        didSet { if progress != oldValue { for c in continuations.values { c.yield(progress) } } }
    }

    public init(services: PipelineServices, ingest: IngestCoordinator) {
        self.services = services
        self.ingest = ingest
        store = RethinkStore(database: services.database)
        (kicks, kick) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func progressUpdates() -> AsyncStream<RethinkProgress> {
        let id = UUID()
        let (stream, c) = AsyncStream<RethinkProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(progress)
        continuations[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    // MARK: Control

    /// Starts the background planner; a rethink interrupted by quitting carries on where it stopped.
    public func start() async {
        await refreshProgress()
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.runLoop() }
    }

    /// Stops the planner and waits until it has. A document being decided is interrupted and stays undecided, to be
    /// decided when the planner starts again.
    public func stop() async {
        guard let worker else { return }
        worker.cancel()
        await worker.value
        self.worker = nil
    }

    /// Begins deciding processed documents again: a few from across the archive for a trial, or all of them.
    /// Documents the user placed or confirmed stay out unless `includeUserPlaced`.
    @discardableResult
    public func begin(_ scope: RethinkScope, includeUserPlaced: Bool) async throws -> RethinkRunRecord {
        guard try await store.activeRun() == nil else { throw RethinkError.alreadyActive }
        let candidates = try await store.candidates(includeUserPlaced: includeUserPlaced)
        let documents = scope == .trial ? Self.sample(candidates, size: services.config.rethink.trialSize) : candidates
        let run = try await store.createRun(scope: scope, includeUserPlaced: includeUserPlaced,
                                            logicVersion: LogicStore.version(of: try await services.logic.current()),
                                            documents: documents)
        Log.info(.classify, "Rethink started", ["run": String(run.id ?? 0), "documents": String(documents.count)])
        await refreshProgress()
        kick.yield()
        return run
    }

    /// Takes documents from each folder in turn, most recent first, so a trial sees the whole archive.
    static func sample(_ documents: [DocumentRecord], size: Int) -> [DocumentRecord] {
        var byFolder = Dictionary(grouping: documents.reversed(), by: \.folderId)
        let folders = byFolder.keys.sorted { ($0 ?? 0) < ($1 ?? 0) }
        var picked: [DocumentRecord] = []
        while picked.count < size, byFolder.values.contains(where: { !$0.isEmpty }) {
            for folder in folders where picked.count < size {
                guard var queue = byFolder[folder], !queue.isEmpty else { continue }
                picked.append(queue.removeFirst())
                byFolder[folder] = queue
            }
        }
        return picked
    }

    /// Plans every remaining document now instead of in the background (command line and tests).
    public func planAll() async throws {
        while let run = try await store.activeRun(), run.status == .planning {
            guard try await planNext(run) else { break }
        }
    }

    public func select(itemID: Int64, _ selected: Bool) async throws {
        guard let item = try await store.item(id: itemID), item.canMove else { throw RethinkError.cannotMove(itemID) }
        try await store.setSelected(itemID: itemID, selected)
        await refreshProgress()
    }

    public func discard() async throws {
        guard let run = try await store.activeRun() else { throw RethinkError.noActiveRun }
        guard run.status != .applying else { throw RethinkError.notReady(run.status) }
        _ = try await store.finish(run, status: .discarded, summary: "Rethink discarded; nothing was moved", by: .user)
        await refreshProgress()
    }

    /// Ends planning before every document is decided, as the user may once they have seen enough of what the logic
    /// does. The document being decided is interrupted rather than waited for, those not reached are left out, and
    /// what was decided becomes the plan, to apply or discard like any other; with nothing in it that could move, the
    /// run settles and the logic is free again.
    @discardableResult
    public func stopPlanning() async throws -> RethinkRunRecord {
        guard let planning = try await store.activeRun() else { throw RethinkError.noActiveRun }
        guard planning.status == .planning else { throw RethinkError.notPlanning(planning.status) }
        let wasRunning = worker != nil
        await stop()
        defer { if wasRunning { startWorker() } }
        // Read again: the planner may have reserved folders for the last documents it decided.
        guard let run = try await store.activeRun(), let runID = run.id, run.id == planning.id, run.status == .planning else {
            throw RethinkError.noActiveRun
        }
        let left = try await store.leaveUndecidedOut(runID: runID)
        Log.info(.classify, "Rethink stopped early", ["run": String(runID), "undecided": String(left)])
        return try await finishPlanning(run, runID: runID, stopped: true)
    }

    // MARK: Planning

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                if let run = try await store.activeRun(), run.status == .planning {
                    if let reason = await waitReason() {
                        progress.waiting = reason
                        await waitForKick(timeout: services.config.rethink.waitSeconds)
                        continue
                    }
                    progress.waiting = nil
                    if try await planNext(run) { continue }
                }
                await waitForKick(timeout: nil)
            } catch where Task.isCancelled {
                return
            } catch let error as OllamaError where error.isTransient {
                progress.waiting = "Waiting for Ollama"
                Log.warning(.classify, "Rethink waiting for Ollama", ["error": error.localizedDescription])
                await waitForKick(timeout: services.config.ingest.retryDelays.last ?? services.config.rethink.waitSeconds)
            } catch {
                Log.error(.classify, "Rethink planning stopped", ["error": error.localizedDescription])
                await waitForKick(timeout: services.config.rethink.waitSeconds)
            }
        }
    }

    /// Why planning should not use the model right now: new arrivals come first, and a pause or the power state
    /// hold rethinking as they hold filing.
    private func waitReason() async -> String? {
        let settings = await services.settings.current
        if settings.paused { return "Paused" }
        if let reason = PowerState.current().pauseReason(settings: settings, config: services.config.power) { return reason }
        let filing = await ingest.status
        if filing.queued > 0 || filing.currentPath != nil { return "Filing new arrivals first" }
        return nil
    }

    private func waitForKick(timeout: Double?) async {
        let kicks = kicks
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var it = kicks.makeAsyncIterator()
                _ = await it.next()
            }
            if let timeout {
                group.addTask {
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Decides the next pending document, or marks the plan ready when none is left.
    /// - Returns: false once the run is no longer planning.
    private func planNext(_ run: RethinkRunRecord) async throws -> Bool {
        guard let runID = run.id else { throw RethinkError.noActiveRun }
        guard let item = try await store.nextPending(runID: runID) else {
            try await finishPlanning(run, runID: runID, stopped: false)
            return false
        }
        try await plan(item, run: run)
        await refreshProgress()
        return true
    }

    /// Every document is decided, or planning was `stopped` by the user before the rest were. When none of them could
    /// change there is nothing for the user to review, so the run settles and the logic is free again; otherwise the
    /// plan waits to be applied or discarded.
    @discardableResult
    private func finishPlanning(_ run: RethinkRunRecord, runID: Int64, stopped: Bool) async throws -> RethinkRunRecord {
        let items = try await store.items(runID: runID)
        let counts = Dictionary(grouping: items, by: \.status).mapValues(\.count)
        let choices = items.filter(\.canMove)
        let stay = "\(counts[.unchanged] ?? 0) stay where they are"
        let decided = items.count - (counts[.notDecided] ?? 0)
        let finished: RethinkRunRecord
        if choices.isEmpty {
            let summary = (stopped ? "Stopped after deciding \(decided) of \(Format.count(items.count, "document")), with nothing"
                                   : "Nothing")
                + " to change: the logic agrees with where these documents are; \(stay), "
                + "\(counts[.unsure] ?? 0) unsure, \(counts[.failed] ?? 0) could not be decided"
            finished = try await store.finish(run, status: .settled, summary: summary, by: stopped ? .user : .system)
            Log.info(.classify, "Rethink settled", ["run": String(runID)])
        } else {
            let moves = choices.filter { $0.status == .move }
            let folders = RethinkStore.folders(try run.plannedFolders(), neededBy: moves)
            let summary = (stopped ? "Stopped after deciding \(decided) of \(Format.count(items.count, "document")): " : "Rethink ready: ")
                + "\(Format.count(moves.count, "document")) would move and "
                + "\(Format.count(folders.count, "folder")) would be created; \(stay), "
                + "\(counts[.unsure] ?? 0) unsure (\(choices.count - moves.count) with a suggested place)"
            finished = try await store.finish(run, status: .ready, summary: summary, by: stopped ? .user : .system)
            Log.info(.classify, "Rethink planned", ["run": String(runID), "moves": String(moves.count),
                                                    "choices": String(choices.count)])
        }
        await refreshProgress()
        return finished
    }

    private func plan(_ pending: RethinkItemRecord, run: RethinkRunRecord) async throws {
        var item = pending
        let settings = await services.settings.current
        guard let document = try await services.documents.document(id: item.docId), document.status == .filed,
              document.path == item.fromPath, var content = try await services.documents.content(docID: item.docId) else {
            item.status = .skipped
            item.error = "Changed or removed after the rethink started"
            try await store.decide(item)
            return
        }
        content.source.path = document.path
        var planned = try run.plannedFolders()
        let trace = try await services.startTrace(docID: item.docId, jobID: nil, attempt: 0, source: .rethink, settings: settings)
        item.traceId = trace.traceID
        do {
            let root = settings.archiveURL
            let outcome = try await services.classifier.classify(
                content, taxonomy: try await planningSnapshot(root: root, planned: planned), settings: settings,
                config: services.config, mode: .rethink(documentID: item.docId), trace: trace)
            var decision = outcome.decision
            let snapshot = try await planningSnapshot(root: root, planned: planned)
            let unsure = decision.band == .review
            let used = try await services.taxonomy.allCodes()
            let code = decision.folderCode ?? decision.proposedNewFolder.flatMap { reserve($0, in: snapshot, used: used, planned: &planned) }
            if let code {
                if let index = planned.firstIndex(where: { $0.code == code }) {
                    if let sender = decision.correspondentID { planned[index].senders.insert(sender) }
                    planned[index].documentTypes.insert(decision.documentType)
                }
                decision.folderCode = code
                decision.proposedNewFolder = nil
                // Rethinking changes where a document lives, not what it is called: a model phrasing the name
                // differently this time is no reason to rename a file the user already knows.
                decision.fileName = (document.filename as NSString).deletingPathExtension
                let target = try services.filer.placer.plan(
                    decision: decision, folderCode: code, source: content.source,
                    taxonomy: try await planningSnapshot(root: root, planned: planned), settings: settings, userChosen: false)
                let path = URL(fileURLWithPath: target.directory).appendingPathComponent(target.filename).path
                item.targetCode = code
                item.targetPath = path
                // An unsure suggestion is only offered: the user ticks it if they agree.
                item.status = unsure ? .unsure : (path == document.path ? .unchanged : .move)
                item.selected = !unsure
            } else {
                item.status = .unsure
                item.selected = false
            }
            item.decisionJson = JSON.string(decision)
            if planned != (try run.plannedFolders()), let runID = run.id {
                try await store.setPlannedFolders(runID: runID, planned)
            }
            try await store.decide(item)
            await services.traces.finish(trace, outcome: "rethink-\(item.status.rawValue)", docID: item.docId)
        } catch where Task.isCancelled {
            // Stopping interrupted the model: the document is not decided, which is no failure of it.
            await services.traces.finish(trace, outcome: "interrupted", docID: item.docId)
            throw CancellationError()
        } catch let error as OllamaError where error.isTransient {
            await services.traces.finish(trace, outcome: "waiting", docID: item.docId)
            throw error
        } catch {
            item.status = .failed
            item.error = error.localizedDescription
            try await store.decide(item)
            await services.traces.finish(trace, outcome: "failed", docID: item.docId)
            Log.warning(.classify, "Could not rethink document", ["doc": String(item.docId), "error": error.localizedDescription])
        }
    }

    /// The folder tree as it would be with the plan's new folders, which carry negative ids until they exist.
    private func planningSnapshot(root: URL, planned: [PlannedFolder]) async throws -> TaxonomySnapshot {
        var snapshot = try await services.taxonomy.snapshot(root: root)
        var nextID: Int64 = -1
        // Planned folders are listed parents first, so each one's parent is already in place.
        for folder in planned where snapshot.folder(code: folder.code) == nil {
            let parent = folder.parentCode.flatMap { snapshot.folder(code: $0) }
            guard folder.parentCode == nil || parent != nil else { continue }
            snapshot.folders.append(TaxonomyFolder(
                id: nextID, code: folder.code, name: folder.name, parentCode: folder.parentCode,
                relativePath: parent.map { "\($0.relativePath)/\(folder.name)" } ?? folder.name, description: folder.description,
                yearSubfolders: folder.yearSubfolders, yearRule: folder.yearRule ?? .documentDate, descriptionHash: "planned-\(folder.code)",
                kind: folder.kind, logic: folder.logic, senders: folder.senders, documentTypes: folder.documentTypes))
            nextID -= 1
        }
        return snapshot
    }

    /// Reserves codes for the folders the model proposed, level by level, and returns the code of the last. A level
    /// that already exists, or is already planned, in its parent is reused. Nil when the path would be too deep.
    private func reserve(_ spec: FolderSpec, in snapshot: TaxonomySnapshot, used: Set<String>,
                         planned: inout [PlannedFolder]) -> String? {
        let startDepth = spec.parentCode.flatMap { snapshot.folder(code: $0) }.map(snapshot.depth(of:)) ?? 0
        guard startDepth + spec.levels.count <= services.config.taxonomy.maxDepth else { return nil }
        var used = used.union(snapshot.folders.map(\.code)).union(planned.map(\.code))
        var parent = spec.parentCode
        for (index, level) in spec.levels.enumerated() {
            let name = TaxonomyStore.displayName(level.name)
            let sameName = { (other: String) in TaxonomyStore.sameName(other, name) }
            if let existing = snapshot.children(of: parent).first(where: { $0.holdsUserDocuments && sameName($0.name) })?.code
                ?? planned.first(where: { $0.parentCode == parent && sameName($0.name) })?.code {
                parent = existing
                continue
            }
            let code = FolderCode.next(after: used)
            used.insert(code)
            let last = index == spec.levels.count - 1
            planned.append(PlannedFolder(code: code, name: name, description: level.description, parentCode: parent,
                                         yearSubfolders: last && spec.yearSubfolders, yearRule: last ? spec.yearRule : nil,
                                         kind: level.kind, logic: spec.logic, senders: [], documentTypes: []))
            parent = code
        }
        return parent
    }

    // MARK: Applying

    /// Moves the documents the plan moves (those still selected and unchanged since planning), creates the folders
    /// they need, removes the folders left empty and lets rules follow their documents.
    @discardableResult
    public func apply() async throws -> RethinkRunRecord {
        guard let run = try await store.activeRun(), let runID = run.id else { throw RethinkError.noActiveRun }
        guard run.status == .ready else { throw RethinkError.notReady(run.status) }
        try await store.setStatus(runID: runID, .applying)
        await refreshProgress()
        let settings = await services.settings.current
        let root = settings.archiveURL
        let embedModel = try? services.config.models(for: settings.models).embed
        var created: [String: TaxonomyFolder] = [:]
        var moves: [PlacementMove] = []
        var moved = 0
        for var item in try await store.items(runID: runID, statuses: [.move, .unsure]) where item.canMove {
            guard item.selected else {
                if item.status == .move {
                    item.status = .skipped
                    try await store.save(item)
                }
                continue
            }
            let chosen = item.isUserChoice
            do {
                guard let document = try await services.documents.document(id: item.docId), document.status == .filed,
                      document.path == item.fromPath, var decision = item.decision, let code = item.targetCode,
                      var content = try await services.documents.content(docID: item.docId) else {
                    item.status = .skipped
                    item.error = "Changed after the plan was made"
                    try await store.save(item)
                    continue
                }
                let folder = try await realize(code, planned: try run.plannedFolders(), created: &created, root: root)
                decision.folderCode = folder.code
                content.source.path = document.path
                let trace = item.traceId.map { TraceContext(traceID: $0, sink: services.traces) } ?? .disabled
                if chosen {
                    // The logic only suggested this place; the user picked it, so it is their decision.
                    decision.decidedBy = .user
                    decision.confidence.final = 1
                    decision.confidence.band = .auto
                    await trace.record(.review, startedAt: Date(), input: ["action": "rethinkChoice", "folder": folder.code],
                                       output: ["previousFolder": item.fromFolderId.map(String.init) ?? "none"])
                }
                let filedRecord = try await services.filer.file(
                    document, source: content.source, decision: decision, folderCode: folder.code, status: .filed, userChosen: chosen,
                    inPlace: false, taxonomy: try await services.taxonomy.snapshot(root: root), settings: settings, trace: trace,
                    event: .rethought)
                var filed = filedRecord
                filed.lastTraceId = item.traceId ?? filed.lastTraceId
                _ = try await services.documents.save(filed)
                content.source.path = filed.path
                var embedding: [Float]?
                if let embedModel { embedding = try await services.index.embedding(docID: item.docId, model: embedModel) }
                await services.learner.documentFiled(
                    documentID: item.docId, folderID: folder.id,
                    outcome: ClassificationOutcome(decision: decision, embedding: embedding, embeddingModel: embedding == nil ? nil : embedModel),
                    content: content, confirmedByUser: chosen, trace: trace)
                if let from = item.fromFolderId, from != folder.id {
                    moves.append(PlacementMove(documentID: item.docId, fromFolderID: from, toFolderID: folder.id,
                                               correspondentID: filed.correspondentId, documentType: decision.documentType))
                }
                item.status = .applied
                item.targetPath = filed.path
                moved += 1
            } catch {
                item.status = .failed
                item.error = error.localizedDescription
                Log.error(.fileops, "Could not apply rethink to document", ["doc": String(item.docId), "error": error.localizedDescription])
            }
            try await store.save(item)
        }
        let removed = try await services.taxonomy.pruneEmpty(root: root)
        await services.learner.placementsRearranged(moves, removedFolderIDs: Set(removed.map(\.id)))
        let summary = "Rethink applied: moved \(Format.count(moved, "document")), created \(Format.count(created.count, "folder")), "
            + "removed \(Format.count(removed.count, "empty folder"))"
        let finished = try await store.finish(run, status: .applied, summary: summary, by: .system)
        Log.info(.fileops, "Rethink applied", ["run": String(runID), "moved": String(moved), "removed": String(removed.count)])
        await refreshProgress()
        return finished
    }

    /// The real folder behind a code in the plan, creating a planned folder, after the planned folders it is in, the
    /// first time it is used.
    private func realize(_ code: String, planned: [PlannedFolder], created: inout [String: TaxonomyFolder],
                         root: URL) async throws -> TaxonomyFolder {
        if let folder = created[code] { return folder }
        guard let plan = planned.first(where: { $0.code == code }) else {
            guard let existing = try await services.taxonomy.snapshot(root: root).folder(code: code) else {
                throw PlacementError.unknownFolder(code)
            }
            return existing
        }
        var parent: TaxonomyFolder?
        if let parentCode = plan.parentCode {
            parent = try await realize(parentCode, planned: planned, created: &created, root: root)
        }
        let taken = try await services.taxonomy.allCodes().contains(plan.code)
        let folder = try await services.taxonomy.createFolder(
            root: root, parentCode: parent?.code, name: plan.name, description: plan.description, yearSubfolders: plan.yearSubfolders,
            yearRule: plan.yearRule, origin: .learned, kind: plan.kind, logic: plan.logic, code: taken ? nil : plan.code)
        created[code] = folder
        return folder
    }

    // MARK: Progress

    private func refreshProgress() async {
        do {
            let active = try await store.activeRun()
            let latest = active == nil ? try await store.latestRun() : nil
            guard let run = active ?? latest, let runID = run.id else {
                progress = .none
                return
            }
            let items = try await store.items(runID: runID)
            let choices = items.filter(\.canMove)
            progress = RethinkProgress(status: run.status, total: items.count,
                                       decided: items.filter { $0.status != .pending }.count,
                                       moves: choices.filter(\.selected).count, choices: choices.count,
                                       waiting: run.status == .planning ? progress.waiting : nil)
        } catch {
            Log.error(.db, "Could not read rethink progress", ["error": error.localizedDescription])
        }
    }
}
