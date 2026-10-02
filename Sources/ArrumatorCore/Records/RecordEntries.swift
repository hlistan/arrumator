import Foundation

/// The version stamped at the top of every record file, so a future format can tell old files apart.
public enum RecordSchema {
    public static let version = 1
}

/// One document, as the `_documents.md` of its directory records it. The file is named, not located: the entry
/// sits next to the document, so moving or renaming the directory never touches it.
public struct DocumentEntry: Codable, Sendable, Hashable {
    public var id: Int64
    public var uid: String
    public var file: String
    public var originalName: String
    public var sha256: String
    public var size: Int64
    public var contentType: String
    public var status: DocumentStatus
    public var pages: Int?
    /// What the document is described by; absent while it has no labels and has not been labelled.
    public var labels: [DocumentLabel]?
    /// True while its labels are only its tags because the model has not labelled it yet; absent otherwise. Never `tags`,
    /// which entries of versions that filed into folders hold topics under.
    public var tagsOnly: Bool?
    public var duplicateOf: Int64?
    /// How the model read the document: its name, the model, why it waits for the user.
    public var analysis: DocumentAnalysis?
    public var added: Date
    public var filed: Date?

    /// In the order a person reads an entry, with the full analysis last.
    enum CodingKeys: String, CodingKey {
        case id, uid, file
        case originalName = "original_name"
        case added, filed, status, pages, labels
        case tagsOnly = "tags_only"
        case duplicateOf = "duplicate_of"
        case contentType = "content_type"
        case size, sha256, analysis
    }

    public init?(_ record: DocumentRecord) {
        guard let id = record.id else { return nil }
        self.id = id
        uid = record.uid
        file = record.filename
        originalName = record.originalFilename
        sha256 = record.sha256
        size = record.size
        contentType = record.uttype
        status = record.status
        pages = record.pageCount
        labels = record.labels
        tagsOnly = record.tagsOnly ? true : nil
        duplicateOf = record.duplicateOf
        analysis = record.analysis
        added = record.addedAt
        filed = record.filedAt
    }

    /// The index row for this entry in `directory`. What the index caches about the file (its text, inode, times of
    /// extraction) starts empty and is filled in again when the document is read. Labels are kept as the index keeps
    /// them (`DocumentLabel.stored`), so an entry edited by hand to give a document a label of another kind than a tag
    /// labels it, as a correction in the app does.
    public func record(directory: URL, now: Date) -> DocumentRecord {
        let stored = labels.map { DocumentLabel.stored($0, labelled: tagsOnly != true) } ?? (labels: nil, tagsOnly: false)
        return DocumentRecord(id: id, uid: uid, path: directory.appendingPathComponent(file).path, originalFilename: originalName,
                              sha256: sha256, size: size, uttype: contentType, inode: nil, pageCount: pages, status: status,
                              analysisJson: analysis.map { JSON.string($0) }, contentJson: nil, labelsJson: stored.labels.map { JSON.string($0) },
                              tagsOnly: stored.tagsOnly, duplicateOf: duplicateOf, lastTraceId: nil, addedAt: added, filedAt: filed,
                              extractedAt: nil, embeddedAt: nil, fileMtime: nil, createdAt: added, updatedAt: now)
    }
}

/// One event as a history file records it. The job and trace it pointed at are the index's own and are not kept.
public struct EventEntry: Codable, Sendable, Hashable {
    public var id: Int64
    public var at: Date
    public var kind: EventKind
    public var actor: EventActor
    public var document: Int64?
    public var summary: String
    public var payload: String

    public init?(_ record: EventRecord) {
        guard let id = record.id else { return nil }
        self.id = id
        at = record.at
        kind = record.kind
        actor = record.actor
        document = record.docId
        summary = record.summary
        payload = record.payloadJson
    }

    public var record: EventRecord {
        EventRecord(id: id, at: at, docId: document, jobId: nil, traceId: nil, kind: kind, actor: actor, summary: summary,
                    payloadJson: payload)
    }
}

/// One of the user's rules for labels, as `System/_labels.md` records it.
public struct LabelRuleEntry: Codable, Sendable, Hashable {
    public var id: Int64
    public var kind: LabelKind
    public var value: String
    public var action: LabelRuleAction
    public var target: String?
    public var created: Date

    public init?(_ rule: LabelRule) {
        guard let id = rule.id else { return nil }
        self.id = id
        kind = rule.kind
        value = rule.value
        action = rule.action
        target = rule.target
        created = rule.createdAt
    }

    public var record: LabelRule {
        LabelRule(id: id, kind: kind, value: value, action: action, target: target, createdAt: created)
    }
}

/// One of the user's search tasks, as `System/_tasks.md` records it: what was asked, what the model read it as, the
/// documents of its set by number (those the user took out among them), and its exports. The trace and queue times are
/// the index's own and are not kept; a task whose prompt was being read is queued again. The model an earlier version
/// gave a task (`assignedModel`) is not read: a model is not a profile, so that task follows Settings' profile, as
/// `v16_taskProfile` has it.
public struct SearchTaskEntry: Codable, Sendable, Hashable {
    public var id: Int64
    public var prompt: String
    public var title: String?
    public var grouping: [LabelKind]?
    public var state: SearchTaskState
    public var effort: TaskEffort
    /// The id of the model profile the user gave the task; absent for one that follows the profile Settings uses.
    public var profile: String?
    public var plan: SearchPlan?
    public var model: String?
    public var problem: String?
    public var documents: [Member]
    public var exports: [Export]
    public var created: Date
    public var updated: Date

    public struct Member: Codable, Sendable, Hashable {
        public var document: Int64
        public var inclusion: SetInclusion
    }

    public struct Export: Codable, Sendable, Hashable {
        public var id: Int64
        public var at: Date
        public var format: ExportFormat
        public var path: String
        public var files: [ExportedFile]
        public var skipped: [SkippedFile]
    }

    /// In the order a person reads an entry, with the plan, the set and the exports last.
    enum CodingKeys: String, CodingKey {
        case id, prompt, title, state, effort, profile, grouping, model, problem, created, updated, plan, documents, exports
    }

    init?(_ record: SearchTaskRecord, members: [SetMember], exports: [SearchTaskExportRecord]) {
        guard let id = record.id else { return nil }
        self.id = id
        prompt = record.prompt
        title = record.title
        grouping = record.userGrouping
        state = record.state
        effort = record.effort
        profile = record.profile
        plan = record.plan
        model = record.model
        problem = record.problem
        documents = members.map { Member(document: $0.document, inclusion: $0.inclusion) }
        self.exports = exports.compactMap { $0.export.map { Export(id: $0.id, at: $0.at, format: $0.format, path: $0.path, files: $0.files,
                                                                    skipped: $0.skipped) } }
        created = record.createdAt
        updated = record.updatedAt
    }

    var record: SearchTaskRecord {
        SearchTaskRecord(id: id, prompt: prompt, title: title, groupingJson: grouping.map { JSON.string($0) }, effort: effort,
                         profile: profile, state: state == .interpreting ? .queued : state, planJson: plan.map { JSON.string($0) }, model: model,
                         problem: problem, lastTraceId: nil, nextRunAt: state.isActive ? created : nil, createdAt: created, updatedAt: updated)
    }

    var exportRecords: [SearchTaskExportRecord] {
        exports.map { SearchTaskExportRecord(id: $0.id, taskId: id, at: $0.at, format: $0.format, path: $0.path,
                                             manifestJson: JSON.string(ExportManifest(files: $0.files, skipped: $0.skipped))) }
    }
}

/// A question about a search task's documents and its answer, as the task's file in `System/Conversations` records it.
/// The trace and queue times are the index's own and are not kept; a question that was being answered is queued again.
public struct ConversationTurnEntry: Codable, Sendable, Hashable {
    public var id: Int64
    public var question: String
    public var state: TurnState
    public var answer: String?
    /// Absent while the answer draws on none.
    public var sources: [Int64]?
    public var finding: TurnFinding?
    public var model: String?
    public var problem: String?
    public var asked: Date
    public var answered: Date?

    /// In the order a person reads an entry, with the answer and what it found last.
    enum CodingKeys: String, CodingKey {
        case id, asked, question, state, model, problem, answered, answer, sources, finding
    }

    init?(_ record: TaskTurnRecord) {
        guard let id = record.id else { return nil }
        self.id = id
        question = record.question
        state = record.state
        answer = record.answer
        sources = record.sources.isEmpty ? nil : record.sources
        finding = record.finding
        model = record.model
        problem = record.problem
        asked = record.askedAt
        answered = record.answeredAt
    }

    func record(task: Int64) -> TaskTurnRecord {
        TaskTurnRecord(id: id, taskId: task, question: question, state: state == .answering ? .queued : state, answer: answer,
                       sourcesJson: sources.map { JSON.string($0) }, findingJson: finding.map { JSON.string($0) }, model: model,
                       problem: problem, lastTraceId: nil, nextRunAt: state.isActive ? asked : nil, askedAt: asked, answeredAt: answered)
    }
}

/// The front matter of a file holding a list.
struct RecordList<Entry: Codable & Sendable>: Codable, Sendable {
    var arrumator: Int
    var entries: [Entry]

    init(_ entries: [Entry]) {
        arrumator = RecordSchema.version
        self.entries = entries
    }
}
