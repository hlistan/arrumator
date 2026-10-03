@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// A document in two places of the archive, when nothing tells which is a copy (`DocumentInTwoPlaces`): its entry is kept
/// as it is in each list that names it, every other entry of those lists is written as any other, and the user's
/// removing either place settles it (docs/storage.md, Documents in two places).
@Suite struct DocumentInTwoPlacesTests {
    /// An archive whose two documents are in `Bills`, with its list, and a copy of that folder made in Finder beside it,
    /// `Bills copy`, which keeps the files named in `copied`, and the whole list; then the index lost and rebuilt.
    private struct Duplicated {
        let w: RecordsWorld
        let documents: [DocumentRecord]
        let bills: URL
        let copy: URL
        let database: AppDatabase
        let records: ArchiveRecords
        let h: Harness

        var list: String { w.h.env.config.records.documentsFileName }
        func text(_ folder: URL) throws -> String { try String(contentsOf: folder.appendingPathComponent(list), encoding: .utf8) }
        var store: DocumentStore { DocumentStore(database: database, time: TestTime(.advances)) }

        static func make(copying copied: (([DocumentRecord]) -> [DocumentRecord])? = nil) async throws -> Duplicated {
            let w = try await RecordsWorld.make()
            let fm = FileManager.default
            let documents = try await w.h.services.documents.list(DocumentFilter(), limit: 10).sorted { $0.path < $1.path }
            let bills = w.h.env.archive.appendingPathComponent("Bills", isDirectory: true).standardizedFileURL
            try fm.createDirectory(at: bills, withIntermediateDirectories: true)
            try fm.moveItem(at: w.topListing, to: bills.appendingPathComponent(w.h.env.config.records.documentsFileName))
            for document in documents { try fm.moveItem(at: document.url, to: bills.appendingPathComponent(document.filename)) }
            let copy = w.h.env.archive.appendingPathComponent("Bills copy", isDirectory: true).standardizedFileURL
            try fm.copyItem(at: bills, to: copy)
            let kept = Set((copied?(documents) ?? documents).map(\.filename))
            for document in documents where !kept.contains(document.filename) {
                try fm.removeItem(at: copy.appendingPathComponent(document.filename))
            }
            let (database, records) = try w.freshIndex()
            try await records.rebuild()
            try await records.flush()
            return Duplicated(w: w, documents: documents, bills: bills, copy: copy, database: database, records: records, h: w.h.over(database))
        }

        /// The entry a list gives the document `uid`, as its lines read; nil when it gives none.
        func entry(_ uid: String, in folder: URL) throws -> String? {
            let lines = try text(folder).components(separatedBy: "\n")
            guard let at = lines.firstIndex(of: "  uid: \(uid)"),
                  let start = lines[..<at].lastIndex(where: { $0.hasPrefix("- id: ") }) else { return nil }
            let end = lines[(at + 1)...].firstIndex { $0.hasPrefix("- id: ") || $0 == FrontMatter.fence } ?? lines.endIndex
            return lines[start..<end].joined(separator: "\n")
        }
    }

    @Test func everyOtherEntryOfAListThatKeepsADocumentInTwoPlacesTakesTheUsersChangesAndNewDocuments() async throws {
        // The copy keeps only the first document's file, so only it is in two places; its list names both.
        let d = try await Duplicated.make { [$0[0]] }
        defer { d.w.h.env.cleanup() }
        let (twice, once) = (d.documents[0], d.documents[1])
        let (twiceID, onceID) = (try #require(twice.id), try #require(once.id))
        let kept = try #require(try await d.store.document(id: twiceID))
        let other = try #require(try await d.store.document(id: onceID))
        #expect(kept.path == d.copy.appendingPathComponent(twice.filename).path && other.path == d.bills.appendingPathComponent(once.filename).path,
                "the document in two places is kept at the list read first, the other where its only file is")
        let held = try #require(try d.entry(twice.uid, in: d.bills), "the list of Bills keeps the entry of the document in two places")

        let tag = DocumentLabel(kind: .tag, value: "Home")
        try await d.h.review.edit(onceID, fileName: nil, labels: LabelEdit(adding: [tag]))
        try await d.records.flush()
        #expect(try d.text(d.bills).contains("value: Home"), "the user's change to the other document is written into its list")
        try await d.records.reconcile()
        try await d.records.flush()
        #expect(try await d.store.document(id: onceID)?.labels?.contains(tag) == true,
                "and a read-back never takes it away again")
        #expect(try d.entry(twice.uid, in: d.bills) == held, "the entry of the document in two places is kept as it was")

        // A document filed into Bills meanwhile.
        let added = d.bills.appendingPathComponent("water.txt")
        try Data("water".utf8).write(to: added)
        var filed = other
        (filed.id, filed.uid, filed.path, filed.inode) = (nil, UUID().uuidString, added.path, nil)
        let new = try await d.store.save(filed)
        try await d.records.flush()
        #expect(try d.text(d.bills).contains("uid: \(new.uid)"), "a document filed into Bills gets its entry")
        #expect(try d.entry(twice.uid, in: d.bills) == held, "beside the entry kept as it was")

        // The user removes the copy: the document follows the file that is left, and every change stays.
        try FileManager.default.removeItem(at: d.copy)
        try await ArchiveReconciler(services: d.h.services, coordinator: d.h.coordinator).apply([.gone(path: d.copy.path)])
        try await d.records.reconcile()
        try await d.records.flush()
        #expect(try await d.store.document(id: twiceID)?.path == d.bills.appendingPathComponent(twice.filename).path,
                "the document is where its file is left")
        let text = try d.text(d.bills)
        #expect(text.contains("value: Home") && text.contains("uid: \(new.uid)") && text.contains("uid: \(twice.uid)"),
                "and the list of Bills holds the change, the new document and the document whose copy went")
        #expect(try await d.store.document(id: onceID)?.labels?.contains(tag) == true, "the tag is the document's still")
    }

    @Test func removingThePlaceADocumentWasNotKeptAtSettlesItAndAFilePutThereLaterIsTakenIn() async throws {
        let d = try await Duplicated.make()
        defer { d.w.h.env.cleanup() }
        let document = d.documents[0]
        let documentID = try #require(document.id)
        let notKept = d.bills.appendingPathComponent(document.filename)
        #expect(try await d.store.document(id: documentID)?.path == d.copy.appendingPathComponent(document.filename).path,
                "the document is kept at the copy's list, read first")
        try FileManager.default.removeItem(at: notKept)
        let reconciler = ArchiveReconciler(services: d.h.services, coordinator: d.h.coordinator)
        try await reconciler.apply([.gone(path: notKept.path)])
        let left = try await d.database.reader.read { db in try TwoPlaces.place(db, uid: document.uid) }
        #expect(left == nil, "a document left in one place is in two places no more")
        try await d.records.flush()
        #expect(try d.entry(document.uid, in: d.bills) == nil && d.entry(d.documents[1].uid, in: d.bills) != nil,
                "the list of Bills no longer keeps its entry, and keeps the other's, still in two places")

        // The user puts a copy of it back where it was: a copy now, taken in as a document of its own.
        try FileManager.default.copyItem(at: d.copy.appendingPathComponent(document.filename), to: notKept)
        try await reconciler.apply([.found(path: notKept.path)])
        let adopted = try await JobStore(database: d.database, time: TestTime(.advances)).active(kinds: [.adopt]).map(\.sourcePath)
        #expect(adopted == [notKept.path], "the file is not ignored as a place of a document in two places: \(adopted)")
    }

    /// How many documents of an archive are in two places in `manyDocumentsInTwoPlacesAreNotedInOneRebuild`.
    static let many = 1_000

    @Test(.timeLimit(.minutes(1)))
    func manyDocumentsInTwoPlacesAreNotedInOneRebuild() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let fm = FileManager.default
        let folders = ["Scans", "Scans copy"].map { env.archive.appendingPathComponent($0, isDirectory: true) }
        let at = TestTime.start
        let entries = (1...Self.many).compactMap { n in
            DocumentEntry(DocumentRecord(id: Int64(n), uid: RecordsWorld.uid(n), path: "/scan-\(n).txt", originalFilename: "scan-\(n).txt",
                                         sha256: "h\(n)", size: 1, uttype: "public.plain-text", inode: nil, pageCount: nil, status: .filed,
                                         analysisJson: nil, contentJson: nil, labelsJson: nil, tagsOnly: false, duplicateOf: nil, lastTraceId: nil,
                                         addedAt: at, filedAt: at, extractedAt: nil, embeddedAt: nil, fileMtime: nil, createdAt: at, updatedAt: at))
        }
        let text = try FrontMatter.compose(RecordList(entries), body: "")
        for folder in folders {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent(env.config.records.documentsFileName), atomically: true, encoding: .utf8)
            for entry in entries {
                let url = folder.appendingPathComponent(entry.file)
                try Data("s".utf8).write(to: url)
                try Xattr.set(Xattr.documentID, entry.uid, on: url)
            }
        }
        let database = try AppDatabase.inMemory()
        let summary = try await env.records(index: database).rebuild()
        let noted = try await database.reader.read { db in try TwoPlaces.all(db) }
        #expect(summary.documents == Self.many && noted.count == Self.many && noted.values.allSatisfy { $0.paths.count == 2 },
                "every document is noted in its two places")
        let told = try await HistoryStore(database: database, time: TestTime(.advances)).events(limit: Self.many * 2, kinds: [.foundInTwoPlaces])
        #expect(told.count == Self.many, "each once")
    }
}
