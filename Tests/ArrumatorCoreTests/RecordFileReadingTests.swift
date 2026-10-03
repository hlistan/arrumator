@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// What a record file says reaches the index without losing what the index holds (docs/storage.md): a document is the
/// one its identity names, a reference to nothing is dropped rather than failing the read, an entry removed by hand is
/// written back, what the index keeps of its own about an event stays attached to it, and neither a file read back nor a
/// rebuild replaces what was committed after the file, or the archive, was read for it.
@Suite struct RecordFileReadingTests {
    @Test func aFolderCopiedInFromAnotherArchiveNeverTakesTheNumbersOfThisOnesDocuments() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let first = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        // Another archive numbered its documents from 1 too; its folder, list and all, is copied in.
        let copied = try w.h.env.put("Copied/statement.txt", text: "Bank statement")
        try Xattr.set(Xattr.documentID, RecordsWorld.uid(900), on: copied)
        try """
        ---
        arrumator: 1
        entries:
        - id: \(w.documents[0])
          uid: \(RecordsWorld.uid(900))
          file: statement.txt
          original_name: statement.txt
          added: 2026-06-01T10:00:00Z
          filed: 2026-06-01T10:01:00Z
          status: filed
          content_type: public.plain-text
          size: 14
          sha256: abc
        ---
        """.write(to: copied.deletingLastPathComponent().appendingPathComponent(w.h.env.config.records.documentsFileName),
                  atomically: true, encoding: .utf8)
        try await w.records.reconcile()
        let kept = try #require(try await w.h.services.documents.document(id: w.documents[0]))
        #expect(kept.uid == first.uid && kept.path == first.path && kept.labels == first.labels,
                "the document that has the number keeps it, and everything it is")
        let other = try #require(try await w.h.services.documents.document(uid: RecordsWorld.uid(900)))
        let number = try #require(other.id)
        #expect(!w.documents.contains(number) && other.path == copied.path, "the copied document is taken in under a number of its own")
        #expect(try w.listing(in: copied.deletingLastPathComponent()).contains("- id: \(number)\n"), "and its list is written again with it")
    }

    @Test func aCopyWhoseOriginalIsGoneIsReadAsACopyOfNothing() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let file = try env.put("bill copy.txt", text: "EDP electricity July")
        try Xattr.set(Xattr.documentID, RecordsWorld.uid(2), on: file)
        // The original's entry was removed by hand, or its folder was not copied with this one.
        try """
        ---
        arrumator: 1
        entries:
        - id: 2
          uid: \(RecordsWorld.uid(2))
          file: bill copy.txt
          original_name: bill copy.txt
          added: 2026-07-06T10:00:00Z
          filed: 2026-07-06T10:01:00Z
          status: duplicate
          duplicate_of: 1
          content_type: public.plain-text
          size: 20
          sha256: abc
        ---
        """.write(to: env.archive.appendingPathComponent(env.config.records.documentsFileName), atomically: true, encoding: .utf8)
        let records = env.records()
        let summary = try await records.rebuild()
        #expect(summary.documents == 1, "the rebuild is not undone by a reference to a document the archive does not have")
        let copy = try #require(try await DocumentStore(database: env.database, time: env.time).document(id: 2))
        #expect(copy.duplicateOf == nil && copy.path == file.path, "the copy is kept, pointing at nothing, as an event of a document gone does")
        #expect(try await records.reconcile() == 0, "and the archive is read again without failing")
    }

    @Test func anEntryRemovedByHandIsWrittenBack() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let second = try #require(try await w.h.services.documents.document(id: w.documents[1]))
        let text = try String(contentsOf: w.topListing, encoding: .utf8)
        let start = try #require(text.range(of: "- id: \(w.documents[1])\n"))
        // To the next entry, or the end of the front matter.
        let ends = ["\n- id: ", "\n---\n"].compactMap { text.range(of: $0, range: start.upperBound..<text.endIndex)?.lowerBound }
        let end = try #require(ends.min())
        try text.replacingCharacters(in: start.lowerBound..<text.index(after: end), with: "")
            .write(to: w.topListing, atomically: true, encoding: .utf8)
        #expect(!(try String(contentsOf: w.topListing, encoding: .utf8)).contains("uid: \(second.uid)"), "the entry is gone from the file")
        #expect(try await w.records.reconcile() == 1, "the edited file is read")
        #expect(try await w.h.services.documents.document(id: w.documents[1]) != nil, "removing an entry removes no document")
        #expect(try w.listing(in: w.h.env.archive).contains("uid: \(second.uid)"), "and its entry is written back")
    }

    @Test func readingAHistoryFileBackKeepsTheJobAndTraceOfEachEvent() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let linked = { try await w.h.services.history.events(limit: 100).filter { $0.traceId != nil || $0.jobId != nil } }
        let before = try await linked()
        #expect(!before.isEmpty, "filing links events to the job and the trace that made them")
        let url = w.h.env.layout.historyFile(month: RecordKind.month(of: w.h.env.time.now()))
        let text = try String(contentsOf: url, encoding: .utf8)
        // The user corrects a summary by hand.
        let edited = try #require(text.range(of: "summary: ").map { text.replacingCharacters(in: $0, with: "summary: Corrected ") })
        try edited.write(to: url, atomically: true, encoding: .utf8)
        #expect(try await w.records.reconcile() == 1, "the edited month is read back")
        let after = try await linked()
        #expect(after.map(\.id) == before.map(\.id) && after.map(\.jobId) == before.map(\.jobId) && after.map(\.traceId) == before.map(\.traceId),
                "each event keeps the job and trace it was recorded with, which the file does not hold")
        #expect(try await w.h.services.history.events(limit: 100).contains { $0.summary.hasPrefix("Corrected ") }, "and the edit is read")
    }

    @Test func anEventRecordedWhileItsHistoryFileIsReadBackIsKept() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let month = w.h.env.layout.historyFile(month: RecordKind.month(of: w.h.env.time.now()))
        // The user edits the month's history by hand, and the app records an event while the file is read back: after it
        // was read, before what it holds is applied to the index.
        try (try String(contentsOf: month, encoding: .utf8) + "\nEdited by hand\n").write(to: month, atomically: true, encoding: .utf8)
        let history = w.h.services.history
        let recorded = Mutex(false)
        await w.records.setBeforeApplying { url in
            guard url.path == month.path, recorded.withLock({ done in defer { done = true }; return !done }) else { return }
            // From a task of its own, as the app records it.
            _ = try? await Task { try await history.record(.paused, summary: Self.meanwhile) }.value
        }
        #expect(try await w.records.reconcile() == 1, "the edited month is read back")
        #expect(recorded.withLock { $0 }, "with the event recorded meanwhile")
        let kept = try await history.events(limit: 100, kinds: [.paused]).map(\.summary)
        #expect(kept == [Self.meanwhile], "the event is kept, not replaced by what the file held before it")
        #expect(try String(contentsOf: month, encoding: .utf8).contains(Self.meanwhile), "and written into the month's file")
    }

    static let meanwhile = "Recorded while the file was read back"

    @Test func aRuleMadeWhileTheRulesFileIsReadBackIsKeptBesideTheEdit() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        try await w.h.labels.merge(DocumentLabel(kind: .sender, value: "EDP Comercial"), into: "EDP")
        try await w.records.flush()
        let url = w.h.env.layout.labelRules
        // The user changes the rule by hand, and decides about another label while the file is read back.
        try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "target: EDP", with: "target: EDP Energia")
            .write(to: url, atomically: true, encoding: .utf8)
        let labels = w.h.labels
        let decided = Mutex(false)
        await w.records.setBeforeApplying { read in
            guard read.path == url.path, decided.withLock({ done in defer { done = true }; return !done }) else { return }
            _ = try? await Task { try await labels.ignore(DocumentLabel(kind: .topic, value: "electricity")) }.value
        }
        #expect(try await w.records.reconcile() == 1, "the edited rules are read back")
        let rules = try await w.h.services.labels.rules()
        #expect(rules.map(\.target) == ["EDP Energia", nil], "both the edit and the rule decided meanwhile are kept: \(rules.map(\.summary))")
    }

    @Test func aChangeCommittedWhileTheArchiveIsReadForARebuildIsNeverLost() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let before = try await w.records.indexState()
        let (parsed, _) = await w.records.readArchive()
        // The worker, or a command in another process, records something between the reading and the replacing.
        try await w.h.services.history.record(.paused, summary: "Recorded meanwhile")
        #expect(try await w.records.replaceIndex(with: parsed, expecting: before) == false,
                "the index changed after the archive was read, so it is not replaced with what was read")
        let meanwhile = { try await w.h.services.history.events(limit: 100, kinds: [.paused]).map(\.summary) }
        #expect(try await meanwhile() == ["Recorded meanwhile"], "and the change is still in it")
        let summary = try await w.records.rebuild()
        #expect(try await meanwhile() == ["Recorded meanwhile"] && summary.documents == w.documents.count,
                "a rebuild on request writes it into the files first and reads it back with the rest")
    }

    @Test func aChangeCommittedBeforeTheSnapshotOfARebuildIsNeverLostEither() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        // Recorded after the rebuild wrote the files, and before it noted what they hold.
        try await w.h.services.history.record(.paused, summary: "Recorded before the snapshot")
        let before = try await w.records.indexState()
        let (parsed, _) = await w.records.readArchive()
        #expect(try await w.records.replaceIndex(with: parsed, expecting: before) == false,
                "the index holds a change the files do not, so it is not replaced with them")
        #expect(try await w.h.services.history.events(limit: 100, kinds: [.paused]).map(\.summary) == ["Recorded before the snapshot"],
                "and the change is still in it")
    }

    @Test func aRebuildCutShortAfterItReplacedTheIndexIsFinishedAtTheNextOpening() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let database = w.h.env.database
        let before = try await w.records.indexState()
        let (parsed, _) = await w.records.readArchive()
        #expect(try await w.records.replaceIndex(with: parsed, expecting: before), "a rebuild on request replaces the index")
        // The app quits there, before the documents are found on disk and queued to be read again.
        #expect(try await database.pendingRebuild() == .unfinished, "the index says, in the same transaction, that the rebuild is not finished")
        let summary = try #require(try await w.records.rebuildIfPending(), "the next opening finishes it")
        let queued = try await JobStore(database: database, time: TestTime(.advances)).active(kinds: [.reindex]).compactMap(\.docId).sorted()
        #expect(summary.documents == w.documents.count && queued == w.documents, "every document is queued to be read again")
        let pending = try await database.pendingRebuild()
        #expect(try await w.h.services.history.events(limit: 10, kinds: [.rebuilt]).count == 1 && pending == nil,
                "the rebuild is recorded, and the index no longer waits for it")
    }

    @Test func aCopyInAFolderCopiedInIsOfTheDocumentItsOwnListNames() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        func entry(_ id: Int64, uid: Int, file: String, copyOf: Int64?) -> String {
            """
            - id: \(id)
              uid: \(RecordsWorld.uid(uid))
              file: \(file)
              original_name: \(file)
              added: 2026-06-01T10:00:00Z
              status: \(copyOf == nil ? "filed" : "duplicate")
            \(copyOf.map { "  duplicate_of: \($0)\n" } ?? "")  content_type: public.plain-text
              size: 4
              sha256: abc
            """
        }
        // Another archive numbered these 2, 3 and 4; this one has documents 1 and 2.
        for (name, uid) in [("bill.txt", 901), ("bill copy.txt", 902), ("note copy.txt", 903)] {
            try Xattr.set(Xattr.documentID, RecordsWorld.uid(uid), on: try w.h.env.put("Copied/\(name)", text: "bill"))
        }
        let entries = [entry(2, uid: 901, file: "bill.txt", copyOf: nil), entry(3, uid: 902, file: "bill copy.txt", copyOf: 2),
                       entry(4, uid: 903, file: "note copy.txt", copyOf: 1)]
        try ("---\narrumator: 1\nentries:\n" + entries.joined(separator: "\n") + "\n---\n")
            .write(to: w.h.env.archive.appendingPathComponent("Copied/\(w.h.env.config.records.documentsFileName)"), atomically: true, encoding: .utf8)
        try await w.records.reconcile()
        let documents = w.h.services.documents
        let original = try #require(try await documents.document(uid: RecordsWorld.uid(901))?.id)
        let copy = try #require(try await documents.document(uid: RecordsWorld.uid(902)))
        let other = try #require(try await documents.document(uid: RecordsWorld.uid(903)))
        #expect(!w.documents.contains(original) && copy.duplicateOf == original,
                "a copy is of the document its list names, under the number that document was given here")
        #expect(other.duplicateOf == nil, "and one of a document its list does not have is of none of this archive's: \(String(describing: other.duplicateOf))")
    }

    @Test func aConversationWhoseTaskIsGoneFromTheTasksFileIsLeftAsItIsAndItsNumberGivenToNoNewTask() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let interpreter = StubInterpreter(plans: [:])
        let tasks = w.h.searchTasks(interpreter).actions
        let talk = w.h.conversations(StubAnswerer(), interpreter: interpreter).actions
        let kept = try await tasks.create(prompt: "electricity bills")
        let gone = try await tasks.create(prompt: "water bills")
        for task in [kept, gone] { try await talk.ask(task.id, question: "How much?") }
        try await w.records.flush()
        // The user removes the last task from System/_tasks.md by hand, and the index is lost.
        let url = w.h.env.layout.searchTasks
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(text.range(of: "- id: \(gone.id)\n"))
        let end = try #require(text.range(of: "\n---\n", range: start.upperBound..<text.endIndex))
        try text.replacingCharacters(in: start.lowerBound..<text.index(after: end.lowerBound), with: "").write(to: url, atomically: true, encoding: .utf8)
        let conversation = w.h.env.layout.conversationFile(task: gone.id)
        let held = try String(contentsOf: conversation, encoding: .utf8)

        let (database, records) = try w.newIndex()
        _ = try await records.rebuildIfPending()
        var services = w.h.services
        services.database = database
        let queue = SearchTaskQueue(services: services, interpreter: interpreter)
        let next = try await SearchTaskActions(services: services, queue: queue).create(prompt: "phone bills")
        #expect(next.id != gone.id, "a new task is not given the number of the conversation left without its task")
        try await TaskConversationActions(services: services, queue: TaskConversationQueue(services: services, answerer: StubAnswerer(),
                                                                                             interpreter: interpreter, search: w.h.search))
            .ask(next.id, question: "Since when?")
        try await records.flush()
        #expect(try String(contentsOf: conversation, encoding: .utf8) == held, "so the conversation's file is never written over")
        #expect(try await records.reconcile() >= 1, "and it is read again, waiting for its task to come back")
    }
}
