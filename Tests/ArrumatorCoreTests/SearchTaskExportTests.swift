@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// Exporting a search task's set (docs/how-it-works.md#search-tasks): copies of its documents in a new folder named
/// after the task, a folder per label the set is arranged by, or a ZIP archive of that folder, recorded with the task.
/// Nothing in the archive changes, nothing already at the destination is written over, and no label can place a file
/// outside the export.
@Suite struct SearchTaskExportTests {
    private let suite = SearchTaskTests()

    private func prepared(_ plan: SearchPlan = SearchTaskTests.invoices2025) async throws -> (SearchTaskTests.World, SearchTaskActions, Int64) {
        let w = try await suite.world()
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [SearchTaskTests.prompt: plan]))
        let id = try await tasks.create(prompt: SearchTaskTests.prompt).id
        await queue.drain()
        return (w, tasks, id)
    }

    /// Finds the task's documents again, as after their labels changed.
    private func findAgain(_ tasks: SearchTaskActions, _ id: Int64) async throws {
        _ = try await tasks.retry(id)
        await tasks.queue.drain()
    }

    private func out(_ w: SearchTaskTests.World) -> URL { w.h.env.root.appendingPathComponent("Out", isDirectory: true) }

    /// Every file under `root`, by its path below it, in NFC.
    private func files(under root: URL) -> Set<String> {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return Set((walker?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)).precomposedStringWithCanonicalMapping })
    }

    @Test func theSetIsCopiedIntoFoldersByItsArrangementAndTheExportIsRecordedWithTheTask() async throws {
        let (w, tasks, id) = try await prepared()
        defer { w.h.env.cleanup() }
        _ = try await tasks.update(id, SearchTaskChange(grouping: .by([.sender, .date])))
        let edp = try #require(try await w.h.services.documents.document(id: try w.id("edp_2025_03.txt")))
        let export = try await tasks.export(id, to: out(w), format: .folder)

        #expect(export.path == out(w).appendingPathComponent("Utility invoices 2025").path, "a new folder named after the task")
        #expect(files(under: URL(fileURLWithPath: export.path)) == ["Águas do Porto/2025/aguas_2025_05.txt", "EDP Comercial/2025/edp_2025_03.txt"],
                "a folder per sender, one per year inside it, and the documents under their own names")
        #expect(Set(export.files.map(\.path)) == ["Águas do Porto/2025/aguas_2025_05.txt", "EDP Comercial/2025/edp_2025_03.txt"]
                    && export.skipped.isEmpty, "the export records where each document went")
        #expect(try HashService.sha256(of: edp.url) == edp.sha256, "documents are copied, never moved: the archive is as it was")
        #expect(try await w.h.services.documents.document(id: edp.id ?? 0)?.path == edp.path, "and so is the index")
        let task = try #require(try await tasks.store.task(id: id))
        #expect(task.exports == [export], "the export is the task's, to find again")
        #expect(try await w.h.services.history.events(limit: 10, kinds: [.taskExported]).first?.summary.contains(export.path) == true,
                "and in History, with where it went")
    }

    @Test func aSetListedWithoutArrangingIsExportedNewestFirst() async throws {
        let (w, tasks, id) = try await prepared()
        defer { w.h.env.cleanup() }
        _ = try await tasks.update(id, SearchTaskChange(grouping: .by([])))
        let export = try await tasks.export(id, to: out(w), format: .folder)
        #expect(export.files.map(\.document) == [try w.id("aguas_2025_05.txt"), try w.id("edp_2025_03.txt")],
                "the export records the documents as the set lists them: the May bill before the March one, the newest by their own date first")
    }

    @Test func exportingAgainNeverWritesOverWhatIsThere() async throws {
        let (w, tasks, id) = try await prepared()
        defer { w.h.env.cleanup() }
        let first = try await tasks.export(id, to: out(w), format: .folder)
        let second = try await tasks.export(id, to: out(w), format: .folder)
        #expect(second.path == first.path + " (2)", "a second export gets a folder of its own, named with naming.collisionFormat")
        #expect(files(under: URL(fileURLWithPath: first.path)).count == 2, "and the first is as it was")
        #expect(try await tasks.store.task(id: id)?.exports.map(\.path) == [first.path, second.path], "both are the task's")
    }

    @Test func aZipArchiveHoldsTheSameFolders() async throws {
        let (w, tasks, id) = try await prepared()
        defer { w.h.env.cleanup() }
        let export = try await tasks.export(id, to: out(w), format: .zip)
        #expect(export.path == out(w).appendingPathComponent("Utility invoices 2025.zip").path && export.format == .zip,
                "an archive named after the task")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out(w).path) == ["Utility invoices 2025.zip"],
                "and nothing else is left beside it")
        // Unpacked as Finder does, with the tool macOS ships for it.
        let unpacked = w.h.env.root.appendingPathComponent("Unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", export.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0, "the archive is a ZIP archive macOS unpacks")
        #expect(files(under: unpacked) == ["Utility invoices 2025/Águas do Porto/aguas_2025_05.txt", "Utility invoices 2025/EDP Comercial/edp_2025_03.txt"],
                "holding the task's folder, arranged as a folder export is")
        #expect(Set(export.files.map(\.path)) == ["Águas do Porto/aguas_2025_05.txt", "EDP Comercial/edp_2025_03.txt"],
                "and records the same paths")
    }

    @Test func aLabelCanNeverPlaceAFileOutsideTheExport() async throws {
        let escaping = SearchPlan(title: "../../Escape", labels: [SearchTaskTests.label(.type, "invoice")], words: [], grouping: [.sender])
        let (w, tasks, id) = try await prepared(escaping)
        defer { w.h.env.cleanup() }
        let meo = try w.id("meo_2025_01.txt")
        try await w.h.review.edit(meo, fileName: nil, labels: [SearchTaskTests.label(.sender, "../../../etc"), SearchTaskTests.label(.type, "invoice")])
        let edp = try w.id("edp_2024_11.txt")
        try await w.h.review.edit(edp, fileName: nil, labels: [SearchTaskTests.label(.sender, "..."), SearchTaskTests.label(.type, "invoice")])
        try await findAgain(tasks, id)
        let export = try await tasks.export(id, to: out(w), format: .folder)
        #expect(URL(fileURLWithPath: export.path).deletingLastPathComponent().standardizedFileURL == out(w).standardizedFileURL,
                "the task's name is one folder in the destination, whatever it says")
        let root = URL(fileURLWithPath: export.path)
        let paths = files(under: root)
        #expect(paths.count == export.files.count && paths.count == 4, "every copy is inside the export: \(paths)")
        #expect(paths.contains("etc/meo_2025_01.txt"), "a label with path separators is one folder, cleaned as a file name is")
        #expect(paths.contains("No sender/edp_2024_11.txt"), "and one with nothing left after cleaning goes with those without a sender")
        #expect(!FileManager.default.fileExists(atPath: w.h.env.root.appendingPathComponent("etc").path), "nothing was written outside it")
    }

    @Test func anExportIntoTheArchiveOrIncomingOrOntoAFileIsRefused() async throws {
        let (w, tasks, id) = try await prepared()
        defer { w.h.env.cleanup() }
        for folder in [w.h.env.archive, w.h.env.archive.appendingPathComponent("Exports"), w.h.env.incoming] {
            await #expect(throws: SearchTaskError.destinationInsideArchive(folder.standardizedFileURL.path),
                          "copies there would be filed as documents") {
                try await tasks.export(id, to: folder, format: .folder)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: w.h.env.archive.appendingPathComponent("Exports").path), "and nothing is made there")
        let file = w.h.env.root.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        await #expect(throws: SearchTaskError.destinationNotAFolder(file.path)) { try await tasks.export(id, to: file, format: .zip) }
        #expect(try await tasks.store.task(id: id)?.exports.isEmpty == true, "a refused export records nothing")
    }

    @Test func aDocumentWhoseFileIsGoneIsSkippedWithTheReason() async throws {
        let (w, tasks, id) = try await prepared()
        defer { w.h.env.cleanup() }
        let aguas = try #require(try await w.h.services.documents.document(id: try w.id("aguas_2025_05.txt")))
        try FileManager.default.moveItem(at: aguas.url, to: w.h.env.root.appendingPathComponent("elsewhere.txt"))
        let export = try await tasks.export(id, to: out(w), format: .folder)
        #expect(export.files.map(\.document) == [try w.id("edp_2025_03.txt")], "what can be copied is")
        #expect(export.skipped.map(\.document) == [aguas.id] && export.skipped.first?.reason.contains(aguas.path) == true,
                "and what cannot is recorded with why")
    }

    @Test func aTaskWithoutDocumentsHasNothingToExport() async throws {
        let (w, tasks, id) = try await prepared(SearchPlan(title: "None", labels: [SearchTaskTests.label(.sender, "Nobody")], words: [],
                                                           grouping: []))
        defer { w.h.env.cleanup() }
        await #expect(throws: SearchTaskError.nothingToExport(id)) { try await tasks.export(id, to: out(w), format: .folder) }
        #expect(!FileManager.default.fileExists(atPath: out(w).path), "and makes no folder")
    }
}
