import Foundation

/// What a search task's prompt asks for, as the local model reads it (`SearchPromptInterpreting`): the labels the
/// documents must have, the words they must contain, how to arrange what is found, and a name for it.
///
/// Labels are criteria the way faceted search combines them: the labels of one kind are alternatives, and the kinds
/// narrow each other down, so `type: invoice` with `topic: electricity, water` finds the invoices about either
/// (Hearst, "Design Recommendations for Hierarchical Faceted Search Interfaces", SIGIR 2006; Tunkelang, "Faceted Search",
/// 2009; docs/organizing-principles-sources.md#sources-for-search-tasks).
public struct SearchPlan: Sendable, Codable, Hashable {
    /// A short name for what the prompt asks for, in its language.
    public var title: String
    /// Every kind given must be matched by one of its labels. A date, period or deadline is a year, a month, a day or a
    /// span of them (`start/end`); any other label is matched by its words (`SearchPlan.matches`).
    public var labels: [DocumentLabel]
    /// Words every document found must contain, in its text, its file name or its labels: what no label says.
    public var words: [String]
    /// The kinds of label what is found is arranged by, the outermost first; empty for the task's default.
    public var grouping: [LabelKind]

    public init(title: String, labels: [DocumentLabel], words: [String], grouping: [LabelKind]) {
        self.title = title
        self.labels = labels
        self.words = words
        self.grouping = grouping
    }

    /// Whether the plan asks for anything at all: a plan without labels or words would find every document.
    public var isEmpty: Bool { labels.isEmpty && words.isEmpty }

    /// The kinds whose labels are dates, matched and arranged by the time they stand for.
    public static let timeKinds: Set<LabelKind> = [.date, .period, .deadline]

    /// Whether a document labelled with `labels` has, for every kind the plan gives, one of the plan's labels. A date,
    /// period or deadline matches when the two spans of time overlap: `2025` finds the date `2025-03-05` and the period
    /// `2024-07/2025-06`. Any other label matches when the plan's words stand together in it, whatever their case,
    /// accents or punctuation: `EDP` finds `EDP Comercial`, `tax return` the type `tax-return`, `portuguese` the
    /// language `pt`. A value with nothing to match by (no letters, digits or calendar day) asks for nothing.
    public func matches(_ labels: [DocumentLabel]) -> Bool {
        Dictionary(grouping: self.labels, by: \.kind).allSatisfy { kind, wanted in
            let have = labels.filter { $0.kind == kind }
            if Self.timeKinds.contains(kind) {
                let spans = wanted.compactMap { TimeSpan($0.value) }
                return spans.isEmpty || have.contains { label in TimeSpan(label.value).map { span in spans.contains { $0.overlaps(span) } } ?? false }
            }
            let keys = wanted.map { LabelUsage.searchKey($0.value) }.filter { !$0.isEmpty }
            return keys.isEmpty || have.contains { label in
                let written = " " + LabelUsage.searchKey(DocumentLabel.searchText([label], kind: kind)) + " "
                return keys.contains { written.contains(" " + $0 + " ") }
            }
        }
    }
}

/// A span of calendar days, as a date, period or deadline label stands for one: a year is its first to its last day, a
/// month likewise, a day itself, and `start/end` from the start of one to the end of the other. Days are ISO 8601
/// strings, whose order is the calendar's.
public struct TimeSpan: Sendable, Hashable {
    public var first: String
    public var last: String

    /// The span `text` stands for, in any form `DocumentLabel.normalized` keeps for a period; nil for anything else.
    public init?(_ text: String) {
        guard let period = DocumentLabel.normalized(text, kind: .period)?.value else { return nil }
        let bounds = period.split(separator: "/").map(String.init)
        guard let start = bounds.first, let end = bounds.last else { return nil }
        first = Self.bound(start, last: false)
        last = Self.bound(end, last: true)
    }

    /// Whether the two share a day.
    public func overlaps(_ other: TimeSpan) -> Bool { first <= other.last && other.first <= last }

    /// The year of the span's start: what a date, period or deadline is arranged by.
    public var year: String { String(first.prefix(Self.yearLength)) }

    /// `YYYY`, `YYYY-MM` or `YYYY-MM-DD` as its first or last day. A month's last day is written as its 31st, which
    /// sorts after every day of that month and before the next: enough for comparing, never shown.
    private static func bound(_ value: String, last: Bool) -> String {
        switch value.count {
        case yearLength: value + (last ? "-12-31" : "-01-01")
        case monthLength: value + (last ? "-31" : "-01")
        default: value
        }
    }

    /// The lengths of an ISO 8601 year and month: `2025`, `2025-03`.
    static let yearLength = 4
    static let monthLength = 7
}

/// How the model read a search task's prompt: the plan, and which model gave it; or why there is none.
public struct SearchInterpretation: Sendable, Codable, Hashable {
    public var plan: SearchPlan?
    public var model: String?
    /// Why there is no plan, such as the model giving no valid answer.
    public var problem: String?

    public init(plan: SearchPlan?, model: String?, problem: String?) {
        self.plan = plan
        self.model = model
        self.problem = problem
    }
}

/// Reads what a person asks for, in their own words and language, as a `SearchPlan`. Implemented by
/// `ArrumatorClassify.SearchPromptInterpreter`.
public protocol SearchPromptInterpreting: Sendable {
    /// `effort` is how much that model thinks before it answers (`tasks.efforts`), and `profile` the model profile whose
    /// chat model reads it: the task's own, else the one Settings uses. `vocabulary` is the archive's labels in use, the most used
    /// first, which the model is shown so it asks for them as the archive writes them; `today` is the ISO day the prompt
    /// is read on, which "last year" counts from. Without a valid answer the interpretation says why and has no plan; a
    /// model that cannot be reached throws, so the task waits, and one that is missing throws, so the task fails saying
    /// which it needs.
    func interpret(_ prompt: String, effort: TaskEffort, profile: ModelProfile, vocabulary: [LabelKind: [LabelUsage]], today: String,
                   config: PipelineConfig, trace: TraceContext) async throws -> SearchInterpretation
}

/// How much the model thinks before it answers a search task's request: low not at all, medium, high the most. Which
/// model reads is the profile's. Each is a preset in `tasks.efforts` of what the model is told about thinking, with the
/// answer length and time thinking needs, how often a wrong answer goes back to it and how much of the archive's
/// vocabulary it is shown (`EffortPreset`).
public enum TaskEffort: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    case low, medium, high
}

/// Where a search task is in the queue.
public enum SearchTaskState: String, Sendable, Codable, CaseIterable {
    /// Waiting for the model to read its prompt.
    case queued
    /// The model is reading its prompt.
    case interpreting
    /// Its documents are found and arranged, ready to be looked over and exported.
    case ready
    /// The model could not read its prompt; `problem` says why.
    case failed

    /// Still in the queue.
    public var isActive: Bool { self == .queued || self == .interpreting }
}

/// How a document belongs to a task's set, or not.
public enum SetInclusion: String, Sendable, Codable, CaseIterable {
    /// Found by the task's plan.
    case matched
    /// Added by the user.
    case added
    /// Taken out by the user: finding the documents again leaves it out.
    case removed
}

/// What an export is delivered as.
public enum ExportFormat: String, Sendable, Codable, CaseIterable {
    /// A folder of folders, one level per kind the set is arranged by.
    case folder
    /// The same folder, packed as a ZIP archive.
    case zip
}

/// One document as an export holds it: which, and where inside the export, below its top folder.
public struct ExportedFile: Sendable, Codable, Hashable {
    public var document: Int64
    public var path: String

    public init(document: Int64, path: String) {
        self.document = document
        self.path = path
    }
}

/// A document of the set an export could not hold, and why.
public struct SkippedFile: Sendable, Codable, Hashable {
    public var document: Int64
    public var reason: String

    public init(document: Int64, reason: String) {
        self.document = document
        self.reason = reason
    }
}

/// What an export holds.
public struct ExportManifest: Sendable, Codable, Hashable {
    public var files: [ExportedFile]
    public var skipped: [SkippedFile]

    public init(files: [ExportedFile], skipped: [SkippedFile]) {
        self.files = files
        self.skipped = skipped
    }
}

/// A set of documents as a task delivered it: when, as what, where, and which documents it held.
public struct SearchTaskExport: Sendable, Codable, Hashable, Identifiable {
    public var id: Int64
    public var at: Date
    public var format: ExportFormat
    /// The folder or ZIP archive made.
    public var path: String
    public var files: [ExportedFile]
    public var skipped: [SkippedFile]

    public init(id: Int64, at: Date, format: ExportFormat, path: String, files: [ExportedFile], skipped: [SkippedFile]) {
        self.id = id
        self.at = at
        self.format = format
        self.path = path
        self.files = files
        self.skipped = skipped
    }
}

/// A search task as the app and the command line show it: what was asked, how the model read it, the set of documents
/// it prepared as the user edited it, and every export of it.
public struct SearchTask: Sendable, Codable, Hashable, Identifiable {
    public var id: Int64
    /// The name it goes by: the user's, else the model's, else its prompt.
    public var name: String
    public var prompt: String
    /// The name the user gave it; nil for the model's.
    public var title: String?
    public var state: SearchTaskState
    public var plan: SearchPlan?
    /// The kinds the set is arranged by, the outermost first: the user's, else the plan's, else `tasks.defaultGrouping`.
    public var grouping: [LabelKind]
    /// Whether the user chose `grouping`.
    public var groupedByUser: Bool
    /// How much the model thinks before it answers its request.
    public var effort: TaskEffort
    /// The id of the model profile the user gave it to read its request; nil to follow the one Settings uses, whichever
    /// that is when it is read.
    public var profile: String?
    /// The model that read its request last.
    public var model: String?
    public var problem: String?
    /// The documents in the set, in the order they joined it.
    public var documents: [Int64]
    /// Documents the user added, and those taken out, which finding the documents again respects.
    public var added: [Int64]
    public var removed: [Int64]
    /// Every export, oldest first.
    public var exports: [SearchTaskExport]
    /// The trace of the last time its prompt was read; nil before, and after a rebuild.
    public var lastTrace: Int64?
    public var createdAt: Date
    public var updatedAt: Date
}

/// Documents arranged by their labels, a level per kind: what a task found, shown and exported as a tree of folders.
public struct LabelGroup: Sendable, Codable, Hashable {
    /// The kind this group's documents share a label of; nil for the whole set.
    public var kind: LabelKind?
    /// The label they share, a year for a date, period or deadline; nil for those without a label of `kind`, and for the
    /// whole set.
    public var value: String?
    /// The groups of the next kind, when the set is arranged by one more.
    public var groups: [LabelGroup]
    /// The documents at this level: none when it has groups.
    public var documents: [DocumentRecord]

    public init(kind: LabelKind?, value: String?, groups: [LabelGroup], documents: [DocumentRecord]) {
        self.kind = kind
        self.value = value
        self.groups = groups
        self.documents = documents
    }

    /// Every document in the group and the groups below it.
    public var count: Int { documents.count + groups.reduce(0) { $0 + $1.count } }
    /// Every document in the group and the groups below it, those at this level first.
    public var allDocuments: [DocumentRecord] { documents + groups.flatMap(\.allDocuments) }
}

/// A task and its set, arranged.
public struct SearchTaskDetail: Sendable, Codable, Hashable {
    public var task: SearchTask
    public var tree: LabelGroup

    public init(task: SearchTask, tree: LabelGroup) {
        self.task = task
        self.tree = tree
    }
}
