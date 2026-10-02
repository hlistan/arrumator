import Foundation

/// A tag a file is given when it is queued, and what gave it (docs/how-it-works.md#folders-in-incoming): the folder at the
/// top of Incoming it was put in (`IncomingFolders`), or the command that filed it (`arrumatorcli ingest --tag`). It is
/// kept with the file's job (`JobPayload.tags`), so the queue shows it before the file is read and a stop and a restart
/// keep it, and the document is given it as soon as it is one, as the user's rules write it (`PipelineServices.giveTags`).
public struct GivenTag: Sendable, Codable, Hashable {
    /// What gave a tag.
    public enum Source: String, Sendable, Codable, Hashable {
        /// The folder at the top of Incoming the file is in, whose path is `folder`.
        case folder
        /// The command that filed the file.
        case command
        /// The document, which has it already and keeps it when it is read again.
        case document
    }

    /// The tag, a label of kind `tag`.
    public var label: DocumentLabel
    public var source: Source
    /// The folder that gives the tag, for one of `.folder`.
    public var folder: String?

    public init(label: DocumentLabel, source: Source, folder: String? = nil) {
        self.label = label
        self.source = source
        self.folder = folder
    }

    /// Whether this gives the document a tag it may not have yet, rather than naming one it has.
    public var isNew: Bool { source != .document }

    /// What History says of the tags a document was given or kept: `tagged “Taxes 2024” by its folder in Incoming`,
    /// `tagged “Mine” as asked`, `keeps its tags “Taxes 2024”, “Mine”`; nil when it has none.
    public static func note(_ tags: [GivenTag]) -> String? {
        func quoted(_ source: Source) -> (count: Int, text: String)? {
            let values = tags.filter { $0.source == source }.map { "“\($0.label.value)”" }
            return values.isEmpty ? nil : (values.count, values.joined(separator: ", "))
        }
        let parts = [quoted(.folder).map { "tagged \($0.text) by its folder in Incoming" },
                     quoted(.command).map { "tagged \($0.text) as asked" },
                     quoted(.document).map { "keeps its \($0.count == 1 ? "tag" : "tags") \($0.text)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Each of a document's `tags` with what gave it: the folder or command of `given` that gave it, else the document,
    /// which kept it.
    public static func sources(of tags: [DocumentLabel], given: [GivenTag]) -> [GivenTag] {
        tags.map { tag in given.first { $0.isNew && $0.label == tag } ?? GivenTag(label: tag, source: .document) }
    }

    /// Each tag once, however it is cased or accented, the first of each, and at most `limit` of them.
    static func distinct(_ tags: [GivenTag], limit: Int) -> [GivenTag] {
        let kept = Set(tags.map(\.label).distinct())
        var seen = Set<DocumentLabel>()
        return Array(tags.filter { kept.contains($0.label) && seen.insert($0.label).inserted }.prefix(limit))
    }
}

/// What History keeps of a file's arrival: where it is, and the tags it is given.
public struct ArrivedPayload: Sendable, Codable, Hashable {
    public var path: String
    /// Absent for a file given no tag, as in every arrival recorded before there were any.
    public var tags: [GivenTag]?
}

extension LabelsConfig {
    /// `value` as a label of `kind` keeps it (`DocumentLabel.normalized`), cut to `maxValueChars` after the last whole
    /// word that fits, as the model's labels are; nil when it is none.
    public func label(_ value: String, kind: LabelKind) -> DocumentLabel? {
        DocumentLabel.normalized(value, kind: kind).map { DocumentLabel(kind: $0.kind, value: DocumentLabel.shortened($0.value, to: maxValueChars)) }
    }

    /// Whether labels of `kind` are written freely, so the user may merge one into another or remove it everywhere on
    /// the Labels page: a kind the vocabulary keeps one (`vocabulary.kinds`), or the user's own tags, which nothing
    /// merges unasked. A kind of one form, a type, a date, a period, a deadline, an amount or a language, has nothing to
    /// merge.
    public func isWrittenFreely(_ kind: LabelKind) -> Bool {
        vocabulary.kinds[kind] != nil || kind.isUsersOwn
    }
}

extension DocumentLabel {
    /// How a document's labels are stored: the list, nil while it has none and has not been labelled, and whether they
    /// are only its tags because it has not been labelled yet (`DocumentRecord.tagsOnly`). A document is labelled once
    /// the model has read it (`labelled`), or once it has a label of another kind than a tag, such as one the user gave
    /// by hand; a tag alone labels nothing, being the user's own.
    public static func stored(_ labels: [DocumentLabel], labelled: Bool) -> (labels: [DocumentLabel]?, tagsOnly: Bool) {
        let isLabelled = labelled || labels.contains { !$0.kind.isUsersOwn }
        if isLabelled { return (labels, false) }
        return labels.isEmpty ? (nil, false) : (labels, true)
    }
}
