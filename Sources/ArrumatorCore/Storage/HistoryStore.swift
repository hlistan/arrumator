import Foundation
import GRDB

/// Append-only audit trail of everything that happens to documents, labels and settings.
public struct HistoryStore: Sendable {
    public let database: AppDatabase
    public let time: any TimeSource

    public init(database: AppDatabase, time: any TimeSource) {
        self.database = database
        self.time = time
    }

    /// Records an event; its number, or nil when it is held until the index holds its archive (`insert`).
    @discardableResult
    public func record(_ kind: EventKind, actor: EventActor = .system, doc: Int64? = nil, job: Int64? = nil,
                       trace: Int64? = nil, summary: String, payload: (any Encodable)? = nil) async throws -> Int64? {
        let payloadJSON = try payload.map { try JSON.string($0) }
        let at = time.now()
        return try await database.writer.write { db in
            try Self.insert(db, kind, at: at, actor: actor, doc: doc, job: job, trace: trace, summary: summary, payloadJSON: payloadJSON)
        }
    }

    /// Records an event in the transaction that also makes `change`, the change it describes outside the index, such as
    /// a file saved, as its last step: when `change` throws, nothing is recorded. An event held until the index holds its
    /// archive (`insert`) is held in that transaction, and its number is nil. Whoever made the change undoes it when the
    /// transaction, after it, cannot be committed (`SettingsStore.change(_:recording:)`).
    @discardableResult
    public func record(_ kind: EventKind, actor: EventActor, summary: String, payload: (any Encodable)?,
                       alongside change: @escaping @Sendable () throws -> Void) async throws -> Int64? {
        let payloadJSON = try payload.map { try JSON.string($0) }
        let at = time.now()
        return try await database.writer.write { db in
            let id = try Self.insert(db, kind, at: at, actor: actor, doc: nil, job: nil, trace: nil, summary: summary, payloadJSON: payloadJSON)
            try change()
            return id
        }
    }

    /// Inserts inside an existing transaction so events commit atomically with the change they describe. An index that
    /// holds nothing of its archive yet (`AppDatabase.PendingRebuild.unread`), whose history its rebuild replaces with
    /// the archive's, holds an event that concerns no document, job or trace, such as a setting changed during
    /// onboarding, apart from what the rebuild replaces, and records it once it holds the archive (`recordHeld`), so the
    /// change is recorded once and the event is not lost; one that does is refused as any change to what the record
    /// files hold is (`v19_unreadIndexRefusesRecords`). The event's number, or nil when it is held.
    @discardableResult
    public static func insert(_ db: Database, _ kind: EventKind, at: Date, actor: EventActor = .system, doc: Int64? = nil,
                              job: Int64? = nil, trace: Int64? = nil, summary: String,
                              payload: (any Encodable)? = nil) throws -> Int64? {
        try insert(db, kind, at: at, actor: actor, doc: doc, job: job, trace: trace, summary: summary,
                   payloadJSON: try payload.map { try JSON.string($0) })
    }

    /// An event with nothing to record beyond its kind and summary.
    static let emptyPayload = "{}"

    private static func insert(_ db: Database, _ kind: EventKind, at: Date, actor: EventActor, doc: Int64?, job: Int64?,
                               trace: Int64?, summary: String, payloadJSON: String?) throws -> Int64? {
        let payloadJSON = payloadJSON ?? Self.emptyPayload
        // Decided in the transaction that records it, so a rebuild that reads the archive meanwhile is not missed.
        if doc == nil, job == nil, trace == nil, try AppDatabase.pendingRebuild(db) == .unread {
            try HeldEvent(at: at.unixSeconds, kind: kind, actor: actor, summary: summary, payloadJson: payloadJSON).hold(in: db)
            Log.debug(.db, "Event held until the index is rebuilt from the archive", ["event": kind.rawValue])
            return nil
        }
        var event = EventRecord(id: nil, at: at, docId: doc, jobId: job, traceId: trace, kind: kind, actor: actor,
                                summary: summary, payloadJson: payloadJSON)
        try event.insert(db)
        // The summary names labels, file names and problems drawn from the document, which never go into a log (§4.1).
        Log.debug(.ingest, "Event recorded", [
            "event": kind.rawValue, "doc": doc.map(String.init) ?? "-", "job": job.map(String.init) ?? "-",
            "trace": trace.map(String.init) ?? "-",
        ])
        return event.id
    }

    /// Records, in the transaction of `db`, the events held while the index held nothing of its archive, in the order
    /// they were held, each at its own time and under a number after the archive's: what `AppDatabase.setPendingRebuild`
    /// does once the index holds it. One this version cannot read, which a later version held, is dropped, as an event
    /// of a kind it does not know is from a history file, and logged by its type.
    static func recordHeld(_ db: Database) throws {
        let held = try String.fetchAll(db, sql: "SELECT value FROM meta WHERE key GLOB ? ORDER BY rowid", arguments: [HeldEvent.keys])
        for value in held {
            guard let event = JSON.decode(HeldEvent.self, from: value) else { continue }
            var record = EventRecord(id: nil, at: Date(unixSeconds: event.at), docId: nil, jobId: nil, traceId: nil, kind: event.kind,
                                     actor: event.actor, summary: event.summary, payloadJson: event.payloadJson)
            try record.insert(db)
        }
        try db.execute(sql: "DELETE FROM meta WHERE key GLOB ?", arguments: [HeldEvent.keys])
        if !held.isEmpty { Log.info(.db, "Recorded the events held until the index was rebuilt", ["events": String(held.count)]) }
    }

    public func events(limit: Int, kinds: Set<EventKind>? = nil, docID: Int64? = nil, before: Date? = nil) async throws -> [EventRecord] {
        try await database.reader.read { db in
            // Events of one moment, the latest recorded first.
            var request = EventRecord.order(Column("at").desc, Column("id").desc).limit(limit)
            if let kinds { request = request.filter(kinds.map(\.rawValue).contains(Column("kind"))) }
            if let docID { request = request.filter(Column("doc_id") == docID) }
            if let before { request = request.filter(Column("at") < before.unixSeconds) }
            return try request.fetchAll(db)
        }
    }
}

/// An event recorded while the index held nothing of its archive, kept in `meta`, which the triggers that refuse changes
/// to such an index leave alone, under a key of its own, until the index holds the archive (`HistoryStore.recordHeld`).
struct HeldEvent: Codable {
    /// When it happened, in the seconds since 1970 the events table keeps.
    var at: Double
    var kind: EventKind
    var actor: EventActor
    var summary: String
    var payloadJson: String

    /// The keys in `meta` of the events held, as a GLOB pattern: `held_event:` and the place of each in the order held.
    static let keys = "held_event:*"
    static let keyPrefix = "held_event:"

    /// Keeps the event in `meta`, in the transaction of `db`, after those held before it.
    func hold(in db: Database) throws {
        let place = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meta WHERE key GLOB ?", arguments: [Self.keys]) ?? 0
        try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?)", arguments: [Self.keyPrefix + String(place + 1), try JSON.string(self)])
    }
}
