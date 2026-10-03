@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What a rebuild finds of documents' files on disk, which the record files do not hold: a document follows its file
/// by the identifier on it, a copy is a document of its own, a package is one document, and History says what the
/// archive watcher would have said had it seen it happen (`ArchiveReconciler`).
@Suite struct RebuildLocatingTests {
    private func store(_ database: AppDatabase) -> DocumentStore { DocumentStore(database: database, time: TestTime(.advances)) }

    private func adoptions(_ database: AppDatabase) async throws -> [String] {
        try await JobStore(database: database, time: TestTime(.advances)).active(kinds: [.adopt]).map(\.sourcePath).sorted()
    }

    private func move(_ url: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: destination)
    }

    /// Copies `url` to `destination` as Finder does, the extended attributes with it: the document's identifier too.
    private func copy(_ url: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: destination)
    }

    @Test func aDocumentARebuildFindsGoneIsMissingWithTheStatusItHadAndTakesItBackWhenItsFileIsFound() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        var doc = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        doc.status = .needsReview
        doc = try await w.h.services.documents.save(doc)
        let docID = try #require(doc.id)
        // Taken out of the archive while no app watched it.
        let away = w.h.env.root.appendingPathComponent("Away/\(doc.filename)")
        try move(doc.url, to: away)
        let first = try await w.records.rebuild()
        let missing = try #require(try await w.h.services.history.events(limit: 5, kinds: [.missing], docID: docID).first,
                                   "a document a rebuild finds gone is recorded missing, as the archive watcher records it")
        #expect(first.missing == 1 && missing.actor == .user && missing.summary == "\(doc.filename) was removed from the archive"
                    && JSON.decode(MissingPayload.self, from: missing.payloadJson)?.had == .needsReview,
                "with the status it had, to be taken again when its file is found: \(missing.payloadJson)")

        // Put back into another folder while the index was lost.
        let back = w.h.env.archive.appendingPathComponent("Back/\(doc.filename)").standardizedFileURL
        try move(away, to: back)
        let (database, records) = try w.freshIndex()
        let second = try await records.rebuild()
        let found = try #require(try await store(database).document(id: docID))
        #expect(found.path == back.path && found.status == .needsReview && second.relocated == 1 && second.missing == 0,
                "the document found again is where its file is, with the status it had, not filed: \(found.status)")
        let moved = try await HistoryStore(database: database, time: TestTime(.advances)).events(limit: 5, kinds: [.userMoved], docID: docID)
        #expect(moved.map(\.summary) == ["\(doc.filename) moved to \(back.path)"], "and History says where it was found")
    }

    @Test func aCopyMadeInFinderThatCarriesADocumentsIdentifierIsTakenInByARebuildAsADocumentOfItsOwn() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let doc = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        let copied = w.h.env.archive.appendingPathComponent("A copy/\(doc.filename)").standardizedFileURL
        try copy(doc.url, to: copied)
        #expect(Xattr.get(Xattr.documentID, from: copied) == doc.uid, "the copy carries the document's identifier, as Finder copies it")
        let (database, records) = try w.freshIndex()
        let summary = try await records.rebuild()
        #expect(try await store(database).document(id: try #require(doc.id))?.path == doc.path && summary.relocated == 0,
                "the document stays with its file where it is recorded: \(summary)")
        #expect(try await adoptions(database) == [copied.path] && summary.adopted == 1, "and the copy is taken in as a document of its own")
        #expect(Xattr.get(Xattr.documentID, from: copied) == nil && Xattr.get(Xattr.documentID, from: doc.url) == doc.uid,
                "without the identifier, which the original keeps, so nothing takes the copy for the document again")
    }

    @Test func aPackageInTheArchiveIsFoundAndTakenInByARebuildAsOneDocument() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        // A package put in by hand, which macOS shows as one document.
        let notes = try w.h.env.put("Notes.rtfd/TXT.rtf", text: "{\\rtf1 notes}").deletingLastPathComponent().standardizedFileURL
        // A document whose file is now a package carrying its identifier, as one saved again by an app as a package.
        let doc = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        let letter = try w.h.env.put("Letters/Letter.rtfd/TXT.rtf", text: "{\\rtf1 letter}").deletingLastPathComponent().standardizedFileURL
        try Xattr.set(Xattr.documentID, doc.uid, on: letter)
        try FileManager.default.removeItem(at: doc.url)
        #expect(Packages.isPackage(notes) && Packages.isPackage(letter), "both are packages to macOS")
        let (database, records) = try w.freshIndex()
        let summary = try await records.rebuild()
        #expect(try await store(database).document(id: try #require(doc.id))?.path == letter.path && summary.relocated == 1
                    && summary.missing == 0, "the document is found in the package that carries its identifier: \(summary)")
        #expect(try await adoptions(database) == [notes.path], "and the package put in by hand is taken in whole, not what it holds")
    }

    @Test func aFolderCopiedInFinderWithItsListIntoAnArchiveWhoseIndexHasItsDocumentsMovesNoneOfThem() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let documents = try await w.h.services.documents.list(DocumentFilter(), limit: 10).sorted { $0.path < $1.path }
        // A folder holding the documents and their list, copied in Finder: the list and each copy name the originals.
        let folder = w.h.env.archive.appendingPathComponent("Bills copy", isDirectory: true).standardizedFileURL
        try copy(w.topListing, to: folder.appendingPathComponent(w.h.env.config.records.documentsFileName))
        for document in documents { try copy(document.url, to: folder.appendingPathComponent(document.filename)) }

        try await w.records.reconcile()
        #expect(try await w.h.services.documents.list(DocumentFilter(), limit: 10).sorted { $0.path < $1.path }.map(\.path)
                    == documents.map(\.path), "the index has each document where its file is: the copied list moves none")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(w.h.env.config.records.documentsFileName).path),
                "the copied list, which lists none of the folder's documents, is written as the index has the folder: without one")
        #expect(try w.listing(in: w.h.env.archive).contains("uid: \(documents[0].uid)"), "the documents' own list keeps them")
    }

    /// Where a folder of the archive is duplicated in Finder: beside it, as Duplicate puts it, or into another folder.
    enum Duplicate: String, CaseIterable, Sendable {
        case beside
        case nested

        func folder(of original: URL) -> URL {
            switch self {
            case .beside: original.deletingLastPathComponent().appendingPathComponent("\(original.lastPathComponent) copy", isDirectory: true)
            case .nested: original.deletingLastPathComponent().appendingPathComponent("Old/\(original.lastPathComponent)", isDirectory: true)
            }
        }
    }

    @Test(arguments: Duplicate.allCases)
    func aFolderDuplicatedWithItsListWhileTheIndexWasLostIsDecidedOnNoGuessAndTheUserIsTold(_ duplicate: Duplicate) async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let documents = try await w.h.services.documents.list(DocumentFilter(), limit: 10).sorted { $0.path < $1.path }
        let list = w.h.env.config.records.documentsFileName
        let bills = w.h.env.archive.appendingPathComponent("Bills", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: bills, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: w.topListing, to: bills.appendingPathComponent(list))
        for document in documents { try FileManager.default.moveItem(at: document.url, to: bills.appendingPathComponent(document.filename)) }
        let copied = duplicate.folder(of: bills).standardizedFileURL
        try copy(bills, to: copied)

        let (database, records) = try w.freshIndex()
        let summary = try await records.rebuild()
        try await records.reconcile()
        try await records.flush()
        let rebuilt = try await store(database).list(DocumentFilter(), limit: 10)
        let places = Set(rebuilt.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path })
        #expect(rebuilt.count == documents.count && places.count == 1 && [bills.path, copied.path].contains(places.first ?? ""),
                "each document is kept at one of its places, all at the same, as nothing tells which is the copy: \(places)")
        #expect(try await adoptions(database).isEmpty && summary.adopted == 0, "neither place is taken in as new documents")
        for document in documents {
            for folder in [bills, copied] {
                #expect(Xattr.get(Xattr.documentID, from: folder.appendingPathComponent(document.filename)) == document.uid,
                        "no file loses the document's identifier: \(folder.lastPathComponent)/\(document.filename)")
            }
        }
        for folder in [bills, copied] {
            let text = try String(contentsOf: folder.appendingPathComponent(list), encoding: .utf8)
            #expect(documents.allSatisfy { text.contains("uid: \($0.uid)") }, "neither list loses its entries: \(folder.lastPathComponent)")
        }
        let history = HistoryStore(database: database, time: TestTime(.advances))
        let told = try await history.events(limit: 20, kinds: [.foundInTwoPlaces])
        #expect(told.count == documents.count && told.allSatisfy { $0.summary.contains(bills.path) && $0.summary.contains(copied.path) },
                "History says once, after a rebuild and a read-back, that each document is in both places: \(told.map(\.summary))")
        let doctor = try await doctorChecks(database, w).filter { $0.name == "Document in two places" }
        #expect(doctor.count == 1 && doctor.allSatisfy { $0.status == .warning && $0.detail.contains("\(documents.count) documents")
                    && $0.detail.contains(bills.path) && $0.detail.contains(copied.path) && !$0.detail.contains(documents[0].filename) },
                "and the doctor warns of them, naming both folders and no document's file: \(doctor.map(\.detail))")

        // The user removes the copy: each document is at the place that is left, wherever it was kept.
        try FileManager.default.removeItem(at: copied)
        let h = w.h.over(database)
        try await ArchiveReconciler(services: h.services, coordinator: h.coordinator).apply([.gone(path: copied.path)])
        let after = try await store(database).list(DocumentFilter(), limit: 10)
        #expect(after.allSatisfy { $0.path.hasPrefix(bills.path + "/") && $0.status == .filed },
                "every document follows the file that is left, none is missing: \(after.map(\.path))")
        #expect(try await doctorChecks(database, w).allSatisfy { $0.name != "Document in two places" }, "and the doctor no longer warns")
    }

    /// What the doctor says of the archive whose index is `database`.
    private func doctorChecks(_ database: AppDatabase, _ w: RecordsWorld) async throws -> [DoctorCheck] {
        let env = w.h.env
        let settings = await env.settings.current
        let mock = MockOllama(installed: []) { _ in "{}" }
        let address = try OllamaEndpoint.validated(settings.ollamaURL)
        let lifecycle = OllamaLifecycle(api: mock, config: env.config.ollama, management: .external, binaryOverride: nil, address: address,
                                        time: env.time)
        return await Doctor(database: database, archive: env.archive, paths: env.paths, appVersion: "test", time: env.time,
                            resolver: StubResolver())
            .run(settings: settings, config: env.config, lifecycle: lifecycle, models: ModelManager(api: mock, config: env.config.ollama),
                 ollamaURL: address, unreadableRecords: []).checks
    }
}
