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

    @discardableResult
    public func record(_ kind: EventKind, actor: EventActor = .system, doc: Int64? = nil, job: Int64? = nil,
                       trace: Int64? = nil, summary: String, payload: (any Encodable)? = nil) async throws -> Int64 {
        let payloadJSON = payload.map { JSON.string($0) }
        let at = time.now()
        return try await database.writer.write { db in
            try Self.insert(db, kind, at: at, actor: actor, doc: doc, job: job, trace: trace, summary: summary, payloadJSON: payloadJSON)
        }
    }

    /// Inserts inside an existing transaction so events commit atomically with the change they describe.
    @discardableResult
    public static func insert(_ db: Database, _ kind: EventKind, at: Date, actor: EventActor = .system, doc: Int64? = nil,
                              job: Int64? = nil, trace: Int64? = nil, summary: String,
                              payload: (any Encodable)? = nil) throws -> Int64 {
        try insert(db, kind, at: at, actor: actor, doc: doc, job: job, trace: trace, summary: summary,
                   payloadJSON: payload.map { JSON.string($0) })
    }

    /// An event with nothing to record beyond its kind and summary.
    static let emptyPayload = "{}"

    private static func insert(_ db: Database, _ kind: EventKind, at: Date, actor: EventActor, doc: Int64?, job: Int64?,
                               trace: Int64?, summary: String, payloadJSON: String?) throws -> Int64 {
        var event = EventRecord(id: nil, at: at, docId: doc, jobId: job, traceId: trace, kind: kind, actor: actor,
                                summary: summary, payloadJson: payloadJSON ?? Self.emptyPayload)
        try event.insert(db)
        // The summary names labels, file names and problems drawn from the document, which never go into a log (§4.1).
        Log.debug(.ingest, "Event recorded", [
            "event": kind.rawValue, "doc": doc.map(String.init) ?? "-", "job": job.map(String.init) ?? "-",
            "trace": trace.map(String.init) ?? "-",
        ])
        return event.id ?? 0
    }

    public func events(limit: Int, kinds: Set<EventKind>? = nil, docID: Int64? = nil, before: Date? = nil) async throws -> [EventRecord] {
        try await database.reader.read { db in
            var request = EventRecord.order(Column("at").desc).limit(limit)
            if let kinds { request = request.filter(kinds.map(\.rawValue).contains(Column("kind"))) }
            if let docID { request = request.filter(Column("doc_id") == docID) }
            if let before { request = request.filter(Column("at") < before.unixSeconds) }
            return try request.fetchAll(db)
        }
    }
}
