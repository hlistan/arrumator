import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// A record file is the user's (AGENTS.md §4.2): one that is there but cannot be read is never written over, removed or
/// taken for one that is not there, whatever reads it, and keeps no other file from being read (docs/storage.md).
@Suite struct UnreadableRecordFileTests {
    @Test func aRecordFileThatCannotBeReadIsNeitherOverwrittenNorTakenAsEmpty() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let url = w.topListing
        let broken = RecordsWorld.broken(try String(contentsOf: url, encoding: .utf8))
        try broken.write(to: url, atomically: true, encoding: .utf8)
        try await w.records.reconcile()
        let unreadable = await w.records.unreadableFiles()
        #expect(unreadable.map(\.path) == [url.path] && unreadable.first?.reason.contains("line") == true,
                "a file that is no longer valid YAML is reported with where it breaks, and the read goes on: \(unreadable)")
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        try await w.records.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == broken, "a change to its directory is not written over it")
        #expect(try await RecordsWorld.marks(w.h.env.database).contains(RecordKind.documents(directory: w.h.env.archive.path).key),
                "and stays waiting, to be written once the file reads again")
        let documents = try await w.h.services.documents.list(DocumentFilter(), limit: 10)
        #expect(documents.count == w.documents.count + 1, "the index keeps every document, the new one too")
        #expect(documents.filter { $0.labels == StubAnalyzer.edpBill }.compactMap(\.id).sorted() == w.documents,
                "and the ones already there keep their labels")

        try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "entries: [unclosed", with: "entries:")
            .write(to: url, atomically: true, encoding: .utf8)
        try await w.records.reconcile()
        #expect(try w.listing(in: w.h.env.archive).contains("file: edp_september.txt"), "once it reads again, the directory's changes are written into it")
        #expect(await w.records.unreadableFiles().isEmpty, "and it is no longer reported")
    }

    /// Ways a record file can be there and still not be read.
    enum Unreadable: String, CaseIterable, Sendable {
        /// Saved again as UTF-16, as some editors do.
        case utf16
        /// Its permissions let nobody read it.
        case forbidden
    }

    @Test(arguments: Unreadable.allCases)
    func aRecordFileThatIsThereButCannotBeReadIsNeverTakenForAbsent(_ way: Unreadable) async throws {
        let w = try await RecordsWorld.make()
        let url = w.topListing
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            w.h.env.cleanup()
        }
        let saved: Data
        switch way {
        case .utf16:
            saved = try #require(try String(contentsOf: url, encoding: .utf8).data(using: .utf16))
            try saved.write(to: url)
        case .forbidden:
            saved = try Data(contentsOf: url)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        }
        try await w.records.reconcile()
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        try await w.records.flush()
        #expect(await w.records.unreadableFiles().map(\.path) == [url.path], "the file is reported as one that cannot be read")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == saved, "and is never written over as though it were not there")
    }

    @Test func oneRecordFileThatCannotBeReadKeepsNoOtherFromBeingRead() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let broken = try w.h.env.put("Kept/\(w.h.env.config.records.documentsFileName)",
                                     text: RecordsWorld.broken(try String(contentsOf: w.topListing, encoding: .utf8)))
        _ = try w.editLabelByHand()
        #expect(try await w.records.reconcile() == 1, "the file edited by hand is read, whichever comes first")
        let parties = try await w.h.services.documents.list(DocumentFilter(), limit: 5).flatMap { $0.labels(.party) }
        #expect(parties.sorted() == ["Maria Exemplo", "Maria Silva"], "so its correction is the document's")
        #expect(await w.records.unreadableFiles().map(\.path) == [broken.path], "and the broken one is reported, not read")
    }

    @Test func aRebuildThatWouldDropAFileItCannotReadIsRefusedNamingItAndWhatToDo() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        try await w.h.labels.merge(DocumentLabel(kind: .sender, value: "EDP Comercial"), into: "EDP")
        try await w.records.flush()
        let url = w.h.env.layout.labelRules
        let broken = RecordsWorld.broken(try String(contentsOf: url, encoding: .utf8))
        try broken.write(to: url, atomically: true, encoding: .utf8)
        await #expect("the user asked for a rebuild, which would drop the rules the file holds") {
            try await w.records.rebuild()
        } throws: { error in
            guard case let RecordsError.unreadableFiles(files) = error else { return false }
            return files.map(\.path) == [url.path] && error.localizedDescription.contains(url.path) && error.localizedDescription.contains("Correct")
        }
        #expect(try await w.h.services.labels.rules().count == 1, "so the index keeps them")
        #expect(try String(contentsOf: url, encoding: .utf8) == broken, "and the file is left as it is")
    }

    @Test func aRecordFileTheIndexHasNotReadIsReadBeforeItIsWrittenOrRemoved() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        try await w.h.labels.merge(DocumentLabel(kind: .sender, value: "EDP Comercial"), into: "EDP")
        try await w.records.flush()
        let url = w.h.env.layout.labelRules
        // An index that has not read the rules yet, such as one whose archive another Mac has just synchronised.
        let (database, records) = try w.freshIndex()
        let actions = LabelActions(database: database, time: TestTime(.advances))
        let mine = try #require(try await actions.ignore(DocumentLabel(kind: .topic, value: "electricity")).rule.id)
        _ = try await actions.forget(rule: mine)
        try await records.flush()
        #expect(FileManager.default.fileExists(atPath: url.path), "a file the index never wrote is not removed for holding nothing the index has")
        let rules = try await LabelStore(database: database, config: w.h.env.config.labels).rules()
        #expect(rules.map(\.summary) == ["sender “EDP Comercial” → “EDP”"], "it is read into the index instead, and kept: \(rules.map(\.summary))")
    }

    @Test func aFolderOfRecordFilesThatCannotBeListedIsNeverTakenForAnEmptyOne() async throws {
        let w = try await RecordsWorld.make()
        let folder = w.h.env.layout.history
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            w.h.env.cleanup()
        }
        let events = try await w.h.services.history.events(limit: 100).map(\.id)
        // Its files can still be reached by name, but which there are cannot be read.
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
        await #expect("a rebuild would drop every month of the history the folder holds") {
            try await w.records.rebuild()
        } throws: { error in
            guard case let RecordsError.unreadableFiles(files) = error else { return false }
            return files.map(\.path) == [folder.path]
        }
        #expect(try await w.h.services.history.events(limit: 100).map(\.id) == events, "so the index keeps its history")
        try await w.records.reconcile()
        #expect(await w.records.unreadableFiles().map(\.path) == [folder.path], "and the folder is reported, its files not taken for gone")
        #expect(try await RecordsWorld.marks(w.h.env.database).isEmpty, "none of which is written again as though it had been deleted")
    }

    @Test func aRecordFileOfANewerFormatIsRefusedNamingItsVersion() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        try await w.h.labels.merge(DocumentLabel(kind: .sender, value: "EDP Comercial"), into: "EDP")
        try await w.records.flush()
        let url = w.h.env.layout.labelRules
        let newer = RecordSchema.version + 1
        // As a later version would write it, its entries still looking like this version's.
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "arrumator: \(RecordSchema.version)\n", with: "arrumator: \(newer)\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try await w.records.reconcile()
        let file = try #require(await w.records.unreadableFiles().first)
        #expect(file.path == url.path && file.reason.contains("format \(newer)"),
                "a file a newer version wrote is not read as this version reads its own: \(file.reason)")
        _ = try await w.h.labels.ignore(DocumentLabel(kind: .topic, value: "electricity"))
        try await w.records.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == text, "and is never written over with this version's idea of it")
    }

    @Test func anEntryWhoseFileIsNotOneNameInItsFolderLeavesItsListUnread() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let paths = try await w.h.services.documents.list(DocumentFilter(), limit: 10).map(\.path).sorted()
        var lines = try String(contentsOf: w.topListing, encoding: .utf8).components(separatedBy: "\n")
        let first = try #require(lines.firstIndex { $0.hasPrefix("  file: ") })
        // An entry edited to point outside the archive.
        lines[first] = "  file: ../../outside.txt"
        let edited = lines.joined(separator: "\n")
        try edited.write(to: w.topListing, atomically: true, encoding: .utf8)
        try await w.records.reconcile()
        let file = try #require(await w.records.unreadableFiles().first)
        #expect(file.path == w.topListing.path && file.reason.contains("entries[0].file") && !file.reason.contains("outside"),
                "a file named by more than one name of a path is no file of its folder, so the list is not read: \(file.reason)")
        #expect(try await w.h.services.documents.list(DocumentFilter(), limit: 10).map(\.path).sorted() == paths,
                "no document is moved outside the archive by it")
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        try await w.records.flush()
        #expect(try String(contentsOf: w.topListing, encoding: .utf8) == edited, "and it is never written over")
    }

    /// Ways front matter can be there and not be what the app reads.
    enum Malformed: String, CaseIterable, Sendable {
        /// A line that is no YAML.
        case invalidYAML
        /// A value no status is.
        case unknownValue
    }

    @Test(arguments: Malformed.allCases)
    func whyAFileCannotBeReadSaysWhereNeverWhatItHolds(_ way: Malformed) async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        // Words of the user's or of a document, which never go into a log (AGENTS.md §4.1).
        let words = "Fatura confidencial de Maria"
        var lines = try String(contentsOf: w.topListing, encoding: .utf8).components(separatedBy: "\n")
        let first = try #require(lines.firstIndex { $0.hasPrefix("  status: ") })
        lines[first] = switch way {
        case .invalidYAML: "  status: \(words): yes"
        case .unknownValue: "  status: \(words)"
        }
        try lines.joined(separator: "\n").write(to: w.topListing, atomically: true, encoding: .utf8)
        try await w.records.reconcile()
        let reason = try #require(await w.records.unreadableFiles().first?.reason)
        #expect(!reason.contains("Fatura") && !reason.contains("Maria"), "what the file holds is never quoted: \(reason)")
        switch way {
        case .invalidYAML:
            #expect(reason.contains("line \(first + 1), column "), "the file's line and column say where it breaks: \(reason)")
        case .unknownValue:
            #expect(reason.contains("entries[0].status"), "the field says where a value is wrong: \(reason)")
        }
    }
}
