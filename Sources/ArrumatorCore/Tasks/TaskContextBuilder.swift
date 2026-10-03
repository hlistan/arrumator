import Foundation
import GRDB

/// Chooses what an answer about a task's documents is shown (`TaskContext`): the set as it is when the question is
/// answered, so adding documents to it or taking them out changes what the next answer draws on.
///
/// The documents come in the order the question concerns them: first those the last answer drew on, which a question
/// such as "translate it" goes on about; then those the question concerns (`SearchService.relevance`); then the rest by
/// their own date, the newest first. In that order each is shown with its text, its start and its end cut to
/// `conversation.documentChars` as a document is read, while the text fits in `conversation.contextChars`; one whose text
/// does not fit, or that has none yet, is listed by its name, date and labels, at most `conversation.maxListed`. Once the
/// list is full, a document without text is passed over, and the first whose text is too long for the room left ends
/// the choice; the answer is told how many more there are. A set the context holds is shown whole. The documents are put
/// in order by their numbers alone, which of them have a text is told without reading it, and a document's text is read
/// only to be shown or listed (`choose`), so a question reads the text of the documents it shows or lists, and one more,
/// never of the whole set. The conversation so far is shown up to `conversation.historyChars`, the latest exchanges kept,
/// the latest cut to fit when it alone is longer.
public struct TaskContextBuilder: Sendable {
    public let database: AppDatabase
    public let search: SearchService
    public let config: PipelineConfig

    public init(database: AppDatabase, search: SearchService, config: PipelineConfig) {
        self.database = database
        self.search = search
        self.config = config
    }

    /// What an answer to `question` is shown of `set`, the documents of the task's set, with `earlier`, the questions
    /// answered before it, the first asked first; and how the documents were put in the order the question concerns
    /// them.
    public func context(for question: String, set: [Int64], earlier: [TaskTurn]) async throws -> ContextChoice {
        let conversation = config.conversation
        let excerptDivisor = config.analysis.excerptTailDivisor
        let members = Set(set)
        let followed = (earlier.last(where: { $0.state == .answered })?.sources ?? []).filter(members.contains)
        let relevance = try await search.relevance(of: question, among: set)
        let (chosen, held) = try await database.reader.read { db in
            let dated = try Self.byDocumentDate(db, ids: set)
            var seen = Set<Int64>()
            let ranked = (followed + relevance.documents + dated).filter { seen.insert($0).inserted }
            let withText = try Self.withText(db, ids: set)
            let chosen = try Self.choose(ranked, room: conversation.contextChars, maxListed: conversation.maxListed,
                                         hasText: withText.contains, record: { try DocumentRecord.fetchOne(db, key: $0) },
                                         text: { try Self.text(db, of: $0, maxChars: conversation.documentChars, tailDivisor: excerptDivisor) })
            return (chosen, dated.count)
        }
        return ContextChoice(shown: TaskContext(documents: chosen.read + chosen.listed, unlisted: held - chosen.read.count - chosen.listed.count,
                                                conversation: Self.exchanges(earlier, maxChars: conversation.historyChars)),
                             semanticUsed: relevance.semanticUsed, semanticUnavailableReason: relevance.semanticUnavailableReason)
    }

    /// The documents with these numbers that the index has, by number, in the order of their own date, the newest first
    /// (`DocumentOrder.documentDate`).
    static func byDocumentDate(_ db: Database, ids: [Int64]) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT d.id FROM documents d WHERE d.id IN (\(databaseQuestionMarks(count: ids.count))) ORDER BY \(DocumentOrder.documentDate.sql)
            """, arguments: StatementArguments(ids))
    }

    /// The documents with these numbers that have a text to be shown, told by the length of what was read of them
    /// without reading it: their text, or a description of what an image shows (`ExtractedContent.visual`, kept as the
    /// text's summary).
    static func withText(_ db: Database, ids: [Int64]) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: """
            SELECT d.id FROM documents d JOIN document_text t ON t.doc_id = d.id
            WHERE d.id IN (\(databaseQuestionMarks(count: ids.count))) AND d.content_json IS NOT NULL
            AND (length(t.body) > 0 OR t.summary IS NOT NULL)
            """, arguments: StatementArguments(ids)))
    }

    /// In `ranked` order, the documents shown with their text while it fits in `room`, and those listed by name, at most
    /// `maxListed`, whose text does not fit or that have none, each as `record` has it; one it does not have is passed
    /// over. Once the list is full, a document without text (`hasText`) is passed over unread, and the first whose text
    /// is too long for the room left ends the choice, as does the next document when there is no room left for any text.
    /// A document's text is read (`text`) only while there is room for it, so it is read for the documents shown and
    /// listed, and the one that ends the choice, at most.
    static func choose(_ ranked: [Int64], room: Int, maxListed: Int, hasText: (Int64) -> Bool, record: (Int64) throws -> DocumentRecord?,
                       text: (DocumentRecord) throws -> String?) rethrows -> (read: [ContextDocument], listed: [ContextDocument]) {
        var read: [ContextDocument] = []
        var listed: [ContextDocument] = []
        var used = 0
        for id in ranked {
            let listFull = listed.count >= maxListed
            // A text is at least a character long, so none fits once the room is full.
            if listFull && used >= room { break }
            guard !listFull || hasText(id), let document = try record(id) else { continue }
            if used < room, let shown = try text(document) {
                if used + shown.count <= room {
                    used += shown.count
                    read.append(Self.shown(document, text: shown))
                } else if listFull {
                    break
                } else {
                    listed.append(Self.shown(document, text: nil))
                }
            } else if !listFull {
                listed.append(Self.shown(document, text: nil))
            }
        }
        return (read, listed)
    }

    /// A document as an answer is shown it, with `text`, or by name alone when it is nil.
    static func shown(_ document: DocumentRecord, text: String?) -> ContextDocument {
        ContextDocument(id: document.id ?? 0, name: document.filename, date: document.documentDate, labels: document.labels ?? [], text: text)
    }

    /// `document`'s text as it was read (`ExtractedContent`, which describes an image too), its start and end cut to
    /// `maxChars`; nil when it has none yet.
    static func text(_ db: Database, of document: DocumentRecord, maxChars: Int, tailDivisor: Int) throws -> String? {
        guard let id = document.id, var content = JSON.decode(ExtractedContent.self, from: document.contentJson) else { return nil }
        content.text = try String.fetchOne(db, sql: "SELECT body FROM document_text WHERE doc_id = ?", arguments: [id]) ?? ""
        let text = content.classificationExcerpt(maxChars: maxChars, tailDivisor: tailDivisor)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// The questions answered before, the latest kept up to `maxChars`, the first asked first; the latest is cut to fit
    /// when it alone is longer, so a question about the answer just given always has it.
    static func exchanges(_ earlier: [TaskTurn], maxChars: Int) -> [Exchange] {
        var kept: [Exchange] = []
        var used = 0
        for turn in earlier.reversed() where turn.state == .answered {
            guard let answer = turn.answer else { continue }
            let size = turn.question.count + answer.count
            if used + size <= maxChars {
                kept.append(Exchange(question: turn.question, answer: answer))
                used += size
                continue
            }
            if kept.isEmpty {
                let room = max(0, maxChars - turn.question.count)
                if room > 0 { kept.append(Exchange(question: turn.question, answer: String(answer.prefix(room)) + Self.cut)) }
            }
            break
        }
        return kept.reversed()
    }

    /// What ends an answer cut to fit.
    static let cut = "…"

    /// What an answer is shown, and whether the documents of the set were put in order by the question's meaning as
    /// well as its words, or, when they were not, why (`SearchService.relevance`): what its trace records.
    public struct ContextChoice: Sendable {
        public var shown: TaskContext
        public var semanticUsed: Bool
        public var semanticUnavailableReason: String?
    }
}
