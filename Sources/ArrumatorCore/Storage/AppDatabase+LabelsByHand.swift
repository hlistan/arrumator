// swiftlint:disable line_length - migration SQL is kept as written when it shipped
import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of the labels the user gives by hand, in the order they shipped, after `v28_sidecars`.
    static func registerLabelsByHandMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v29_labelsByHand", migrate: labelsByHandMigration)
    }

    /// A label as `documents.labels_json` held it when this migration shipped.
    private struct StoredLabel: Codable, Hashable {
        var kind: String
        var value: String
    }

    /// The kinds of label the model gave when this migration shipped: every kind but the user's own `tag`.
    private static let modelKinds: Set<String> = ["sender", "party", "type", "topic", "object", "reference", "date", "period",
                                                  "deadline", "amount", "jurisdiction", "language"]

    /// `v29_labelsByHand`. A label of a kind the model gives that the user gives a document by hand is the user's own, as
    /// a tag is, which reading the document again never takes the place of: `by_hand_json` lists those of its labels,
    /// NULL while it has none. No label was told apart so before, so it is marked where History tells it: replaying the
    /// user's corrections of each document in order (`correction`), a label one added and none took off after, that the
    /// document still has, written so, was given by hand. A label a correction says nothing of, as one made before
    /// corrections said what they changed, or renamed since, stays the model's, as every label was. The trigger that
    /// marks a document's record file follows the new column, so the record of each document marked is written again with
    /// its labels given by hand, and no other.
    static func labelsByHandMigration(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE documents ADD COLUMN by_hand_json TEXT;
        DROP TRIGGER documents_record_update;
        CREATE TRIGGER documents_record_update AFTER UPDATE OF path, original_filename, sha256, size, uttype, status, page_count, analysis_json, labels_json, tags_only, by_hand_json, duplicate_of, added_at, filed_at, uid ON documents BEGIN INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(OLD.path, replace(OLD.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; INSERT INTO record_dirty(key, version) VALUES ('documents:' || rtrim(NEW.path, replace(NEW.path, '/', '')), 1) ON CONFLICT(key) DO UPDATE SET version = version + 1; END;
        """)
        var given: [Int64: [StoredLabel]] = [:]
        for event in try Row.fetchAll(db, sql: """
            SELECT doc_id, summary FROM events WHERE kind = 'corrected' AND doc_id IS NOT NULL ORDER BY at, id
            """) {
            let (id, said): (Int64, String) = (event["doc_id"], event["summary"])
            let changed = correction(said)
            var labels = (given[id] ?? []).filter { !changed.removed.contains($0) }
            labels += changed.added.filter { !labels.contains($0) }
            given[id] = labels
        }
        for (id, labels) in given.sorted(by: { $0.key < $1.key }) where !labels.isEmpty {
            guard let json = try String.fetchOne(db, sql: "SELECT labels_json FROM documents WHERE id = ?", arguments: [id]),
                  let has = try? JSONDecoder().decode([StoredLabel].self, from: Data(json.utf8)) else { continue }
            let byHand = has.filter { modelKinds.contains($0.kind) && labels.contains($0) }
            guard !byHand.isEmpty else { continue }
            try db.execute(sql: "UPDATE documents SET by_hand_json = ? WHERE id = ?",
                           arguments: [String(decoding: try JSONEncoder().encode(byHand), as: UTF8.self), id])
        }
    }

    /// The labels a correction's History entry says it added and took off, as corrections have said them since they
    /// said what they changed (`ReviewActions.changes`): `Renamed to “…”; added sender “EDP”, topic “household”;
    /// removed type “invoice”`. None from an entry that says nothing of them, as those of earlier versions did
    /// (`Corrected labels`).
    private static func correction(_ said: String) -> (added: [StoredLabel], removed: [StoredLabel]) {
        func labels(_ list: Substring?) -> [StoredLabel] {
            guard let list else { return [] }
            return list.matches(of: /([a-z]+) “([^”]*)”/).map { StoredLabel(kind: String($0.output.1), value: String($0.output.2)) }
        }
        let added = said.firstMatch(of: /(?:^|; )added (.+?)(?=; removed |$)/)?.output.1
        let removed = said.firstMatch(of: /(?:^|; )removed (.+)$/)?.output.1
        return (labels(added), labels(removed))
    }
}
// swiftlint:enable line_length
