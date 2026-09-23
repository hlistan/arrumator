import Foundation
import GRDB
import Testing
@testable import ArrumatorCore

/// Installed databases record which migrations they have applied by identifier. These tests stop a shipped
/// identifier from being renamed, which made every installed app fail to start.
@Suite struct MigrationTests {
    /// Every identifier that has ever shipped, in order. Append new migrations; never rename or remove one.
    static let shipped = ["v1_initial", "v2_datesAsUnixSeconds", "v3_brainsAndRethink", "v4_renameBrainsToLogic",
                          "v5_logicEvents", "v6_archiveRecords", "v7_oneLogicPerArchive",
                          "v8_undoForgets"]

    @Test func shippedIdentifiersNeverChange() {
        let registered = AppDatabase.migrator.migrations
        #expect(Array(registered.prefix(Self.shipped.count)) == Self.shipped,
                "a shipped migration was renamed, removed or reordered; installed databases would re-run it and fail")
    }

    @Test func aDatabaseFromTheBrainsReleaseOpensWithItsDataIntact() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3_brainsAndRethink")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO brains (builtin_key, name, body, active, position, edited, created_at, updated_at)
                VALUES (NULL, 'Mine', 'File tax papers by year.', 1, 0, 1, 0, 0),
                       ('organizing-principles', 'Organizing principles', 'Built in.', 0, 1, 0, 0, 0),
                       (NULL, 'Draft', 'Cars under Vehicles.', 0, 2, 0, 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO traces (doc_id, job_id, attempt, source, started_at, app_version, prompt_version,
                                    taxonomy_version, settings_json, brains_version)
                VALUES (NULL, NULL, 0, 'ingest', 0, 'test', 1, 1, '{}', 'mine-1')
                """)
            try db.execute(sql: "INSERT INTO events (at, kind, actor, summary, payload_json) VALUES (0, 'brainChanged', 'user', 'Switched', '{}')")
        }

        // What the app does at launch.
        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let logic = try LogicRecord.fetchAll(db)
            #expect(logic.map(\.body) == ["File tax papers by year."], "the logic that was active is the archive's one logic")
            #expect(logic.first?.followsBuiltin == false, "logic the user wrote never follows the built-in text")
            #expect(try String.fetchOne(db, sql: "SELECT logic_version FROM traces") == "mine-1")
            #expect(try db.columns(in: "rules").contains { $0.name == "forgotten" })
            #expect(try !db.tableExists("brains"))
            let events = try EventRecord.order(Column("id")).fetchAll(db)
            #expect(events.map(\.kind) == [.logicChanged, .logicChanged], "events from then still read")
            #expect(events.last?.summary.contains("“Draft”") == true && events.last?.payloadJson.contains("Cars under Vehicles.") == true,
                    "logic the user wrote but never activated is kept in the history, not lost")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_dirty WHERE key = 'logic'") == 1,
                    "the logic is written into the archive at the next start")
        }
    }
}
