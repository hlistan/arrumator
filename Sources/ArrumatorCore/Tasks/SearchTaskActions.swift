import Foundation
import GRDB

/// A change the user makes to a search task. Nil leaves a part as it is.
public struct SearchTaskChange: Sendable, Hashable {
    /// The task's name; empty gives it the model's name back.
    public var title: String?
    /// What the task asks for, in the user's words; a new one sends the task back into the queue.
    public var prompt: String?
    public var grouping: Grouping?
    /// How much the model thinks before it answers its prompt; another sends the task back into the queue.
    public var effort: TaskEffort?
    /// The id of the model profile that reads its prompt, one the settings list; empty gives the task back to the one
    /// Settings uses. Another sends the task back into the queue.
    public var profile: String?

    /// What the task's set is arranged by.
    public enum Grouping: Sendable, Hashable {
        /// As the prompt asked, else `tasks.defaultGrouping`.
        case asAsked
        /// By these kinds, the outermost first; none lists the set without arranging it.
        case by([LabelKind])
    }

    public init(title: String? = nil, prompt: String? = nil, grouping: Grouping? = nil, effort: TaskEffort? = nil, profile: String? = nil) {
        self.title = title
        self.prompt = prompt
        self.grouping = grouping
        self.effort = effort
        self.profile = profile
    }
}

/// What the user does with search tasks: ask for documents in their own words, change what a task asks for or how it
/// arranges them, add documents to its set or take them out, export the set, ask again, remove the task. Each change is
/// made in one transaction with its History event, and reaches the archive's `System/_tasks.md`.
public struct SearchTaskActions: Sendable {
    public let services: PipelineServices
    public let queue: SearchTaskQueue

    public init(services: PipelineServices, queue: SearchTaskQueue) {
        self.services = services
        self.queue = queue
    }

    public var store: SearchTaskStore { SearchTaskStore(database: services.database, config: services.config.tasks, time: services.time) }
    private var config: TasksConfig { services.config.tasks }

    /// Puts a prompt in the queue as a new task, read with `effort`, else the one Settings gives new tasks
    /// (`taskEffort`), and by the model profile `profile` names, else by the one Settings uses whenever it is read. A
    /// profile the settings do not list is refused, and nothing is written.
    @discardableResult
    public func create(prompt: String, effort: TaskEffort? = nil, profile: String? = nil) async throws -> SearchTask {
        let asked = try Self.prompt(prompt)
        let settings = await services.settings.current
        let effort = effort ?? settings.taskEffort
        let profile = try profile.flatMap { try Self.profile($0, settings: settings) }
        let now = services.time.now()
        let config = config
        let id = try await services.database.writer.write { db in
            var record = SearchTaskRecord(id: nil, prompt: asked, title: nil, groupingJson: nil, effort: effort, profile: profile,
                                          state: .queued, planJson: nil, model: nil, problem: nil, lastTraceId: nil, nextRunAt: now,
                                          createdAt: now, updatedAt: now)
            try record.insert(db)
            let id = record.id ?? 0
            try HistoryStore.insert(db, .taskCreated, at: now, actor: .user,
                                    summary: "Asked for “\(SearchTaskStore.name(record, config: config))”, "
                                        + Self.reading(effort: effort, profile: profile, settings: settings),
                                    payload: TaskEventPayload(task: id, documents: nil, plan: nil))
            return id
        }
        await queue.wake()
        return try await task(id)
    }

    /// Renames the task, arranges its set otherwise, or gives it another prompt, effort or profile, each of which sends it
    /// back into the queue to be read again. A profile the settings do not list is refused, and nothing is changed.
    @discardableResult
    public func update(_ id: Int64, _ change: SearchTaskChange) async throws -> SearchTask {
        let prompt = try change.prompt.map(Self.prompt)
        if case let .by(kinds) = change.grouping { try validate(kinds) }
        let settings = await services.settings.current
        let profile = try change.profile.map { try Self.profile($0, settings: settings) }
        let now = services.time.now()
        let config = config
        let requeued = try await services.database.writer.write { db -> Bool in
            guard var record = try SearchTaskRecord.fetchOne(db, key: id) else { throw SearchTaskError.taskNotFound(id) }
            var changed: [String] = []
            if let title = change.title.map(DocumentLabel.oneLine) {
                let kept = title.isEmpty ? nil : DocumentLabel.shortened(title, to: config.maxTitleChars)
                if kept != record.title { record.title = kept; changed.append("name") }
            }
            var reread: [String] = []
            if let prompt, prompt != record.prompt {
                record.prompt = prompt
                reread.append("prompt")
            }
            if let effort = change.effort, effort != record.effort {
                record.effort = effort
                reread.append("effort")
            }
            if let profile, profile != record.profile {
                record.profile = profile
                reread.append("profile")
            }
            let requeued = !reread.isEmpty
            if requeued {
                record.state = .queued
                record.problem = nil
                record.nextRunAt = now
                changed += reread
            }
            if let grouping = change.grouping {
                let json: String? = switch grouping {
                case .asAsked: nil
                case let .by(kinds): JSON.string(kinds)
                }
                if json != record.groupingJson { record.groupingJson = json; changed.append("arrangement") }
            }
            guard !changed.isEmpty else { return false }
            record.updatedAt = now
            try record.update(db)
            try HistoryStore.insert(db, .taskEdited, at: now, actor: .user,
                                    summary: "Changed the \(changed.joined(separator: ", ")) of “\(SearchTaskStore.name(record, config: config))”"
                                        + (requeued ? ", " + Self.reading(effort: record.effort, profile: record.profile, settings: settings) : ""),
                                    payload: TaskEventPayload(task: id, documents: nil, plan: nil))
            return requeued
        }
        if requeued { await queue.wake() }
        return try await task(id)
    }

    /// Sends the task back into the queue to find its documents again, as after new documents were filed.
    @discardableResult
    public func retry(_ id: Int64) async throws -> SearchTask {
        let now = services.time.now()
        let config = config
        try await services.database.writer.write { db in
            guard var record = try SearchTaskRecord.fetchOne(db, key: id) else { throw SearchTaskError.taskNotFound(id) }
            guard !record.state.isActive else { return }
            record.state = .queued
            record.problem = nil
            record.nextRunAt = now
            record.updatedAt = now
            try record.update(db)
            try HistoryStore.insert(db, .taskEdited, at: now, actor: .user,
                                    summary: "Asked again for “\(SearchTaskStore.name(record, config: config))”",
                                    payload: TaskEventPayload(task: id, documents: nil, plan: nil))
        }
        await queue.wake()
        return try await task(id)
    }

    /// Adds documents to the task's set: one the user took out comes back, and finding the documents again keeps them.
    /// Returns the documents that were not in the set before.
    @discardableResult
    public func add(_ id: Int64, documents: [Int64]) async throws -> [Int64] {
        let now = services.time.now()
        let config = config
        return try await services.database.writer.write { db in
            guard let record = try SearchTaskRecord.fetchOne(db, key: id) else { throw SearchTaskError.taskNotFound(id) }
            let members = Dictionary(try SearchTaskStore.members(db, task: id).map { ($0.document, $0.inclusion) }, uniquingKeysWith: { a, _ in a })
            var added: [Int64] = []
            for document in documents where !added.contains(document) {
                guard try DocumentRecord.exists(db, key: document) else { throw SearchTaskError.documentNotFound(document) }
                guard members[document] == nil || members[document] == .removed else { continue }
                try SearchTaskStore.include(db, task: id, document: document, as: .added)
                added.append(document)
            }
            guard !added.isEmpty else { return [] }
            let count = try SearchTaskStore.members(db, task: id).filter { $0.inclusion != .removed }.count
            try HistoryStore.insert(db, .taskEdited, at: now, actor: .user,
                                    summary: "Added \(Format.count(added.count, "document")) to “\(SearchTaskStore.name(record, config: config))”",
                                    payload: TaskEventPayload(task: id, documents: count, plan: nil))
            return added
        }
    }

    /// Adds every document in the archive that has all these labels, as the sidebar narrows them down
    /// (`DocumentFilter.labels`): at most `tasks.maxDocuments`, the newest by their own date, as a task finds them
    /// (`SearchPlanMatcher`). Returns the documents that were not in the set before.
    @discardableResult
    public func add(_ id: Int64, labelled labels: [DocumentLabel]) async throws -> [Int64] {
        let documents = try await services.documents.list(DocumentFilter(statuses: DocumentStatus.inArchive, labels: labels),
                                                          order: .documentDate, limit: config.maxDocuments)
        return try await add(id, documents: documents.compactMap(\.id))
    }

    /// Takes documents out of the task's set; finding the documents again leaves them out. Returns those that were in it.
    @discardableResult
    public func remove(_ id: Int64, documents: [Int64]) async throws -> [Int64] {
        let now = services.time.now()
        let config = config
        return try await services.database.writer.write { db in
            guard let record = try SearchTaskRecord.fetchOne(db, key: id) else { throw SearchTaskError.taskNotFound(id) }
            let members = Dictionary(try SearchTaskStore.members(db, task: id).map { ($0.document, $0.inclusion) }, uniquingKeysWith: { a, _ in a })
            var removed: [Int64] = []
            for document in documents where !removed.contains(document) {
                guard let inclusion = members[document], inclusion != .removed else { continue }
                try SearchTaskStore.include(db, task: id, document: document, as: .removed)
                removed.append(document)
            }
            guard !removed.isEmpty else { return [] }
            let count = try SearchTaskStore.members(db, task: id).filter { $0.inclusion != .removed }.count
            try HistoryStore.insert(db, .taskEdited, at: now, actor: .user,
                                    summary: "Took \(Format.count(removed.count, "document")) out of “\(SearchTaskStore.name(record, config: config))”",
                                    payload: TaskEventPayload(task: id, documents: count, plan: nil))
            return removed
        }
    }

    /// Removes the task with its set and the record of its exports. What it exported stays where it was put: the copies
    /// are the user's. The queue no longer counts it among the tasks waiting.
    public func delete(_ id: Int64) async throws {
        let now = services.time.now()
        let config = config
        try await services.database.writer.write { db in
            guard let record = try SearchTaskRecord.fetchOne(db, key: id) else { throw SearchTaskError.taskNotFound(id) }
            _ = try record.delete(db)
            try HistoryStore.insert(db, .taskRemoved, at: now, actor: .user, summary: "Removed “\(SearchTaskStore.name(record, config: config))”",
                                    payload: TaskEventPayload(task: id, documents: nil, plan: record.plan))
        }
        await queue.wake()
    }

    /// Copies the task's set into a new folder in `folder`, named after the task, in folders of folders as its set is
    /// arranged, or into a ZIP archive of that folder, and records the export with the task.
    @discardableResult
    public func export(_ id: Int64, to folder: URL, format: ExportFormat) async throws -> SearchTaskExport {
        guard let detail = try await store.detail(id: id) else { throw SearchTaskError.taskNotFound(id) }
        guard detail.tree.count > 0 else { throw SearchTaskError.nothingToExport(id) }
        let incoming = await services.settings.current.incomingURL
        let exporter = SearchTaskExporter(naming: services.config.naming, tasks: config, excluded: [services.archive, incoming])
        let (path, manifest) = try exporter.export(detail, into: folder, format: format)
        let now = services.time.now()
        let config = config
        return try await services.database.writer.write { db in
            guard let record = try SearchTaskRecord.fetchOne(db, key: id) else { throw SearchTaskError.taskNotFound(id) }
            var export = SearchTaskExportRecord(id: nil, taskId: id, at: now, format: format, path: path.path, manifestJson: JSON.string(manifest))
            try export.insert(db)
            try HistoryStore.insert(db, .taskExported, at: now, actor: .user,
                                    summary: "Exported \(Format.count(manifest.files.count, "document")) of “\(SearchTaskStore.name(record, config: config))” "
                                        + "to \(path.path)" + (manifest.skipped.isEmpty ? "" : "; \(manifest.skipped.count) could not be copied"),
                                    payload: TaskEventPayload(task: id, documents: manifest.files.count, plan: nil))
            guard let recorded = export.export else { throw SearchTaskError.exportFailed(path.path, "the export could not be recorded") }
            return recorded
        }
    }

    private func task(_ id: Int64) async throws -> SearchTask {
        guard let task = try await store.task(id: id) else { throw SearchTaskError.taskNotFound(id) }
        return task
    }

    /// The prompt on one line; an empty one asks for nothing.
    static func prompt(_ text: String) throws -> String {
        let prompt = DocumentLabel.oneLine(text)
        guard !prompt.isEmpty else { throw SearchTaskError.emptyPrompt }
        return prompt
    }

    /// A profile's id on one line, one `settings` list (`ModelProfileError.unknown` otherwise); nil for none, which leaves
    /// the task to the profile Settings uses.
    static func profile(_ text: String, settings: AppSettings) throws -> String? {
        let id = DocumentLabel.oneLine(text)
        guard !id.isEmpty else { return nil }
        _ = try settings.modelProfile(id)
        return id
    }

    /// How a task is read, for History: “read with high effort by Smart”, its profile by name, or “… by Settings'
    /// profile” for one that follows the profile Settings uses.
    static func reading(effort: TaskEffort, profile: String?, settings: AppSettings) -> String {
        "read with \(effort.rawValue) effort by " + (profile.map { settings.modelProfiles[$0]?.name ?? "“\($0)”" } ?? "Settings' profile")
    }

    private func validate(_ kinds: [LabelKind]) throws {
        guard kinds.count <= config.maxGroupingDepth else { throw SearchTaskError.groupingTooDeep(config.maxGroupingDepth) }
        var seen = Set<LabelKind>()
        for kind in kinds where !seen.insert(kind).inserted { throw SearchTaskError.groupingRepeats(kind) }
    }
}
