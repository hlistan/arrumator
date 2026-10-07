import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// A rebuild never goes on without a record file, or a folder of the archive, it cannot read (AGENTS.md §4.2): an index
/// that lacked what it holds would have its gaps filled by what the app did next, over the user's records once the file
/// read again. It stops naming each and saying what to do, the index stays to be rebuilt, and nothing is read into it,
/// written from it or worked on until a rebuild succeeds, and a change the user asks for meanwhile to what the record
/// files hold is refused, saying why, rather than dropped by the rebuild, while a setting's event is held for it
/// (docs/storage.md).
@Suite struct RefusedRebuildTests {
    /// Expects `rebuild` to be refused naming exactly `paths`, with where each breaks and what to do.
    private func expectRefused(_ paths: [String], _ comment: Comment, _ rebuild: () async throws -> RebuildSummary?) async {
        await #expect(comment) {
            _ = try await rebuild()
        } throws: { error in
            guard case let RecordsError.unreadableFiles(files) = error else { return false }
            return files.map(\.path) == paths && error.localizedDescription.contains("Correct")
                && paths.allSatisfy { error.localizedDescription.contains($0) }
        }
    }

    /// Expects `change` to be refused by `database`, as one not rebuilt from its archive, saying so with the record files
    /// at `paths` and what to do.
    private func expectRefused(_ paths: [String], in database: AppDatabase, _ comment: Comment, _ change: () async throws -> Void) async {
        do {
            try await change()
            Issue.record("the change was made: \(comment)")
        } catch {
            let explained = await database.explained(error)
            guard case let RecordsError.notRebuilt(files) = explained else {
                Issue.record("refused as \(error), not as an index not rebuilt: \(comment)")
                return
            }
            #expect(files.map(\.path) == paths && explained.localizedDescription.contains("Correct"), comment)
        }
    }

    @Test func aRebuildRefusedForTheRulesFileLeavesNothingToBeFilledOverThemOnceTheyReadAgain() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        try await w.h.labels.merge(DocumentLabel(kind: .sender, value: "EDP Comercial"), into: "EDP")
        try await w.records.flush()
        let url = w.h.env.layout.labelRules
        let text = try String(contentsOf: url, encoding: .utf8)
        let broken = TestRecordFiles.broken(text)
        try broken.write(to: url, atomically: true, encoding: .utf8)

        let (database, records) = try w.newIndex()
        await expectRefused([url.path], "the index is lost and its rules cannot be read, so it is not rebuilt without them") {
            try await records.rebuildIfPending()
        }
        #expect(try await database.pendingRebuild() == .unread, "it stays to be rebuilt, and says it holds nothing of the archive")
        let actions = LabelActions(database: database, time: TestTime(.advances))
        await expectRefused([url.path], in: database, "a rule the user decides meanwhile is refused, naming the file to correct") {
            try await actions.ignore(DocumentLabel(kind: .topic, value: "electricity"))
        }
        try await records.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == broken, "and nothing is written over the user's file")

        try text.write(to: url, atomically: true, encoding: .utf8)
        let summary = try #require(try await records.rebuildIfPending(), "once the file is corrected, it is rebuilt")
        let rules = try await LabelStore(database: database, config: w.h.env.config.labels, lookAlikes: LookAlikeMemo()).rules()
        #expect(summary.labelRules == 1 && rules.map(\.summary) == ["sender “EDP Comercial” → “EDP”"] && rules.map(\.id) == [1],
                "with the rules the file holds, under their own numbers: \(rules.map(\.summary))")
        let next = try await actions.ignore(DocumentLabel(kind: .topic, value: "electricity"))
        try await records.flush()
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(next.rule.id == 2 && written.contains("target: EDP") && written.contains("value: electricity"),
                "and a rule decided afterwards takes the next number, and joins them in the file")
    }

    @Test func aRebuildRefusedForTheTasksFileLeavesTheirConversationsToComeBackWithThem() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let interpreter = StubInterpreter(plans: [:])
        let task = try await w.h.searchTasks(interpreter).actions.create(prompt: "electricity bills")
        try await w.h.conversations(StubAnswerer(), interpreter: interpreter).actions.ask(task.id, question: "How much?")
        try await w.records.flush()
        let tasks = w.h.env.layout.searchTasks
        let conversation = w.h.env.layout.conversationFile(task: task.id)
        let text = try String(contentsOf: tasks, encoding: .utf8)
        try TestRecordFiles.broken(text).write(to: tasks, atomically: true, encoding: .utf8)
        let held = try String(contentsOf: conversation, encoding: .utf8)

        let (database, records) = try w.newIndex()
        await expectRefused([tasks.path], "the tasks cannot be read, so their conversations are not read without them") {
            try await records.rebuildIfPending()
        }
        try await records.flush()
        #expect(try String(contentsOf: conversation, encoding: .utf8) == held, "the conversation's file is left as it was")
        try text.write(to: tasks, atomically: true, encoding: .utf8)
        _ = try await records.rebuildIfPending()
        let store = TaskConversationStore(database: database, time: TestTime(.advances))
        #expect(try await store.turns(task: task.id).map(\.question) == ["How much?"], "once they are corrected, the task's questions come back with it")
        var services = w.h.services
        services.database = database
        try await TaskConversationActions(services: services, queue: TaskConversationQueue(services: services, answerer: StubAnswerer(),
                                                                                             interpreter: interpreter, search: w.h.search,
                                                                                             processes: w.h.processes))
            .ask(task.id, question: "Since when?")
        try await records.flush()
        let written = try String(contentsOf: conversation, encoding: .utf8)
        #expect(written.contains("question: How much?") && written.contains("question: Since when?"),
                "and a question asked afterwards joins them in its file, rather than taking its place")
    }

    @Test func aRebuildRefusedForAListOfDocumentsKeepsTheHistoryOfThemWholeOnceItReadsAgain() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let month = w.h.env.layout.historyFile(month: RecordKind.month(of: w.h.env.time.now()))
        let history = try String(contentsOf: month, encoding: .utf8)
        let text = try String(contentsOf: w.topListing, encoding: .utf8)
        try TestRecordFiles.broken(text).write(to: w.topListing, atomically: true, encoding: .utf8)

        let (database, records) = try w.newIndex()
        await expectRefused([w.topListing.path], "the documents cannot be read, so the history about them is not read without them") {
            try await records.rebuildIfPending()
        }
        #expect(try await records.reconcile() == 0, "nor is anything read into the index, which would take the history's documents for gone")
        let store = HistoryStore(database: database, time: TestTime(.advances))
        // A setting changed meanwhile is made; its event is held until the index holds the archive.
        try await store.record(.paused, summary: Self.meanwhile)
        try await records.flush()
        #expect(try String(contentsOf: month, encoding: .utf8) == history, "and the month's history is not written without them")

        try text.write(to: w.topListing, atomically: true, encoding: .utf8)
        let summary = try #require(try await records.rebuildIfPending(), "once it is corrected, the index is rebuilt")
        let events = try await store.events(limit: 100)
        #expect(events.filter { $0.summary == Self.meanwhile }.count == 1, "and the event held meanwhile is recorded, once")
        #expect(Set(events.compactMap(\.docId)) == Set(w.documents), "every event about a document is about it still")
        let queued = try await JobStore(database: database, time: TestTime(.advances)).active(kinds: [.reindex]).compactMap(\.docId).sorted()
        #expect(summary.documents == w.documents.count && queued == w.documents && events.contains { $0.kind == .rebuilt },
                "and the rebuild's steps after it replaced the index, finding the documents, queueing them and recording it, all ran")
    }

    static let meanwhile = "Paused meanwhile"

    @Test(.folderModesKeepOut) func aFolderTheWatcherIgnoresIsNotLookedIntoByARebuild() async throws {
        let w = try await RecordsWorld.make()
        let ignored = w.h.env.archive.appendingPathComponent("~$Locked", isDirectory: true).standardizedFileURL
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ignored.path)
            w.h.env.cleanup()
        }
        // A folder the watcher ignores, which nobody may list. Incoming is never kept in the archive (`AppSettings.problems`).
        try w.h.env.put("~$Locked/lock.txt", text: "lock")
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: ignored.path)
        let (_, records) = try w.newIndex()
        let summary = try #require(try await records.rebuildIfPending(), "it holds no record file, so it does not stop the rebuild")
        #expect(summary.documents == w.documents.count && summary.adopted == 0, "nor is anything in it taken in")
        try await w.records.reconcile()
        #expect(await w.records.unreadableFiles().isEmpty, "and it is not reported as a record file that cannot be read")
    }

    @Test(.folderModesKeepOut) func aFolderOfTheUsersThatCannotBeListedStopsTheRebuildNamingIt() async throws {
        let w = try await RecordsWorld.make()
        let folder = w.h.env.archive.appendingPathComponent("Kept", isDirectory: true).standardizedFileURL
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            w.h.env.cleanup()
        }
        try w.h.env.put("Kept/\(w.h.env.config.records.documentsFileName)", text: try String(contentsOf: w.topListing, encoding: .utf8))
        // Nobody may list what it holds: the list of documents in it may be there.
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
        let (database, records) = try w.newIndex()
        await expectRefused([folder.path], "the folder is named, as the list of documents in it is not known to be absent") {
            try await records.rebuildIfPending()
        }
        #expect(try await database.pendingRebuild() == .unread, "and the index stays to be rebuilt")
        try await w.records.reconcile()
        #expect(await w.records.unreadableFiles().map(\.path) == [folder.path], "an index that holds the archive reports it too")
    }
}
