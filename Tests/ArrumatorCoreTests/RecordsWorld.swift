import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB

/// What the suites of the archive's record files start from: two documents filed into a scratch archive, with its
/// record files written.
struct RecordsWorld {
    let h: Harness
    let records: ArchiveRecords
    let documents: [Int64]

    /// Files two documents and writes the record files.
    static func make() async throws -> RecordsWorld {
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: ["edp_july.txt": StubAnalyzer.edpBill,
                                                                          "edp_august.txt": StubAnalyzer.edpBill]))
        for (name, text) in [("edp_july.txt", "EDP electricity July"), ("edp_august.txt", "EDP electricity August")] {
            try await h.ingest(name, text: text)
        }
        let documents = try await h.services.documents.list(DocumentFilter(statuses: [.filed]), limit: 10).compactMap(\.id).sorted()
        let records = h.env.records()
        try await records.flush()
        return RecordsWorld(h: h, records: records, documents: documents)
    }

    /// A second index over the same archive, as after the database was lost.
    func freshIndex() throws -> (AppDatabase, ArchiveRecords) {
        let database = try AppDatabase.inMemory()
        return (database, h.env.records(index: database))
    }

    /// A new index on disk over the same archive, as the app makes one when the archive's index was lost: it holds
    /// nothing of the archive until it is rebuilt (`AppDatabase.PendingRebuild.unread`).
    func newIndex() throws -> (AppDatabase, ArchiveRecords) {
        let config = h.env.config
        let (database, _) = try AppDatabase.open(at: h.env.root.appendingPathComponent("Indexes/\(UUID().uuidString).sqlite"),
                                                 config: config.database, setAsideSuffix: config.records.setAsideSuffix,
                                                 time: TestTime(.advances)) { true }
        return (database, h.env.records(index: database))
    }

    /// The record file of the top of the archive, where both documents are filed.
    var topListing: URL { h.env.archive.appendingPathComponent(h.env.config.records.documentsFileName) }

    /// The text of the list of documents in `directory`.
    func listing(in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(h.env.config.records.documentsFileName), encoding: .utf8)
    }

    /// Changes a label of the first document in the top `_documents.md`, as someone editing it by hand would.
    func editLabelByHand() throws -> URL {
        let text = try String(contentsOf: topListing, encoding: .utf8)
        guard let range = text.range(of: "value: Maria Exemplo") else { throw CocoaError(.fileReadCorruptFile) }
        try text.replacingCharacters(in: range, with: "value: Maria Silva").write(to: topListing, atomically: true, encoding: .utf8)
        return topListing
    }

    /// The keys of the record files waiting to be written in `database`.
    static func marks(_ database: AppDatabase) async throws -> [String] {
        try await database.reader.read { db in try String.fetchAll(db, sql: "SELECT key FROM record_dirty ORDER BY key") }
    }

    /// The identity an entry of the archive's record files gives document `id`.
    static func uid(_ id: Int) -> String { String(format: "5B7A8F4E-0000-0000-0000-%012d", id) }
}
