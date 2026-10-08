import CryptoKit
import Foundation
import GRDB

/// A document's sidecar: beside each document of the archive whose text was read, a Markdown file named after it
/// (`ArchiveLayout.sidecar(of:)`) holding what the model read it as (`DocumentAnalysis.interpretation`), what the vision
/// model saw in it when it is an image, and its text as it was recognised, for the user to read, and Spotlight to find
/// it by, without the app. It is written from the index as
/// a record file is, once the change that makes it stale commits (`flush`), marked by triggers
/// (`AppDatabase.sidecarsMigration`), and never read back: what it holds is the index's. A sidecar is the app's while it
/// holds what the app last wrote (`sidecar_files`): it follows its document when it is renamed or moved, and goes when
/// the document goes, is set aside or its reading is taken back. One that holds anything else, edited by hand or a file of
/// the user's under its name, is the user's (AGENTS.md §4.2): it is never written over or removed, but moved to the Trash
/// before the app writes its own in its place.
extension ArchiveRecords {
    /// The sidecar the index last wrote for a document: where, and its checksum.
    struct KnownSidecar: Sendable, Equatable {
        var path: String
        var hash: String
    }

    /// What a document's sidecar holds above its text: the data a program reads, as every record file starts with.
    struct SidecarHeader: Encodable {
        var arrumator = RecordSchema.version
        /// The document's identity, which the file it is beside carries too (`Xattr.documentID`).
        var document: String
        var file: String
        /// The model that read it, which said what it is.
        var model: String?
        /// How its text was recognised: from its text layer, by OCR, or both (`ExtractedContent.recognition`).
        var text: TextOrigin?
        var language: String?
        var pages: Int?
        /// The pages OCR read, by number.
        var ocrPages: [Int]?
        /// Only when its text was cut to `extraction.maxIndexChars`, or not every page was read.
        var truncated: Bool?

        enum CodingKeys: String, CodingKey {
            case arrumator, document, file, model, text, language, pages, truncated
            case ocrPages = "ocr_pages"
        }
    }

    /// The statuses of a document kept in the archive as itself, read again or not, which has a sidecar once its text is
    /// read: not one undone or missing, nor a copy an earlier version filed.
    static let withSidecar: Set<DocumentStatus> = DocumentStatus.inArchive.union([.processing])

    /// What the sidecar of a document is to be, as the index has it, and what the index last wrote for it.
    struct SidecarPlan: Sendable {
        var known: KnownSidecar?
        /// Where it goes and what it holds; nil when the document is to have none.
        var wanted: (url: URL, text: String)?
    }

    /// What the sidecar of document `docID` is to be, as the index has it in `db` (`sidecar(of:body:)`).
    nonisolated func plan(_ db: Database, docID: Int64) throws -> SidecarPlan {
        let known = try Row.fetchOne(db, sql: "SELECT path, hash FROM sidecar_files WHERE doc_id = ?", arguments: [docID])
            .map { KnownSidecar(path: $0["path"], hash: $0["hash"]) }
        let body = try String.fetchOne(db, sql: "SELECT body FROM document_text WHERE doc_id = ?", arguments: [docID]) ?? ""
        return SidecarPlan(known: known, wanted: try DocumentRecord.fetchOne(db, key: docID).flatMap { try sidecar(of: $0, body: body) })
    }

    /// Writes the sidecar of document `docID` as the index has it now, where it is now, and removes the one the index last
    /// wrote for it elsewhere; or, when it is to have none, removes that one: the document is gone, missing, set aside out
    /// of the archive, or its reading was taken back, or nothing of it was read. Each is done in a transaction that reads
    /// the index again and does nothing when it no longer says so, as another process may have written it meanwhile from
    /// a later state (`plan`). A sidecar that does not hold what the app last wrote goes to the Trash instead (`trashed`).
    /// One the folder refuses for good (`refusesForGood`), or the Trash refuses, is left as it is and said in History, and
    /// holds up no other file nor the command or the app that writes them: it is written again once its document changes.
    /// One a retry may mend, as on a full disk, stays marked and is tried again with the record files. Nothing is written
    /// while the archive's folder is not there, nor for a document whose folder is gone.
    func renderSidecar(_ docID: Int64) async throws -> Rendering {
        let plan = try await database.reader.read { db in try self.plan(db, docID: docID) }
        guard archiveIsThere else { throw RecordsError.archiveNotThere(archive.path) }
        do {
            var rendering = Rendering.unchanged
            if let known = plan.known, known.path != plan.wanted?.url.path {
                await beforeWriting?(URL(fileURLWithPath: known.path))
                rendering = try await dispose(known, of: docID)
            }
            guard let wanted = plan.wanted, rendering != .changedMeanwhile else { return rendering }
            let written = try await writeSidecar(wanted.text, to: wanted.url, of: docID)
            return written == .unchanged ? rendering : written
        } catch let refused as SidecarRefused {
            let now = time.now()
            try await database.writer.write { db in try Self.recordUnwritten(db, refused.path, why: refused.why, at: now) }
            return .unchanged
        }
    }

    /// Where the sidecar of `document` goes and what it holds, or nil when it has none: it is not in the archive as itself,
    /// its text has not been read (`extractedAt`), as after it was taken back or before it is read again after a rebuild,
    /// nothing was read of it and the model said nothing of it, or its name leaves no room for its sidecar's.
    nonisolated func sidecar(of document: DocumentRecord, body: String) throws -> (url: URL, text: String)? {
        guard Self.withSidecar.contains(document.status), archive.holds(document.path), document.extractedAt != nil else { return nil }
        let interpretation = document.analysis?.interpretation
        guard !body.isEmpty || interpretation != nil else { return nil }
        guard let url = layout.sidecar(of: document.path) else {
            Log.warning(.db, "No sidecar for a document whose name leaves no room for one", ["path": document.path])
            return nil
        }
        let content = JSON.decode(ExtractedContent.self, from: document.contentJson)
        let header = SidecarHeader(document: document.uid, file: document.filename, model: document.analysis?.model,
                                   text: content?.recognition, language: content.map(\.language.primary).flatMap { $0 == LanguageGuess.undetermined.primary ? nil : $0 },
                                   pages: document.pageCount, ocrPages: content.flatMap { $0.pagesOCRed.isEmpty ? nil : $0.pagesOCRed },
                                   truncated: content?.isPartial == true ? true : nil)
        let shown = RecordText.sidecar(file: document.filename, interpretation: interpretation, imageDescription: content?.visual?.description,
                                       text: body)
        return (url, try FrontMatter.compose(header, body: shown))
    }

    /// Removes the sidecar the index last wrote for document `docID`, `known`, when it still holds what was written; one
    /// that holds anything else goes to the Trash (`trashed`). Decided and done in the transaction that forgets it, which
    /// checks first that the index still has it written there and wants it no more, so no other writer, as another
    /// process that has just written the sidecar there again, comes between. Whether a file went.
    private func dispose(_ known: KnownSidecar, of docID: Int64) async throws -> Rendering {
        let url = URL(fileURLWithPath: known.path)
        await registry?.expect([url.path, url.deletingLastPathComponent().path])
        return try await database.writer.write { db in
            let now = try self.plan(db, docID: docID)
            guard now.known == known, now.wanted?.url.path != known.path else { return .changedMeanwhile }
            let current = try Self.sidecarHash(at: url)
            if let current, current != known.hash, !(try self.trashed(url, in: db)) {
                // Changed by hand, and the Trash refused it: the user's, never removed, and no longer the app's to follow.
                try db.execute(sql: "DELETE FROM sidecar_files WHERE doc_id = ? AND path = ?", arguments: [docID, known.path])
                return .unchanged
            } else if current == known.hash {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    throw Self.unwritten(url.path, error)
                }
            }
            try db.execute(sql: "DELETE FROM sidecar_files WHERE doc_id = ? AND path = ?", arguments: [docID, known.path])
            return current == nil ? .unchanged : .written
        }
    }

    /// Writes `text` as the sidecar of document `docID` at `url`, atomically as a record file is (`write`), and keeps its
    /// path and checksum, the document's alone, in the transaction that puts it in place, which checks there that the
    /// index still makes `text` of the document there and that the file still holds what it held when it was read. A file
    /// there that holds neither `text` nor what the app last wrote there goes to the Trash first (`trashed`), decided in
    /// that transaction too; one the Trash refuses is left as it is, and no sidecar is written. A folder that is gone is
    /// not made again for it.
    private func writeSidecar(_ text: String, to url: URL, of docID: Int64) async throws -> Rendering {
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return .unchanged }
        let hash = FrontMatter.sha256(text)
        await registry?.expect([url.path, url.deletingLastPathComponent().path])
        await beforeWriting?(url)
        let held = try Self.sidecarHash(at: url)
        let staged = held == hash ? nil : try stageSidecar(text, for: url)
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        return try await database.writer.write { db in
            guard try self.plan(db, docID: docID).wanted.map({ $0.url == url && FrontMatter.sha256($0.text) == hash }) == true,
                  try Self.sidecarHash(at: url) == held else { return .changedMeanwhile }
            if let held, held != hash,
               held != (try String.fetchOne(db, sql: "SELECT hash FROM sidecar_files WHERE path = ?", arguments: [url.path])) {
                // Not what the app wrote there: a sidecar changed by hand, or a file of the user's under its name.
                guard try self.trashed(url, in: db) else { return .unchanged }
            }
            if let staged {
                // rename(2) puts the new text in the file's place whole, or not at all, on one volume.
                guard rename(staged.path, url.path) == 0 else { throw Self.unwritten(url.path, POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
            }
            // One path is one document's sidecar: a document filed where another's was takes its place.
            try db.execute(sql: "DELETE FROM sidecar_files WHERE path = ? AND doc_id != ?", arguments: [url.path, docID])
            try db.execute(sql: """
                INSERT INTO sidecar_files(doc_id, path, hash) VALUES (?, ?, ?)
                ON CONFLICT(doc_id) DO UPDATE SET path = excluded.path, hash = excluded.hash
                """, arguments: [docID, url.path, hash])
            return staged == nil ? .unchanged : .written
        }
    }

    /// Writes `text` beside `url`, under a name of its own that holds no document's (`StagedRecordFile.sidecarURL`), to take
    /// its place (`writeSidecar`).
    private func stageSidecar(_ text: String, for url: URL) throws -> URL {
        let staged = StagedRecordFile.sidecarURL(for: url, watcher: config.watcher)
        do {
            try Data(text.utf8).write(to: staged)
        } catch {
            throw Self.unwritten(url.path, error)
        }
        return staged
    }

    /// A sidecar the folder refused, for a reason no retry changes until something else does (`refusesForGood`): said in
    /// History and left, as its document's next change tries it again (`renderSidecar`).
    struct SidecarRefused: Error {
        var path: String
        var why: String
    }

    /// What a failure to write or remove the sidecar at `path` is: one the folder refuses for good (`SidecarRefused`), or one
    /// a retry may mend, as a full disk or a volume gone a moment, which keeps the sidecar marked to be tried again with the
    /// record files, as a record file is (`RecordsError.unwritable`).
    static func unwritten(_ path: String, _ error: any Error) -> any Error {
        refusesForGood(error) ? SidecarRefused(path: path, why: error.localizedDescription)
            : RecordsError.unwritable(path, error.localizedDescription)
    }

    /// The reasons a folder refuses a file that no retry changes until the user does something: no permission, a volume
    /// that is read-only, a name the volume does not take (POSIX `EACCES`, `EPERM`, `EROFS`, `ENAMETOOLONG`).
    static let refusedForGood: Set<POSIXErrorCode> = [.EACCES, .EPERM, .EROFS, .ENAMETOOLONG]

    /// Whether `error`, or one beneath it, is a refusal no retry changes (`refusedForGood`).
    static func refusesForGood(_ error: any Error) -> Bool {
        if let posix = error as? POSIXError { return refusedForGood.contains(posix.code) }
        if let cocoa = error as? CocoaError, [.fileWriteNoPermission, .fileWriteVolumeReadOnly, .fileWriteInvalidFileName].contains(cocoa.code) {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(nsError.code)) { return refusedForGood.contains(code) }
        return nsError.underlyingErrors.contains(where: refusesForGood)
    }

    /// Moves the file at `url`, a sidecar that does not hold what the app last wrote, to the Trash, from which the user can
    /// take it back, and says so in the log, in the transaction of `db` that decided it. Whether it went, or was gone
    /// already: one the Trash refuses, as on a volume without one, is left where it is, said in History in that
    /// transaction, and not tried again until its document changes.
    private nonisolated func trashed(_ url: URL, in db: Database) throws -> Bool {
        do {
            _ = try trash.trash(url)
            Log.info(.db, "A sidecar the app did not write, or that was changed by hand, went to the Trash", ["path": url.path])
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return true
        } catch {
            try Self.recordUnwritten(db, url.path, why: "it does not hold what Arrumator wrote, as one changed by hand, and the Trash "
                + "refused it (\(error.localizedDescription)), so it stays as it is", at: time.now())
            return false
        }
    }

    /// Says in History, in the transaction of `db`, and in the log, that the sidecar at `path` was not written, or not
    /// removed, and why, as a failure no retry would change is said: once for each time its document changes, which is
    /// when it is tried again.
    static func recordUnwritten(_ db: Database, _ path: String, why: String, at now: Date) throws {
        Log.warning(.db, "A sidecar was not written", ["path": path, "error": why])
        _ = try HistoryStore.insert(db, .error, at: now, summary: "The sidecar \(path) was not written: \(why). It is written once its document changes")
    }

    /// The checksum of the file at `url`, of its bytes, as `FrontMatter.sha256` takes it of the text the app writes; nil
    /// when there is none. One that is there but cannot be read throws `RecordsError.unreadable`, never nil.
    static func sidecarHash(at url: URL) throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw RecordsError.unreadable(url.path, error.localizedDescription)
        }
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Marks the sidecars the index last wrote that are no longer where it wrote them, as one removed by hand, so each is
    /// written again from the index, as a record file that disappeared is; one in a folder `walk` could not look into is
    /// not known to be gone. For one that has its turn.
    func markGoneSidecars(hiddenBy walk: ArchiveWalk) async throws {
        let known = try await database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT doc_id, path FROM sidecar_files").map { ($0["doc_id"] as Int64, $0["path"] as String) }
        }
        let gone = known.filter { !FileManager.default.fileExists(atPath: $0.1) && !walk.hides($0.1) }
        guard !gone.isEmpty else { return }
        try await database.writer.write { db in
            for (docID, path) in gone {
                try db.execute(sql: "DELETE FROM sidecar_files WHERE doc_id = ? AND path = ?", arguments: [docID, path])
                try Self.mark(db, .sidecar(document: docID))
            }
        }
    }
}
