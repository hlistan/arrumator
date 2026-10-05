import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of labels the model joined in one, in the order they shipped, after
    /// `v25_documentsInTwoPlaces`.
    static func registerSplitLabelMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v26_storedLabelsInTheirForm", migrate: storedLabelsInTheirFormMigration)
    }

    /// A label as `documents.labels_json` held it when this migration shipped.
    private struct StoredLabel: Codable, Hashable {
        var kind: String
        var value: String
    }

    /// The kinds whose labels are names or words, each with a letter since this migration (`v26_storedLabelsInTheirForm`).
    private static let wordKinds: Set<String> = ["sender", "party", "topic", "object", "jurisdiction"]

    /// `v26_storedLabelsInTheirForm`. Before the model's answer was split at ";", one entry could hold two labels
    /// ("banking; account statement", QA 2026-10-04, READ-3), which no label of a kind the model gives may hold since: each
    /// such label is the labels it holds, each trimmed, once, in its place; the user's own tags, which may hold ";", stay as
    /// written. A name or a word without a letter, as a tax number given as a party, is no label of its kind since, and is
    /// dropped. The triggers on `documents` index the labels again and mark the document's record file to be written, so
    /// `_documents.md` holds them so too.
    static func storedLabelsInTheirFormMigration(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, labels_json FROM documents WHERE labels_json IS NOT NULL")
        for row in rows {
            guard let json: String = row["labels_json"], let labels = try? JSONDecoder().decode([StoredLabel].self, from: Data(json.utf8))
            else { continue }
            let outOfForm = labels.contains { label in
                label.kind != "tag" && (label.value.contains(";") || (wordKinds.contains(label.kind) && !label.value.contains(where: \.isLetter)))
            }
            guard outOfForm else { continue }
            var split: [StoredLabel] = []
            for label in labels {
                let parts = label.kind == "tag" ? [label.value]
                    : label.value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                for part in parts where !split.contains(StoredLabel(kind: label.kind, value: part))
                    && (!wordKinds.contains(label.kind) || part.contains(where: \.isLetter)) {
                    split.append(StoredLabel(kind: label.kind, value: part))
                }
            }
            guard split != labels else { continue }
            let id: Int64 = row["id"]
            try db.execute(sql: "UPDATE documents SET labels_json = ? WHERE id = ?",
                           arguments: [String(decoding: try JSONEncoder().encode(split), as: UTF8.self), id])
        }
    }
}
