import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// Record files as each earlier release wrote them are read as that release meant them (AGENTS.md §4.2): a field added
/// later is optional where their files lack it, and what a release recorded that no longer exists is dropped as the
/// migration of the index dropped it, never taken for something else and never a reason to leave the file unread.
@Suite struct EarlierRecordFilesTests {
    @Test func anEntryWrittenByAnEarlierVersionIsReadWithItsDocumentUnlabelled() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let directory = env.archive.appendingPathComponent("Home/Utilities/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("2026-07-05 EDP - Fatura.pdf")
        try Data("pdf".utf8).write(to: file)
        // As versions that filed into folders wrote it: tags and a filing decision, no labels and no analysis.
        try """
        ---
        arrumator: 1
        entries:
        - id: 7
          uid: 5B7A8F4E-0000-0000-0000-000000000007
          file: 2026-07-05 EDP - Fatura.pdf
          original_name: fatura.pdf
          added: 2026-07-05T10:00:00Z
          filed: 2026-07-05T10:01:00Z
          status: filed
          sender: EDP Comercial
          document_type: invoice
          date: 2026-07-05
          title: Fatura eletricidade
          language: pt
          tags: [energy]
          decided_by: llm
          confidence: 0.93
          band: auto
          rationale: EDP electricity invoice
          content_type: com.adobe.pdf
          size: 3
          sha256: abc
          decision: {folderCode: F12, title: Fatura eletricidade, confidence: {final: 0.93}}
        ---
        """.write(to: directory.appendingPathComponent(env.config.records.documentsFileName), atomically: true, encoding: .utf8)
        let summary = try await env.records().rebuild()
        #expect(summary.documents == 1, "the earlier version's entry is read")
        let doc = try #require(try await DocumentStore(database: env.database, time: TestTime(.advances)).document(id: 7))
        #expect(doc.path == file.standardizedFileURL.path && doc.status == .filed && doc.originalFilename == "fatura.pdf",
                "a document an earlier version filed into a folder stays where it is")
        let unlabelled = try await DocumentStore(database: env.database, time: TestTime(.advances)).unlabelled()
        #expect(doc.labels == nil && doc.analysis == nil && unlabelled.isEmpty,
                "it has no labels until it is read again; with no stored text yet, it waits for its text to be read first")
    }

    @Test func aCopyAnEarlierVersionFiledStaysOneAndANewCopyHasItsOriginalReadAgain() async throws {
        let analyzer = StubAnalyzer()
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        let text = "EDP electricity July"
        let original = try h.env.put("bill.txt", text: text)
        let filedCopy = try h.env.put("bill copy.txt", text: text)
        let sha = try HashService.sha256(of: original)
        // Each file carries its identity, by which a rebuild finds it.
        for (file, uid) in [(original, RecordsWorld.uid(1)), (filedCopy, RecordsWorld.uid(2))] { try Xattr.set(Xattr.documentID, uid, on: file) }
        // As versions that filed copies wrote them: the copy beside its original, marked as a duplicate of it.
        try """
        ---
        arrumator: 1
        entries:
        - id: 1
          uid: \(RecordsWorld.uid(1))
          file: bill.txt
          original_name: bill.txt
          added: 2026-07-05T10:00:00Z
          filed: 2026-07-05T10:01:00Z
          status: filed
          content_type: public.plain-text
          size: \(text.utf8.count)
          sha256: \(sha)
        - id: 2
          uid: \(RecordsWorld.uid(2))
          file: bill copy.txt
          original_name: bill copy.txt
          added: 2026-07-06T10:00:00Z
          filed: 2026-07-06T10:01:00Z
          status: duplicate
          duplicate_of: 1
          content_type: public.plain-text
          size: \(text.utf8.count)
          sha256: \(sha)
        ---
        """.write(to: h.env.archive.appendingPathComponent(h.env.config.records.documentsFileName), atomically: true, encoding: .utf8)
        try await h.env.records().rebuild()
        let copy = try #require(try await h.services.documents.document(id: 2))
        #expect(copy.status == .duplicate && copy.duplicateOf == 1, "a copy an earlier version filed is read back as the copy it is")
        #expect(try await h.services.jobs.active().map(\.kind) == [.reindex, .reindex], "and both have their text read again for search")

        await h.coordinator.enqueue(try h.env.drop("bill again.txt", text: text))
        await h.coordinator.drain()
        let read = await analyzer.calls.files
        #expect(read == ["bill.txt"],
                "a new copy has the original read by the model again, in place of having only its text read, never the copy filed before: \(read)")
        let after = try #require(try await h.services.documents.document(id: 2))
        #expect(after.status == .duplicate && after.duplicateOf == 1 && after.path == copy.path && FileManager.default.fileExists(atPath: filedCopy.path),
                "which stays as it was, where it was")
        #expect(h.env.trashed().map(\.lastPathComponent) == ["bill again.txt"], "and only the new copy goes to the Trash")
    }

    /// A task as `System/_tasks.md` held it in `release`, asked for electricity invoices of 2025 and exported once,
    /// with document 1 in its set.
    static func task(_ release: TaskRelease, exportedTo folder: URL) -> String {
        """
        ---
        arrumator: 1
        entries:
        - id: 1
          prompt: electricity invoices from 2025
          title: Electricity 2025
          state: ready
        \(release.readWith)  grouping:
          - sender
          model: qwen3:8b
          created: 2026-08-01T09:00:00Z
          updated: 2026-08-01T09:05:00Z
          plan:
            title: Electricity invoices 2025
            labels:
            - kind: type
              value: invoice
            - kind: date
              value: '2025'
            words:
            - electricity
            grouping: []
          documents:
          - document: 1
            inclusion: matched
          exports:
          - id: 1
            at: 2026-08-02T10:00:00Z
            format: folder
            path: \(folder.path)
            files:
            - document: 1
              path: EDP/bill.txt
            skipped: []
        ---
        """
    }

    /// The releases whose `_tasks.md` differ in how a task is read, and the effort each file's task is read with.
    enum TaskRelease: String, CaseIterable, Sendable {
        /// v0.1.7 and v0.1.9: no effort, no model of the task's own.
        case beforeEfforts
        /// v0.1.10: an effort, and the model the user gave the task (`assignedModel`), which is no profile.
        case withAssignedModel

        var readWith: String {
            switch self {
            case .beforeEfforts: ""
            case .withAssignedModel: "  effort: high\n  assignedModel: qwen3.5:9b\n"
            }
        }

        var effort: TaskEffort {
            switch self {
            case .beforeEfforts: .medium
            case .withAssignedModel: .high
            }
        }
    }

    @Test(arguments: TaskRelease.allCases)
    func aTasksFileOfAnEarlierReleaseIsReadAsThatReleaseReadItsTasks(_ release: TaskRelease) async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let bill = try env.put("bill.txt", text: "EDP electricity")
        try Xattr.set(Xattr.documentID, RecordsWorld.uid(1), on: bill)
        try """
        ---
        arrumator: 1
        entries:
        - id: 1
          uid: \(RecordsWorld.uid(1))
          file: bill.txt
          original_name: bill.txt
          added: 2026-07-05T10:00:00Z
          filed: 2026-07-05T10:01:00Z
          status: filed
          content_type: public.plain-text
          size: 15
          sha256: abc
        ---
        """.write(to: env.archive.appendingPathComponent(env.config.records.documentsFileName), atomically: true, encoding: .utf8)
        let url = env.layout.searchTasks
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = Self.task(release, exportedTo: env.root.appendingPathComponent("Exports/Electricity"))
        try text.write(to: url, atomically: true, encoding: .utf8)

        let records = env.records()
        let summary = try await records.rebuild()
        #expect(summary.searchTasks == 1, "the task is read, and the rebuild is not refused for its file: \(summary)")
        let task = try #require(try await SearchTaskStore(database: env.database, config: env.config.tasks, time: env.time).detail(id: 1))
        #expect(task.task.effort == release.effort,
                "a task asked before efforts came is read with medium, as it was then and as migrating the index gave it; a later one with its own")
        #expect(task.task.profile == nil && task.task.name == "Electricity 2025" && task.task.documents == [1],
                "a model given to the task is no profile, and the rest of the task comes back as it was")
    }

    @Test func aHistoryFileOfTheFirstReleasesDropsOnlyEventsOfKindsThatNoLongerExist() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let url = env.layout.historyFile(month: "2026-05")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // As v0.1.1 and v0.1.2 wrote it, when documents were filed into folders and the app learned rules from them.
        try """
        ---
        arrumator: 1
        entries:
        - id: 1
          at: 2026-05-02T09:00:00Z
          kind: arrived
          actor: system
          summary: bill.pdf
          payload: '{}'
        - id: 2
          at: 2026-05-02T09:01:00Z
          kind: classified
          actor: system
          summary: Home/Utilities
          payload: '{}'
        - id: 3
          at: 2026-05-02T09:02:00Z
          kind: filed
          actor: system
          summary: bill.pdf
          payload: '{}'
        - id: 4
          at: 2026-05-02T09:03:00Z
          kind: learned
          actor: system
          summary: Remembered EDP
          payload: '{}'
        - id: 5
          at: 2026-05-03T09:00:00Z
          kind: ruleInduced
          actor: system
          summary: EDP
          payload: '{}'
        ---
        """.write(to: url, atomically: true, encoding: .utf8)
        let records = env.records()
        let summary = try await records.rebuild()
        #expect(summary.events == 2, "the file is read, the events of kinds that still exist with it: \(summary)")
        let events = try await HistoryStore(database: env.database, time: env.time).events(limit: 10, before: TestTime.start)
        #expect(events.map(\.id) == [3, 1] && events.map(\.kind) == [.filed, .arrived],
                "those of kinds that are gone are dropped, as migrating the index dropped them")
        #expect(EventEntry.removedKinds.allSatisfy { EventKind(rawValue: $0) == nil }, "and no kind that exists is ever dropped")
    }
}
