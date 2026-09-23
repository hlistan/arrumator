import Foundation
import GRDB

/// Append-only audit trail of everything that happens to documents, folders, rules and settings.
public struct HistoryStore: Sendable {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    @discardableResult
    public func record(_ kind: EventKind, actor: EventActor = .system, doc: Int64? = nil, job: Int64? = nil,
                       trace: Int64? = nil, summary: String, payload: (any Encodable)? = nil) async throws -> Int64 {
        let payloadJSON = payload.map { JSON.string($0) }
        return try await database.writer.write { db in
            try Self.insert(db, kind, actor: actor, doc: doc, job: job, trace: trace, summary: summary, payloadJSON: payloadJSON)
        }
    }

    /// Inserts inside an existing transaction so events commit atomically with the change they describe.
    @discardableResult
    public static func insert(_ db: Database, _ kind: EventKind, actor: EventActor = .system, doc: Int64? = nil,
                              job: Int64? = nil, trace: Int64? = nil, summary: String,
                              payload: (any Encodable)? = nil) throws -> Int64 {
        try insert(db, kind, actor: actor, doc: doc, job: job, trace: trace, summary: summary,
                   payloadJSON: payload.map { JSON.string($0) })
    }

    private static func insert(_ db: Database, _ kind: EventKind, actor: EventActor, doc: Int64?, job: Int64?,
                               trace: Int64?, summary: String, payloadJSON: String?) throws -> Int64 {
        var event = EventRecord(id: nil, at: Date(), docId: doc, jobId: job, traceId: trace, kind: kind, actor: actor,
                                summary: summary, payloadJson: payloadJSON ?? "{}")
        try event.insert(db)
        Log.debug(.ingest, "event \(kind.rawValue): \(summary)", [
            "doc": doc.map(String.init) ?? "-", "job": job.map(String.init) ?? "-", "trace": trace.map(String.init) ?? "-",
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
