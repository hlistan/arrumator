import Foundation
import GRDB

/// Chooses what an answer about a task's documents is shown (`TaskContext`): the set as it is when the question is
/// answered, so adding documents to it or taking them out changes what the next answer draws on.
///
/// The documents come in the order the question concerns them: first those the last answer drew on, which a question
/// such as "translate it" goes on about; then those the question concerns (`SearchService.relevance`); then the rest by
/// their own date, the newest first. In that order each is shown with its text, its start and its end cut to
/// `conversation.documentChars` as a document is read, while the text fits in `conversation.contextChars`; one whose text
/// does not fit, or that has none yet, is listed by its name, date and labels, at most `conversation.maxListed`, and the
/// answer is told how many more there are. A set the context holds is shown whole. The conversation so far is shown
/// up to `conversation.historyChars`, the latest exchanges kept, the latest cut to fit when it alone is longer.
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
    /// answered before it, the first asked first.
    public func context(for question: String, set: [Int64], earlier: [TaskTurn]) async throws -> TaskContext {
        let conversation = config.conversation
        let excerptDivisor = config.analysis.excerptTailDivisor
        let documents = try await database.reader.read { db in try Self.documents(db, ids: set, maxChars: conversation.documentChars,
                                                                                    tailDivisor: excerptDivisor) }
        let members = Set(set)
        let followed = (earlier.last(where: { $0.state == .answered })?.sources ?? []).filter(members.contains)
        let concerned = try await search.relevance(of: question, among: set)
        let dated = DocumentOrder.byDocumentDate(documents.map(\.record)).compactMap(\.id)
        var seen = Set<Int64>()
        let ranked = (followed + concerned + dated).filter { seen.insert($0).inserted }
        let byID = Dictionary(documents.map { ($0.record.id ?? 0, $0) }, uniquingKeysWith: { a, _ in a })

        var read: [ContextDocument] = []
        var others: [ContextDocument] = []
        var used = 0
        for id in ranked {
            guard let document = byID[id] else { continue }
            if let text = document.text, used + text.count <= conversation.contextChars {
                used += text.count
                read.append(document.shown(text: text))
            } else {
                others.append(document.shown(text: nil))
            }
        }
        let listed = Array(others.prefix(conversation.maxListed))
        return TaskContext(documents: read + listed, unlisted: others.count - listed.count,
                           conversation: Self.exchanges(earlier, maxChars: conversation.historyChars))
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

    /// A document of the set with its text as an answer may be shown it.
    struct Candidate {
        var record: DocumentRecord
        /// Its text cut to fit, or nil when it has none yet.
        var text: String?

        func shown(text: String?) -> ContextDocument {
            ContextDocument(id: record.id ?? 0, name: record.filename, date: record.documentDate, labels: record.labels ?? [], text: text)
        }
    }

    /// The documents with these numbers that the index has, each with its text as it was read (`ExtractedContent`, which
    /// describes an image too), its start and end cut to `maxChars`.
    static func documents(_ db: Database, ids: [Int64], maxChars: Int, tailDivisor: Int) throws -> [Candidate] {
        let records = try DocumentStore.documents(db, ids: ids)
        guard !records.isEmpty else { return [] }
        let bodies = Dictionary(try Row.fetchAll(db, sql: """
            SELECT doc_id, body FROM document_text WHERE doc_id IN (\(databaseQuestionMarks(count: ids.count)))
            """, arguments: StatementArguments(ids)).map { ($0["doc_id"] as Int64, $0["body"] as String? ?? "") }, uniquingKeysWith: { a, _ in a })
        return records.map { record in
            guard let id = record.id, var content = JSON.decode(ExtractedContent.self, from: record.contentJson) else {
                return Candidate(record: record, text: nil)
            }
            content.text = bodies[id] ?? ""
            let text = content.classificationExcerpt(maxChars: maxChars, tailDivisor: tailDivisor)
            return Candidate(record: record, text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text)
        }
    }
}
