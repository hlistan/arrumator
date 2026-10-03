import Foundation
import GRDB

extension AppDatabase {
    /// Registers the migrations of the documents found in two places of the archive, in the order they shipped, after
    /// `v24_documentLabels`.
    static func registerTwoPlacesMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v25_documentsInTwoPlaces", migrate: documentsInTwoPlacesMigration)
    }

    /// `v25_documentsInTwoPlaces`. One row for each place of a document found in more than one place of the archive, when
    /// nothing told which is a copy (`DocumentInTwoPlaces`), by its identifier and by the place, each a key, so a rebuild
    /// that notes thousands of them and the archive watcher that asks of one file each do so by a key. It is the index's
    /// own: no record file holds it, and a rebuild finds the places again.
    static func documentsInTwoPlacesMigration(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE documents_in_two_places (
          uid TEXT NOT NULL,
          doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          path TEXT NOT NULL,
          PRIMARY KEY (uid, path)) WITHOUT ROWID;
        CREATE INDEX documents_in_two_places_path ON documents_in_two_places(path);
        """)
    }
}
