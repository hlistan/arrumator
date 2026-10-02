import Foundation
import GRDB

/// Finds the documents a search task's plan asks for among those in the archive (`DocumentStatus.inArchive`): those
/// whose labels match every kind the plan gives (`SearchPlan.matches`) and that contain every one of its words, each as
/// a phrase, in the full-text index. Labels are matched on the documents' own labels, so a document is found by them
/// even before its text has been read again after a rebuild. They come by their own date, the newest first and the
/// undated last (`DocumentOrder.documentDate`), and when more match than `limit`, the newest are kept. A plan that asks
/// for nothing finds nothing.
public struct SearchPlanMatcher: Sendable {
    public let database: AppDatabase
    public let limit: Int

    public init(database: AppDatabase, limit: Int) {
        self.database = database
        self.limit = limit
    }

    public func documents(_ plan: SearchPlan) async throws -> [Int64] {
        guard !plan.isEmpty else { return [] }
        let match = Self.phrases(plan.words)
        let statuses = DocumentStatus.inArchive.map(\.rawValue).sorted()
        let limit = limit
        return try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id, d.labels_json FROM documents d WHERE d.status IN (\(databaseQuestionMarks(count: statuses.count)))
                ORDER BY \(DocumentOrder.documentDate.sql)
                """, arguments: StatementArguments(statuses))
            var found = rows.compactMap { row -> Int64? in
                plan.matches(JSON.decode([DocumentLabel].self, from: row["labels_json"]) ?? []) ? row["id"] : nil
            }
            if let match {
                let withWords = Set(try Int64.fetchAll(db, sql: "SELECT rowid FROM document_fts WHERE document_fts MATCH ?", arguments: [match]))
                found = found.filter(withWords.contains)
            }
            return Array(found.prefix(limit))
        }
    }

    /// The words as a full-text query that needs every one of them, each a phrase: never a column filter or a prefix,
    /// whatever the model wrote. Nil when no word has anything to look for.
    static func phrases(_ words: [String]) -> String? {
        let quoted = words.map { $0.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { "\"\($0)\"" }
        return quoted.isEmpty ? nil : FTSQueryBuilder.build(quoted.joined(separator: " "))
    }
}
