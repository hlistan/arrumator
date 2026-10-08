@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// A document's sidecar when something gets in its way: another process writing it at the same moment, a folder or a
/// Trash that refuses, a document gone missing, an image with no text of its own.
extension SidecarTests {
    /// A Trash that takes nothing, as a volume without one.
    struct RefusingTrash: Trashing {
        func trash(_ url: URL) throws -> URL? { throw CocoaError(.fileWriteNoPermission) }
    }

    /// What History says of sidecars not written.
    static func unwritten(in h: Harness) async throws -> [String] {
        try await h.services.history.events(limit: 50, kinds: [.error]).map(\.summary).filter { $0.hasPrefix("The sidecar ") }
    }

    /// Gives document `document` `body` as its text, as reading it again for search does.
    static func read(_ document: DocumentRecord, as body: String, in h: Harness) async throws {
        try await h.services.index.upsertText(docID: try #require(document.id), filename: document.filename, body: body, summary: nil,
                                              metadata: [:], extractorVersion: "plain-test/1", labels: document.labels ?? [])
    }

    @Test func twoProcessesWritingTheSidecarAtOnceLeaveTheLaterText() async throws {
        let h = try await Self.harness()
        defer { h.env.cleanup() }
        let document = try await h.ingest("fatura.txt", text: Self.billText)
        let (app, command) = (h.env.records(), h.env.records())
        try await app.flush()
        let url = try Self.sidecar(of: document, in: h)
        try await Self.read(document, as: "TEXT ONE", in: h)
        // The command has read the index for its sidecar when the app commits a later text and writes it first.
        let once = Mutex(true)
        await command.setBeforeWriting { [h] written in
            guard written.path == url.path, once.withLock({ first in
                defer { first = false }
                return first
            }) else { return }
            try? await Self.read(document, as: "TEXT TWO", in: h)
            _ = try? await app.flush()
        }
        try await command.flush()
        let text = try Self.text(at: url)
        #expect(text.contains("TEXT TWO") && !text.contains("TEXT ONE"),
                "the command, which read the earlier text, writes nothing over the later one: \(text)")
        #expect(h.env.trashed().isEmpty, "and nothing went to the Trash, as each held what the app wrote")
    }

    @Test func aProcessThatReadTheIndexBeforeAnotherWroteTheSidecarAgainSendsNothingToTheTrash() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(title: nil, interpretation: StubAnalyzer.edpInterpretation))
        defer { h.env.cleanup() }
        let document = try await h.ingest("Alpha.txt", text: Self.billText)
        let id = try #require(document.id)
        let (app, command) = (h.env.records(), h.env.records())
        try await app.flush()
        let alpha = try Self.sidecar(of: document, in: h)
        try await h.review.edit(id, fileName: "Beta", labels: nil)
        // The command has read that the sidecar at Alpha is to go, as the document is at Beta, when the app puts the
        // document back at Alpha with another text and writes its sidecar there first.
        let once = Mutex(true)
        await command.setBeforeWriting { [h] written in
            guard written.path == alpha.path, once.withLock({ first in
                defer { first = false }
                return first
            }) else { return }
            try? await h.review.edit(id, fileName: "Alpha", labels: nil)
            let back = try? await h.services.documents.document(id: id)
            if let back { try? await Self.read(back, as: "Read again at Alpha", in: h) }
            _ = try? await app.flush()
        }
        try await command.flush()
        #expect(try Self.text(at: alpha).contains("Read again at Alpha") && h.env.trashed().isEmpty,
                "the sidecar the app has just written at Alpha stays, and nothing goes to the Trash: \(h.env.trashed())")
    }

    @Test func aNameInHangulTheAppKeepsHasItsSidecarWrittenWhereverItsNameIsDecomposed() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(title: nil, interpretation: "전기 요금 청구서."))
        defer { h.env.cleanup() }
        let document = try await h.ingest(String(repeating: "한", count: 80) + ".txt", text: "전기 요금 청구서 2026년 7월")
        try await h.env.records().flush()
        let url = try #require(h.env.layout.sidecar(of: document.path), "the name the app gave leaves room for its sidecar's: \(document.filename)")
        let said = try await Self.unwritten(in: h)
        #expect(FileManager.default.fileExists(atPath: url.path) && said.isEmpty,
                "and it is written, staged under a name of its own: \(document.filename.count) characters")
    }

    @Test func onlyARefusalNoRetryChangesLeavesASidecarUnwrittenForGood() {
        let forGood: [any Error] = [POSIXError(.EACCES), POSIXError(.EPERM), POSIXError(.EROFS), POSIXError(.ENAMETOOLONG),
                                    CocoaError(.fileWriteNoPermission), CocoaError(.fileWriteVolumeReadOnly),
                                    NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: POSIXError(.EROFS)])]
        let mended: [any Error] = [POSIXError(.ENOSPC), POSIXError(.EIO), CocoaError(.fileWriteOutOfSpace), CocoaError(.fileWriteUnknown)]
        for error in forGood {
            #expect(ArchiveRecords.unwritten("/A/x.pdf.arrumator.md", error) is ArchiveRecords.SidecarRefused,
                    "\(error) is a refusal no retry changes: said once, and the sidecar left until its document changes")
        }
        for error in mended {
            #expect(ArchiveRecords.unwritten("/A/x.pdf.arrumator.md", error) is RecordsError,
                    "\(error) may mend: the sidecar stays marked and is tried again with the record files")
        }
    }

    @Test(.fileModesKeepOut) func aFolderThatRefusesTheSidecarHoldsUpNothingAndHistorySaysSo() async throws {
        let h = try await Self.harness()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.env.archive.path)
            h.env.cleanup()
        }
        let document = try await h.ingest("fatura.txt", text: Self.billText)
        let records = h.env.records()
        try await records.flush()
        let url = try Self.sidecar(of: document, in: h)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.env.archive.path)
        try await Self.read(document, as: "Other text", in: h)
        try await records.flush()
        try await records.flush()
        #expect(try Self.text(at: url).contains(Self.billText), "the sidecar the folder will not take stays as it was")
        let said = try await Self.unwritten(in: h)
        #expect(said.count == 1 && said.first?.contains(url.path) == true,
                "the flush, and the command or the app that runs it, goes on, and History says once which and why: \(said)")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.env.archive.path)
        try await Self.read(document, as: "Third text", in: h)
        try await records.flush()
        #expect(try Self.text(at: url).contains("Third text"), "it is written once its document changes and the folder takes it")
    }

    @Test func anEditedSidecarTheTrashRefusesStaysAsItIsAndHistorySaysSo() async throws {
        let h = try await Self.harness()
        defer { h.env.cleanup() }
        let document = try await h.ingest("fatura.txt", text: Self.billText)
        let id = try #require(document.id)
        let records = ArchiveRecords(database: h.env.database, archive: h.env.archive, config: h.env.config, registry: nil, trash: RefusingTrash(),
                                     time: h.env.time, timeZone: TestTime.zone)
        try await records.flush()
        let url = try Self.sidecar(of: document, in: h)
        let edited = try Self.text(at: url) + "\nMy own note.\n"
        try edited.write(to: url, atomically: true, encoding: .utf8)

        try await Self.read(document, as: "Read again", in: h)
        try await records.flush()
        #expect(try Self.text(at: url) == edited, "an edited sidecar the Trash will not take is never written over")
        try await h.review.edit(id, fileName: "Fatura de julho", labels: nil)
        try await records.flush()
        let renamed = try Self.sidecar(of: try #require(try await h.services.documents.document(id: id)), in: h)
        #expect(try Self.text(at: url) == edited && (try Self.text(at: renamed)).contains("Read again"),
                "nor removed when its document is renamed, which has its own written beside it: \(renamed.lastPathComponent)")
        #expect(try await Self.unwritten(in: h).count == 2, "History says each time why it stays")
        let followed = try await h.env.database.reader.read { db in try String.fetchAll(db, sql: "SELECT path FROM sidecar_files") }
        #expect(followed == [renamed.path], "the edited one is the user's, no longer one the app follows: \(followed)")
    }

    @Test func aDocumentSetAsideAsMissingLeavesNoSidecar() async throws {
        let h = try await Self.harness()
        defer { h.env.cleanup() }
        let document = try await h.ingest("fatura.txt", text: Self.billText)
        let records = h.env.records()
        try await records.flush()
        let url = try Self.sidecar(of: document, in: h)
        try await h.services.documents.update(try #require(document.id)) { $0.status = .missing }
        try await records.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path) && h.env.trashed().isEmpty,
                "its file gone, the document's sidecar goes too, as it held what the app wrote")
    }

    /// Reads a file as a photo without a word on it, which the vision model alone described.
    struct WordlessPhotoExtractor: ContentExtracting {
        func extract(_ url: URL, sha256: String, context: ExtractionContext, trace: TraceContext) async throws -> ExtractedContent {
            var content = try await PlainTestExtractor().extract(url, sha256: sha256, context: context, trace: trace)
            (content.kind, content.textOrigin, content.text, content.visual) = (.image, .vlmOnly, "", PhotoExtractor.seen)
            return content
        }
    }

    @Test func aPhotoWithoutWordsHasNoTextOfItsOwnInItsSidecar() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(title: nil, interpretation: "A photo of a receipt."), extractor: WordlessPhotoExtractor())
        defer { h.env.cleanup() }
        let photo = try await h.ingest("photo.jpg", text: "ignored")
        try await h.env.records().flush()
        let text = try Self.text(at: try Self.sidecar(of: photo, in: h))
        #expect(!text.contains("\ntext:") && text.contains("_No text was recognised in it._") && text.contains(PhotoExtractor.seen.description),
                "the vision model's words are what it shows, never its text, and no way of reading text is named: \(text)")
        #expect(try await h.services.documentText(try #require(photo.id))?.textOrigin == nil, "and the command line names none either")
    }
}
