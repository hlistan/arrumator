import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// A document's sidecar (`ArchiveRecords.renderSidecar`): beside each document of the archive whose text was read, what the
/// model read it as and its text as it was recognised, written from the index, following the document, and never written
/// over or removed once it holds what the app did not write.
@Suite struct SidecarTests {
    /// The text of the bill every test files: two columns set apart by a tab, as OCR keeps a table's cells apart.
    static let billText = "EDP Comercial\nFatura n.º FT 2026/926804564\tTotal 54,21 €\nMaria Exemplo"

    /// A pipeline whose model says what each document is.
    static func harness(title: String? = StubAnalyzer.edpTitle) async throws -> Harness {
        try await Harness.make(analyzer: StubAnalyzer(title: title, interpretation: StubAnalyzer.edpInterpretation))
    }

    /// Where the sidecar of `document` goes, in `h`'s archive.
    static func sidecar(of document: DocumentRecord, in h: Harness) throws -> URL {
        try #require(h.env.layout.sidecar(of: document.path), "a name the app gives has room for its sidecar's")
    }

    static func text(at url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// The names of the files in the Trash, at any depth.
    static func trashed(in h: Harness) -> [String] { h.env.trashed().map(\.lastPathComponent).sorted() }

    @Test func aFiledDocumentHasWhatTheModelReadItAsAndItsTextAsRecognisedBesideIt() async throws {
        let h = try await Self.harness()
        defer { h.env.cleanup() }
        let document = try await h.ingest("fatura.txt", text: Self.billText)
        try await h.env.records().flush()
        let url = try Self.sidecar(of: document, in: h)
        #expect(url.lastPathComponent == document.filename + h.env.config.watcher.sidecarSuffix
                    && url.deletingLastPathComponent().path == h.env.archive.path,
                "beside the document, named after it: \(url.path)")
        let text = try Self.text(at: url)
        #expect(text.contains("\n" + StubAnalyzer.edpInterpretation + "\n"), "what the model read it as is in it: \(text)")
        #expect(text.contains("```text\n" + Self.billText + "\n```"), "and its text as it was recognised, its tab kept, as code: \(text)")
        let header = try #require(text.split(separator: "---\n").first.map(String.init))
        #expect(header.contains("arrumator: 1") && header.contains("document: \(document.uid)") && header.contains("file: \(document.filename)")
                    && header.contains("model: stub") && header.contains("text: textLayer") && header.contains("language: en"),
                "its data names the document, the model and how its text was read: \(header)")
        #expect(SkipRules(watcher: h.env.config.watcher).ignoreReason(url) == "sidecar", "and nothing takes it in as a document")
    }

    /// Reads a file as `PlainTestExtractor` does, as a photo the vision model described: its text is what OCR read on it.
    struct PhotoExtractor: ContentExtracting {
        static let seen = VisualSummary(imageKind: .receipt, description: "A supermarket receipt on a wooden table",
                                        visibleTextSummary: "Continente", organisations: [], dates: [])

        func extract(_ url: URL, sha256: String, context: ExtractionContext, trace: TraceContext) async throws -> ExtractedContent {
            var content = try await PlainTestExtractor().extract(url, sha256: sha256, context: context, trace: trace)
            (content.kind, content.textOrigin, content.visual) = (.image, .ocr, Self.seen)
            return content
        }
    }

    @Test func anImagesSidecarSaysWhatItShowsBesideWhatItIsAndTheTextOCRReadOnIt() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(title: nil, interpretation: "Talão de compra do Continente."),
                                       extractor: PhotoExtractor())
        defer { h.env.cleanup() }
        let photo = try await h.ingest("talao.jpg", text: "CONTINENTE\tTOTAL 23,40")
        try await h.env.records().flush()
        let text = try Self.text(at: try Self.sidecar(of: photo, in: h))
        #expect(text.contains("## What it is\n\nTalão de compra do Continente.\n\n## What it shows\n\nA supermarket receipt on a wooden table\n"),
                "what the model read it as, in its language, and what the vision model saw in it: \(text)")
        #expect(text.contains("```text\nCONTINENTE\tTOTAL 23,40\n```") && text.contains("text: ocr"),
                "and its text is what OCR read on it, never the vision model's words")
        let id = try #require(photo.id)
        let shown = try #require(try await h.services.documentText(id))
        let sidecar = try Self.sidecar(of: photo, in: h)
        #expect(shown.imageDescription == PhotoExtractor.seen.description && shown.interpretation == "Talão de compra do Continente."
                    && shown.text == "CONTINENTE\tTOTAL 23,40" && shown.sidecar == sidecar.path,
                "the card and the command line show the same, and where the sidecar is: \(shown)")
    }

    @Test func aSidecarFollowsItsDocumentAndGoesWithItNeverToTheTrash() async throws {
        let h = try await Self.harness()
        defer { h.env.cleanup() }
        let document = try await h.ingest("fatura.txt", text: Self.billText)
        let id = try #require(document.id)
        let records = h.env.records()
        try await records.flush()
        let first = try Self.sidecar(of: document, in: h)

        try await h.review.edit(id, fileName: "Fatura de julho", labels: nil)
        try await records.flush()
        let renamed = try #require(try await h.services.documents.document(id: id))
        let second = try Self.sidecar(of: renamed, in: h)
        #expect(!FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path),
                "renamed, the document takes its sidecar with it: \(second.lastPathComponent)")
        #expect(Self.trashed(in: h).isEmpty, "the one it had held what the app wrote, so it is gone, not in the Trash")

        _ = try await h.review.remove(id)
        try await records.flush()
        #expect(!FileManager.default.fileExists(atPath: second.path), "moved to the Trash, the document leaves no sidecar behind")
        #expect(Self.trashed(in: h) == [renamed.filename], "and only the document is in the Trash: \(Self.trashed(in: h))")
    }

    @Test func aSidecarChangedByHandGoesToTheTrashRatherThanBeingWrittenOver() async throws {
        let h = try await Self.harness()
        defer { h.env.cleanup() }
        let document = try await h.ingest("fatura.txt", text: Self.billText)
        let id = try #require(document.id)
        let records = h.env.records()
        try await records.flush()
        let url = try Self.sidecar(of: document, in: h)
        let edited = try Self.text(at: url).replacingOccurrences(of: "Maria Exemplo\n", with: "Maria Exemplo, corrected by hand\n")
        try edited.write(to: url, atomically: true, encoding: .utf8)

        try await h.services.index.upsertText(docID: id, filename: document.filename, body: Self.billText + "\nPágina 2", summary: nil,
                                              metadata: [:], extractorVersion: "plain-test/1", labels: document.labels ?? [])
        try await records.flush()
        #expect(try Self.text(at: url).contains("Página 2"), "the sidecar holds the text read again")
        let trashed = try #require(h.env.trashed().first, "the edited one went to the Trash")
        #expect(try Self.text(at: trashed) == edited && trashed.lastPathComponent == url.lastPathComponent,
                "whole, under its name, for the user to take back")

        try edited.write(to: url, atomically: true, encoding: .utf8)
        try await h.review.edit(id, fileName: "Fatura de julho", labels: nil)
        try await records.flush()
        #expect(h.env.trashed().count == 2 && !FileManager.default.fileExists(atPath: url.path),
                "renamed, its document leaves an edited sidecar to the Trash too, never removed")
    }

    @Test func aFileOfTheUsersUnderASidecarsNameIsNeverWrittenOver() async throws {
        let h = try await Self.harness(title: nil)
        defer { h.env.cleanup() }
        let mine = h.env.archive.appendingPathComponent("notes.txt" + h.env.config.watcher.sidecarSuffix)
        try "My own notes about it".write(to: mine, atomically: true, encoding: .utf8)
        let document = try await h.ingest("notes.txt", text: Self.billText)
        try await h.env.records().flush()
        #expect(document.filename == "notes.txt", "a document without a title keeps its own name")
        #expect(try Self.text(at: mine).contains(StubAnalyzer.edpInterpretation), "its sidecar is written where it goes")
        let trashed = try #require(h.env.trashed().first)
        #expect(try Self.text(at: trashed) == "My own notes about it", "the user's file that was there is in the Trash, as it was")
    }

    @Test func oneDocumentFiledWhereAnothersWasTakesItsSidecarsPlace() async throws {
        let h = try await Self.harness(title: nil)
        defer { h.env.cleanup() }
        let records = h.env.records()
        let first = try await h.ingest("bill.txt", text: "EDP July")
        let firstID = try #require(first.id)
        try await records.flush()
        _ = try await h.review.remove(firstID)
        let second = try await h.ingest("bill.txt", text: "EDP August")
        let secondID = try #require(second.id)
        #expect(second.path == first.path, "filed where the first was: \(second.path)")
        // The second's sidecar is written first, as marks are written in any order, then the first's.
        let firstMark = RecordKind.sidecar(document: firstID).key
        try await h.env.database.writer.write { db in try db.execute(sql: "DELETE FROM record_dirty WHERE key = ?", arguments: [firstMark]) }
        try await records.flush()
        try await h.env.database.writer.write { db in
            try db.execute(sql: "INSERT INTO record_dirty(key, version) VALUES (?, 1)", arguments: [firstMark])
        }
        try await records.flush()
        let url = try Self.sidecar(of: second, in: h)
        #expect(try Self.text(at: url).contains("EDP August"), "the sidecar there is the second document's")
        #expect(Self.trashed(in: h) == ["bill.txt"], "neither sidecar went to the Trash, as each held what the app wrote: \(Self.trashed(in: h))")
        let owner = try await h.env.database.reader.read { db in
            try Int64.fetchAll(db, sql: "SELECT doc_id FROM sidecar_files WHERE path = ?", arguments: [url.path])
        }
        #expect(owner == [secondID], "and the path is the second's alone")
    }

    @Test func aDocumentNothingWasReadOfOrNoLongerInTheArchiveHasNoSidecar() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil, interpretation: StubAnalyzer.edpInterpretation))
        defer { h.env.cleanup() }
        let blank = try await h.ingest("blank.txt", text: "")
        let records = h.env.records()
        try await records.flush()
        let none = try Self.sidecar(of: blank, in: h)
        #expect(blank.status == .needsReview && !FileManager.default.fileExists(atPath: none.path), "nothing read and nothing said of it: no sidecar")

        let read = try await h.ingest("note.txt", text: "A note")
        try await records.flush()
        let url = try Self.sidecar(of: read, in: h)
        let written = try Self.text(at: url)
        #expect(written.contains("_The model has not said what it is._") && written.contains("A note") && !written.contains(StubAnalyzer.edpInterpretation),
                "a document the model gave no answer for has its text beside it, and says the model said nothing of it")
        try await h.review.undo(try #require(read.id))
        try await records.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path) && Self.trashed(in: h).isEmpty,
                "undone back into Incoming, the document leaves its sidecar in the archive no more")
    }

    @Test func aSidecarRemovedByHandIsWrittenAgainAndNoneIsWrittenWhileTheArchiveIsAway() async throws {
        let h = try await Self.harness()
        defer { h.env.cleanup() }
        let document = try await h.ingest("fatura.txt", text: Self.billText)
        let records = h.env.records()
        try await records.flush()
        let url = try Self.sidecar(of: document, in: h)
        try FileManager.default.removeItem(at: url)
        try await records.reconcile()
        #expect(FileManager.default.fileExists(atPath: url.path), "removed by hand, it is written again from the index, as a record file is")

        let away = h.env.root.appendingPathComponent("Away", isDirectory: true)
        try FileManager.default.moveItem(at: h.env.archive, to: away)
        try await h.services.index.upsertText(docID: try #require(document.id), filename: document.filename, body: "Other text", summary: nil,
                                              metadata: [:], extractorVersion: "plain-test/1", labels: document.labels ?? [])
        await #expect(throws: RecordsError.self, "while the archive's folder is not there, nothing is written") { try await records.flush() }
        #expect(!FileManager.default.fileExists(atPath: h.env.archive.path), "and no folder is made in its place")
        try FileManager.default.moveItem(at: away, to: h.env.archive)
        try await records.flush()
        #expect(try Self.text(at: url).contains("Other text"), "once it is back, the sidecar is written")
    }

    @Test func aRebuildTakesNoSidecarForADocumentAndWritesNoneOverUntilTheTextIsReadAgain() async throws {
        let h = try await Self.harness()
        defer { h.env.cleanup() }
        let document = try await h.ingest("fatura.txt", text: Self.billText)
        try await h.env.records().flush()
        let url = try Self.sidecar(of: document, in: h)
        let written = try Self.text(at: url)

        let database = try AppDatabase.inMemory()
        let records = h.env.records(index: database)
        try await records.rebuild()
        let documents = try await DocumentStore(database: database, time: h.env.time).list(DocumentFilter(), limit: 10)
        #expect(documents.map(\.filename) == [document.filename], "the sidecar is no document of the archive: \(documents.map(\.filename))")
        #expect(documents.first?.analysis?.interpretation == StubAnalyzer.edpInterpretation,
                "what the model read the document as comes back from its record file, as its labels do")
        #expect(try Self.text(at: url) == written, "the sidecar is left as it is while the document's text is not read again")

        let rebuilt = h.over(database)
        // Reading the text again after a rebuild gives way to every other job, as it does in the app.
        _ = await rebuilt.coordinator.drain(.everything)
        try await records.flush()
        #expect(try Self.text(at: url) == written && h.env.trashed().isEmpty,
                "read again as it was, the text gives the same sidecar, which nothing replaces or sends to the Trash")
        let known = try await database.reader.read { db in try String.fetchOne(db, sql: "SELECT path FROM sidecar_files") }
        #expect(known == url.path, "it is the index's again")
    }
}
