@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// Search tasks (docs/how-it-works.md#search-tasks): a prompt in the user's words becomes a task in a queue, the model
/// reads it into a plan (a double here, `StubInterpreter`), the documents the plan asks for are found and arranged by
/// their labels, and the user edits the set, which finding the documents again respects. Everything reaches History and
/// the archive's `System/_tasks.md`, which a rebuild reads back.
@Suite struct SearchTaskTests {
    static func label(_ kind: LabelKind, _ value: String) -> DocumentLabel { DocumentLabel(kind: kind, value: value) }

    /// Seven documents: bills from three senders over two years, a contract covering a span, a tax assessment, and one
    /// the model found nothing in.
    static let corpus: [String: (labels: [DocumentLabel], text: String)] = [
        "edp_2025_03.txt": ([label(.sender, "EDP Comercial"), label(.type, "invoice"), label(.topic, "electricity"),
                             label(.date, "2025-03-05"), label(.period, "2025-02"), label(.language, "pt")], "EDP electricity invoice, meter reading"),
        "edp_2024_11.txt": ([label(.sender, "EDP Comercial"), label(.type, "invoice"), label(.topic, "electricity"),
                             label(.date, "2024-11-04"), label(.language, "pt")], "EDP electricity invoice"),
        "aguas_2025_05.txt": ([label(.sender, "Águas do Porto"), label(.type, "invoice"), label(.topic, "water"),
                               label(.date, "2025-05-10"), label(.language, "pt")], "Water invoice"),
        "meo_2025_01.txt": ([label(.sender, "MEO"), label(.type, "invoice"), label(.topic, "telecommunications"),
                             label(.date, "2025-01-20")], "Phone invoice"),
        "edp_contract.txt": ([label(.sender, "EDP Comercial"), label(.type, "contract"), label(.topic, "electricity"),
                              label(.date, "2023-06-01"), label(.period, "2023-06/2025-05")], "Electricity supply contract"),
        "tax_2025.txt": ([label(.sender, "Autoridade Tributária"), label(.type, "tax-assessment"), label(.topic, "taxes"),
                          label(.date, "2025-04-15"), label(.period, "2024")], "IRS assessment"),
        "blank.txt": ([], "Nothing to see"),
    ]

    static let prompt = "electricity and water invoices from 2025"
    /// What the model reads `prompt` as: invoices about either topic, issued in 2025, by sender.
    static let invoices2025 = SearchPlan(title: "Utility invoices 2025",
                                         labels: [label(.type, "invoice"), label(.topic, "electricity"), label(.topic, "water"),
                                                  label(.date, "2025")], words: [], grouping: [.sender])

    struct World {
        let h: Harness
        let ids: [String: Int64]

        func id(_ name: String) throws -> Int64 { try #require(ids[name]) }
        func ids(_ names: String...) throws -> Set<Int64> { Set(try names.map(id)) }
    }

    /// The corpus filed one document after another in the order `names` gives, the clock moving on by `apart` seconds
    /// before each, so the last of them is the most recently processed.
    func world(filing names: [String] = SearchTaskTests.corpus.keys.sorted(), apart: Double = 0) async throws -> World {
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: Self.corpus.mapValues(\.labels)))
        var ids: [String: Int64] = [:]
        for name in names {
            h.env.time.advance(by: apart)
            ids[name] = try await h.ingest(name, text: Self.corpus[name]?.text ?? "").id
        }
        return World(h: h, ids: ids)
    }

    /// The corpus's invoices, the newest by their own date first.
    static let invoicesNewestFirst = ["aguas_2025_05.txt", "edp_2025_03.txt", "meo_2025_01.txt", "edp_2024_11.txt"]
    static let invoices = SearchPlan(title: "Invoices", labels: [label(.type, "invoice")], words: [], grouping: [])

    func task(_ tasks: SearchTaskActions, _ id: Int64) async throws -> SearchTask {
        try #require(try await tasks.store.task(id: id))
    }

    /// Events of these kinds in the order they were recorded: the test clock stands still, so by number.
    func events(_ h: Harness, _ kinds: Set<EventKind>) async throws -> [EventRecord] {
        try await h.services.history.events(limit: 100, kinds: kinds).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    // MARK: What a plan finds

    @Test func labelsOfOneKindAreAlternativesAndTheKindsNarrowEachOtherDown() {
        let bill = [Self.label(.type, "invoice"), Self.label(.topic, "water"), Self.label(.date, "2025-05-10")]
        #expect(Self.invoices2025.matches(bill), "an invoice about water from 2025: water is one of the topics asked for")
        #expect(!Self.invoices2025.matches(bill.filter { $0.kind != .type } + [Self.label(.type, "contract")]),
                "a contract is not an invoice, whatever else it has")
        #expect(!Self.invoices2025.matches(bill.filter { $0.kind != .date }), "a document without a date has none in 2025")
        #expect(SearchPlan(title: "", labels: [], words: ["meter"], grouping: []).matches([]), "a plan without labels asks nothing of them")
    }

    @Test func aLabelIsMatchedByItsWordsWhateverTheirCaseAccentsOrPunctuation() {
        func finds(_ kind: LabelKind, _ asked: String, _ has: String) -> Bool {
            SearchPlan(title: "", labels: [Self.label(kind, asked)], words: [], grouping: []).matches([Self.label(kind, has)])
        }
        #expect(finds(.sender, "EDP", "EDP Comercial"), "a name finds the longer names it is part of")
        #expect(finds(.sender, "autoridade tributaria", "Autoridade Tributária"), "case and accents do not matter")
        #expect(finds(.type, "tax return", "tax-return"), "nor does punctuation")
        #expect(finds(.language, "Portuguese", "pt"), "a language is found by its English name too")
        #expect(!finds(.sender, "EDP", "EDPR Renováveis"), "but only whole words: EDP is not EDPR")
        #expect(!finds(.sender, "EDP", "MEO"), "and another name is another sender")
        #expect(finds(.sender, "—", "MEO"), "a value with nothing to match by asks for nothing rather than for nothing to be found")
    }

    @Test func aDatePeriodOrDeadlineIsMatchedByTheTimeItCovers() {
        func finds(_ kind: LabelKind, _ asked: String, _ has: String) -> Bool {
            SearchPlan(title: "", labels: [Self.label(kind, asked)], words: [], grouping: []).matches([Self.label(kind, has)])
        }
        #expect(finds(.date, "2025", "2025-03-05") && finds(.date, "2025-03", "2025-03-31"), "a year or a month holds its days")
        #expect(!finds(.date, "2025-03", "2025-04-01") && !finds(.date, "2025", "2024-12-31"), "and none outside it")
        #expect(finds(.period, "2025", "2024-07/2025-06"), "a span that reaches into the year asked for is in it")
        #expect(finds(.period, "2025-03/2025-06", "2025"), "and a span asked for finds a year that overlaps it")
        #expect(!finds(.deadline, "2025-07/2025-12", "2025-06-30"), "a deadline the day before the span is not in it")
        #expect(TimeSpan("31.07.2026") == TimeSpan("2026-07-31"), "a day-first day is the same day")
        #expect(TimeSpan("soon") == nil, "and what is no time spans nothing")
    }

    @Test func theMatcherFindsDocumentsInTheArchiveWithTheLabelsAndWordsAskedFor() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let matcher = SearchPlanMatcher(database: w.h.env.database, archive: w.h.env.archive, limit: 100)
        #expect(Set(try await matcher.documents(Self.invoices2025)) == (try w.ids("edp_2025_03.txt", "aguas_2025_05.txt")),
                "the 2025 invoices about electricity or water: not the 2024 one, the phone bill, the contract or the tax assessment")
        let meter = SearchPlan(title: "", labels: [Self.label(.sender, "EDP")], words: ["meter \"reading\""], grouping: [])
        #expect(try await matcher.documents(meter) == [try w.id("edp_2025_03.txt")], "words must be in the text, as a phrase")
        let spanning = SearchPlan(title: "", labels: [Self.label(.topic, "electricity"), Self.label(.period, "2025")], words: [], grouping: [])
        #expect(Set(try await matcher.documents(spanning)) == (try w.ids("edp_2025_03.txt", "edp_contract.txt")),
                "a contract whose term reaches into 2025 covers 2025")
        #expect(try await matcher.documents(SearchPlan(title: "", labels: [], words: [], grouping: [])).isEmpty,
                "a plan that asks for nothing finds nothing, not everything")

        try await w.h.review.undo(try w.id("aguas_2025_05.txt"))
        #expect(try await matcher.documents(Self.invoices2025) == [try w.id("edp_2025_03.txt")],
                "a document undone back to Incoming is no longer in the archive")
        let one = SearchPlanMatcher(database: w.h.env.database, archive: w.h.env.archive, limit: 1)
        #expect(try await one.documents(Self.invoices) == [try w.id("edp_2025_03.txt")],
                "at most the limit, the newest by their own date first: the March invoice, not the January one processed after it")
    }

    @Test func aTaskThatFindsMoreThanItsLimitKeepsTheNewestByTheirOwnDateNotTheLastProcessed() async throws {
        // Filed a minute apart, the newest-dated first: the order they were processed in is the reverse of their dates.
        let w = try await world(filing: Self.invoicesNewestFirst, apart: 60)
        defer { w.h.env.cleanup() }
        let newestFirst = try Self.invoicesNewestFirst.map(w.id)
        let matcher = SearchPlanMatcher(database: w.h.env.database, archive: w.h.env.archive, limit: newestFirst.count)
        #expect(try await matcher.documents(Self.invoices) == newestFirst,
                "a task's documents are found newest by their own date first, not the most recently processed first")

        let limit = 2
        let limited = w.h.with { $0.tasks.maxDocuments = limit }
        let nothing = SearchPlan(title: "Nothing yet", labels: [Self.label(.sender, "Nobody")], words: [], grouping: [])
        let (queue, tasks) = limited.searchTasks(StubInterpreter(plans: ["invoices": Self.invoices, "nothing": nothing]))
        let found = try await tasks.create(prompt: "invoices").id
        let empty = try await tasks.create(prompt: "nothing").id
        await queue.drain()
        #expect(try await task(tasks, found).documents == Array(newestFirst.prefix(limit)),
                "finding more than tasks.maxDocuments, a task keeps the newest by their own date, not the last processed")
        #expect(try await tasks.add(empty, labelled: [Self.label(.type, "invoice")]) == Array(newestFirst.prefix(limit)),
                "and adding every document with the chosen labels adds the same ones, so “found” means the same everywhere in a task")
    }

    // MARK: The queue

    @Test func aPromptBecomesATaskThatTheQueuePreparesWithTheDocumentsItAsksFor() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let interpreter = StubInterpreter(plans: [Self.prompt: Self.invoices2025])
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let asked = try await tasks.create(prompt: "  electricity and water\n invoices from 2025 ")
        #expect(asked.state == .queued && asked.prompt == Self.prompt && asked.documents.isEmpty,
                "a prompt is queued as it was written, on one line, and has found nothing yet")
        #expect(asked.name == Self.prompt, "until the model names it, a task goes by its prompt")

        await queue.drain()
        let ready = try await task(tasks, asked.id)
        let reader = try await w.h.env.settings.current.modelProfile().chatModel
        #expect(ready.state == .ready && ready.plan == Self.invoices2025 && ready.model == reader,
                "the task keeps what the model read its prompt as, and which model that was")
        #expect(Set(ready.documents) == (try w.ids("edp_2025_03.txt", "aguas_2025_05.txt")), "and the documents that plan finds")
        #expect(ready.name == "Utility invoices 2025" && ready.grouping == [.sender], "it goes by the model's name and arrangement")
        #expect(await interpreter.calls.days == [TestTime.start.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())],
                "the model is told today's date, from the injected clock, to count “last year” from")
        #expect(await interpreter.calls.vocabularies.first?[.sender]?.first?.label.value == "EDP Comercial",
                "and the archive's labels, the most used first, to ask for them as the archive writes them")
        #expect(try await events(w.h, [.taskCreated, .taskPrepared]).map(\.kind) == [.taskCreated, .taskPrepared],
                "asking and what was found are both in History")
        let traceID = try #require(ready.lastTrace)
        let trace = try #require(try await w.h.services.traces.trace(id: traceID))
        #expect(trace.0.source == TraceSource.task.rawValue && trace.0.outcome == SearchTaskState.ready.rawValue,
                "the run is traced as a task's")
        #expect(trace.1.map(\.stage) == [TraceStage.interpret.rawValue, TraceStage.match.rawValue], "reading the prompt, then finding")
    }

    @Test func withoutAValidAnswerTheTaskFailsWithTheReasonAndCanBeAskedAgain() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [:]))
        let asked = try await tasks.create(prompt: "something the model cannot read")
        await queue.drain()
        let failed = try await task(tasks, asked.id)
        #expect(failed.state == .failed && failed.problem == StubInterpreter.noAnswer && failed.documents.isEmpty,
                "the task says why it found nothing")
        #expect(try await events(w.h, [.taskFailed]).count == 1, "and so does History")
        #expect(try await tasks.retry(asked.id).state == .queued, "asking again puts it back in the queue")
    }

    @Test func whileOllamaCannotBeReachedTheTaskWaitsInTheQueue() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [:], error: OllamaError.unreachable("connection refused")))
        let asked = try await tasks.create(prompt: Self.prompt)
        await queue.drain()
        let waiting = try await task(tasks, asked.id)
        #expect(waiting.state == .queued && waiting.problem == nil, "a server that is down fails nothing: the task waits")
        let due = try #require(try await w.h.env.database.reader.read { db in try SearchTaskRecord.fetchOne(db, key: asked.id) }?.nextRunAt)
        #expect(due == w.h.env.time.now().addingTimeInterval(w.h.env.config.ingest.retryDelays.last),
                "until the last of ingest.retryDelays has passed, as a document waits")
        #expect(try await events(w.h, [.taskFailed]).isEmpty, "and nothing failed")
    }

    @Test func aMissingModelFailsTheTaskWithTheReason() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [:], error: OllamaError.modelNotFound("ministral-3:14b")))
        let asked = try await tasks.create(prompt: Self.prompt)
        await queue.drain()
        let failed = try await task(tasks, asked.id)
        #expect(failed.state == .failed && failed.problem?.contains("ministral-3:14b") == true,
                "a model that is not installed will not appear by waiting, so the task says which one it needs")
    }

    @Test func aTaskInterruptedWhileItsPromptWasReadIsReadAgainFirstAtTheNextStart() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let phones = SearchTaskQueueStatusTests.phones
        let interpreter = StubInterpreter(plans: SearchTaskQueueStatusTests.plans)
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let asked = try await tasks.create(prompt: Self.prompt)
        // The app reads it.
        let app = w.h.processes.start(pid: TestProcesses.otherPID)
        _ = try await tasks.store.begin(asked.id, by: app.description)
        await queue.drain()
        #expect(try await task(tasks, asked.id).state == .interpreting, "a task another process reads is not taken up twice")
        // Another task is asked while the first is read, and the app quits; a command runs a minute later.
        w.h.env.time.advance(by: 60)
        _ = try await tasks.create(prompt: phones)
        w.h.env.time.advance(by: 60)
        w.h.processes.end(app)
        #expect(try await tasks.store.recoverLeft(w.h.processes) == 1, "once that process has ended it goes back into the queue")
        await queue.drain()
        let read = await interpreter.calls.prompts
        #expect(read == [Self.prompt, phones], "and is read first, keeping its place before the task asked after it")
        #expect(try await task(tasks, asked.id).state == .ready, "and is ready then")
    }

    @Test func aPromptChangedWhileItWasBeingReadIsReadAgainWithTheNewOne() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let phones = "phone bills"
        let phonePlan = SearchPlan(title: "Phone bills", labels: [Self.label(.topic, "telecommunications")], words: [], grouping: [])
        let holder = TaskHolder()
        let interpreter = StubInterpreter(plans: [Self.prompt: Self.invoices2025, phones: phonePlan]) { prompt in
            // The user changes the prompt from the app, in a task of its own, while the first one is being read.
            if prompt == Self.prompt, let tasks = await holder.tasks, let id = await holder.id {
                _ = try await Task { try await tasks.update(id, SearchTaskChange(prompt: phones)) }.value
            }
        }
        let (queue, tasks) = w.h.searchTasks(interpreter)
        let asked = try await tasks.create(prompt: Self.prompt)
        await holder.set(tasks, asked.id)
        await queue.drain()
        let ready = try await task(tasks, asked.id)
        #expect(await interpreter.calls.prompts == [Self.prompt, phones], "the old prompt's reading is dropped and the new one read")
        let meo = try w.id("meo_2025_01.txt")
        #expect(ready.plan == phonePlan && ready.documents == [meo], "the task has what the new prompt asks for")
    }

    // MARK: Editing the set

    @Test func theUserEditsTheSetAndFindingTheDocumentsAgainRespectsIt() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [Self.prompt: Self.invoices2025]))
        let id = try await tasks.create(prompt: Self.prompt).id
        await queue.drain()
        let (edp, aguas, meo) = (try w.id("edp_2025_03.txt"), try w.id("aguas_2025_05.txt"), try w.id("meo_2025_01.txt"))

        #expect(try await tasks.remove(id, documents: [aguas, meo]) == [aguas], "only a document in the set can be taken out")
        #expect(try await tasks.add(id, documents: [meo, edp, meo]) == [meo], "a document already in the set is not added twice")
        var edited = try await task(tasks, id)
        #expect(edited.documents == [edp, meo] && edited.removed == [aguas] && edited.added == [meo], "the set is what the user left in it")

        _ = try await tasks.retry(id)
        await queue.drain()
        edited = try await task(tasks, id)
        #expect(Set(edited.documents) == [edp, meo], "finding the documents again leaves out what the user took out, and keeps what they added")
        #expect(try await tasks.add(id, documents: [aguas]) == [aguas], "a document taken out can be added back")
        #expect(try await task(tasks, id).removed.isEmpty, "and then it is no longer out")
        #expect(try await events(w.h, [.taskEdited]).count == 4, "each edit and asking again is in History")
    }

    @Test func documentsAreAddedByTheLabelsTheyHaveAsTheSidebarNarrowsThemDown() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [Self.prompt: Self.invoices2025]))
        let id = try await tasks.create(prompt: Self.prompt).id
        await queue.drain()
        let added = try await tasks.add(id, labelled: [Self.label(.sender, "edp comercial"), Self.label(.type, "invoice")])
        #expect(added == [try w.id("edp_2024_11.txt")], "every EDP invoice not yet in the set, the label matched however it is written")
    }

    @Test func aDocumentThatDoesNotExistIsRefusedAndNothingChanges() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [Self.prompt: Self.invoices2025]))
        let id = try await tasks.create(prompt: Self.prompt).id
        await queue.drain()
        let before = try await task(tasks, id)
        await #expect(throws: SearchTaskError.documentNotFound(999), "an unknown number is named in the error") {
            try await tasks.add(id, documents: [try w.id("meo_2025_01.txt"), 999])
        }
        #expect(try await task(tasks, id).documents == before.documents, "and the documents before it are not added either")
        await #expect(throws: SearchTaskError.taskNotFound(42)) { try await tasks.remove(42, documents: [1]) }
        await #expect(throws: SearchTaskError.emptyPrompt, "an empty prompt asks for nothing") { try await tasks.create(prompt: " \n ") }
    }

    @Test func aTaskIsRenamedArrangedOtherwiseOrAskedSomethingElse() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [Self.prompt: Self.invoices2025]))
        let id = try await tasks.create(prompt: Self.prompt).id
        await queue.drain()

        var changed = try await tasks.update(id, SearchTaskChange(title: "For the accountant", grouping: .by([.date, .sender])))
        #expect(changed.name == "For the accountant" && changed.grouping == [.date, .sender] && changed.groupedByUser,
                "the user's name and arrangement take the place of the model's")
        #expect(changed.state == .ready, "and nothing needs finding again")
        changed = try await tasks.update(id, SearchTaskChange(title: "", grouping: .asAsked))
        #expect(changed.name == "Utility invoices 2025" && changed.grouping == [.sender] && !changed.groupedByUser,
                "an empty name and `asked` give the model's back")
        changed = try await tasks.update(id, SearchTaskChange(grouping: .by([])))
        #expect(changed.grouping.isEmpty && changed.groupedByUser, "the set can be listed without arranging it")
        await #expect(throws: SearchTaskError.groupingTooDeep(w.h.env.config.tasks.maxGroupingDepth)) {
            try await tasks.update(id, SearchTaskChange(grouping: .by([.type, .sender, .date, .topic])))
        }
        await #expect(throws: SearchTaskError.groupingRepeats(.sender)) {
            try await tasks.update(id, SearchTaskChange(grouping: .by([.sender, .sender])))
        }
        changed = try await tasks.update(id, SearchTaskChange(prompt: "phone bills"))
        #expect(changed.state == .queued && changed.prompt == "phone bills", "another prompt sends the task back into the queue")
        #expect(try await events(w.h, [.taskEdited]).count == 4, "each change that changed something is in History")
    }

    @Test func removingATaskRemovesItsSetAndTheRecordOfItsExports() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [Self.prompt: Self.invoices2025]))
        let id = try await tasks.create(prompt: Self.prompt).id
        await queue.drain()
        let out = w.h.env.root.appendingPathComponent("Out", isDirectory: true)
        let export = try await tasks.export(id, to: out, format: .folder)
        try await tasks.delete(id)
        #expect(try await tasks.store.task(id: id) == nil, "the task is gone")
        let left = try await w.h.env.database.reader.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_task_documents") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_task_exports") ?? -1)
        }
        #expect(left == (0, 0), "with its set and its exports")
        #expect(FileManager.default.fileExists(atPath: export.path), "but what it exported is the user's, and stays")
        #expect(try await events(w.h, [.taskRemoved]).count == 1, "and the removal is in History")
        await #expect(throws: SearchTaskError.taskNotFound(id)) { try await tasks.delete(id) }
    }

    // MARK: Arranging

    /// A document with these labels, numbered `id`.
    static func document(_ id: Int64, _ name: String, _ labels: [DocumentLabel]) throws -> DocumentRecord {
        var d = DocumentRecord.arrived(path: "/archive/\(name)", sha256: name, size: 1, uttype: "public.data", inode: nil, modified: nil,
                                       now: TestTime.start)
        d.id = id
        d.labelsJson = try JSON.string(labels)
        return d
    }

    @Test func theSetIsArrangedALevelPerKindYearsNewestFirstAndTheUnlabelledLast() throws {
        let docs = [
            try Self.document(1, "b.pdf", [Self.label(.sender, "EDP Comercial"), Self.label(.date, "2025-03-05")]),
            try Self.document(2, "a.pdf", [Self.label(.sender, "edp comercial"), Self.label(.date, "2025-01-10")]),
            try Self.document(3, "c.pdf", [Self.label(.sender, "Águas do Porto"), Self.label(.period, "2024-07/2025-06")]),
            try Self.document(4, "d.pdf", [Self.label(.date, "2024-02-01")]),
            try Self.document(5, "e.pdf", [Self.label(.sender, "EDP Comercial"), Self.label(.date, "2024-12-01")]),
        ]
        let tree = DocumentGrouping.tree(docs, by: [.sender, .date])
        #expect(tree.groups.map(\.value) == ["Águas do Porto", "EDP Comercial", nil],
                "senders alphabetically, accents aside, one group however a sender is cased, and those without one last")
        let edp = tree.groups[1]
        #expect(edp.groups.map(\.value) == ["2025", "2024"] && edp.count == 3, "by year, the newest first")
        #expect(edp.groups[0].documents.compactMap(\.id) == [1, 2], "and within a year by their own date, the newest first")
        #expect(tree.groups[0].groups.map(\.value) == [nil], "a document without a date goes with those that have none")
        #expect(tree.count == docs.count && tree.documents.isEmpty, "every document is somewhere in the tree, once")
        let flat = DocumentGrouping.tree(docs, by: [])
        #expect(flat.groups.isEmpty && flat.documents.compactMap(\.id) == [1, 2, 5, 4, 3], "unarranged, the newest date first, the undated last")
        #expect(DocumentGrouping.value(of: docs[2], kind: .period) == "2024", "a span is arranged by the year it starts in")
    }

    @Test func documentsOfOneDateFollowTheirNameThenTheirNumber() throws {
        let day = Self.label(.date, "2025-03-05")
        let docs = [try Self.document(13, "b/same.pdf", [day]), try Self.document(12, "a/same.pdf", [day]), try Self.document(11, "bill 10.pdf", [day]),
                    try Self.document(10, "bill 9.pdf", [day]), try Self.document(9, "undated.pdf", [])]
        #expect(DocumentGrouping.tree(docs, by: [.type]).groups.first?.documents.compactMap(\.id) == [10, 11, 12, 13, 9],
                "one date by name as Finder sorts it, numbers by their value; one name by number, so the order is the same however they came")
    }

    // MARK: The archive's record

    @Test func tasksAndTheirExportsAreWrittenIntoTheArchiveAndComeBackAfterARebuild() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [Self.prompt: Self.invoices2025]))
        let id = try await tasks.create(prompt: Self.prompt).id
        await queue.drain()
        _ = try await tasks.remove(id, documents: [try w.id("aguas_2025_05.txt")])
        _ = try await tasks.add(id, documents: [try w.id("meo_2025_01.txt")])
        _ = try await tasks.update(id, SearchTaskChange(title: "For the accountant", grouping: .by([.date])))
        _ = try await tasks.export(id, to: w.h.env.root.appendingPathComponent("Out", isDirectory: true), format: .folder)
        let waiting = try await tasks.create(prompt: "phone bills", effort: .high, profile: "smart").id

        let records = w.h.env.records()
        try await records.flush()
        let file = try String(contentsOf: w.h.env.layout.searchTasks, encoding: .utf8)
        #expect(file.contains("prompt: \(Self.prompt)") && file.contains("inclusion: removed") && file.contains("format: folder"),
                "the prompt, the set as the user edited it and the exports are in System/_tasks.md")
        #expect(file.contains("| \(id) | For the accountant |"), "with a table of the tasks for people")
        #expect(file.contains("effort: high") && file.contains("profile: smart") && file.contains("effort: medium"),
                "each task's effort, and the profile the user gave it")
        #expect(file.components(separatedBy: "profile:").count == 2, "a task that follows Settings' profile names none")

        let database = try AppDatabase.inMemory()
        let summary = try await w.h.env.records(index: database).rebuild()
        #expect(summary.searchTasks == 2, "a rebuild reads both tasks back")
        let rebuilt = SearchTaskStore(database: database, config: w.h.env.config.tasks, time: w.h.env.time)
        let before = try await task(tasks, id)
        let after = try #require(try await rebuilt.task(id: id))
        #expect(after.prompt == before.prompt && after.title == before.title && after.plan == before.plan && after.state == .ready,
                "the task comes back as it was")
        #expect(after.documents == before.documents && after.removed == before.removed && after.added == before.added,
                "with its set as the user left it")
        #expect(after.exports == before.exports && after.grouping == [.date], "its exports and its arrangement")
        #expect(after.lastTrace == nil, "traces are the index's own and are not kept")
        let again = try #require(try await rebuilt.task(id: waiting))
        #expect(again.state == .queued && again.effort == .high && again.profile == "smart",
                "a task that was waiting is waiting again, to be read as it was asked")
        #expect(after.effort == before.effort && after.profile == nil, "and one that follows Settings' profile still does")
    }

    @Test func aRecordOfTasksWrittenBeforeProfilesComesBackFollowingSettingsProfile() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        try FileManager.default.createDirectory(at: h.env.layout.searchTasks.deletingLastPathComponent(), withIntermediateDirectories: true)
        // As the version that gave tasks a model of their own wrote it: the model, and no profile.
        try """
        ---
        arrumator: 1
        entries:
        - id: 3
          prompt: water bills
          state: ready
          effort: high
          assignedModel: qwen3.5:9b
          created: 2026-07-05T10:00:00Z
          updated: 2026-07-05T10:00:00Z
          documents: []
          exports: []
        ---
        """.write(to: h.env.layout.searchTasks, atomically: true, encoding: .utf8)
        let summary = try await h.env.records().rebuild()
        #expect(summary.searchTasks == 1, "the earlier version's task is read")
        let interpreter = StubInterpreter(plans: ["water bills": Self.invoices2025])
        let (queue, tasks) = h.searchTasks(interpreter)
        let back = try await task(tasks, 3)
        #expect(back.prompt == "water bills" && back.effort == .high && back.state == .ready, "as it was asked")
        #expect(back.profile == nil, "the model it was given is no profile, so it follows the one Settings uses, as the migration has it")
        _ = try await tasks.retry(3)
        await queue.drain()
        let inUse = try await h.env.settings.current.modelProfile()
        #expect(await interpreter.calls.readings == [StubInterpreter.Reading(effort: .high, profile: inUse)],
                "and is read by Settings' profile, never by the model the dropped key named")
    }
}

/// Lets the interpreter double reach the task being read, which exists only once the queue does.
actor TaskHolder {
    var tasks: SearchTaskActions?
    var id: Int64?

    func set(_ tasks: SearchTaskActions, _ id: Int64) {
        self.tasks = tasks
        self.id = id
    }
}

/// A task's name, as the card's field gives it back.
extension SearchTaskTests {
    @Test func aNameLeftAsItWasStaysTheModelsAndIsNoChange() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [Self.prompt: Self.invoices2025]))
        let id = try await tasks.create(prompt: Self.prompt).id
        await queue.drain()
        // The card's name field shows the model's name, and gives it back when the user leaves it unchanged.
        let left = try await tasks.update(id, SearchTaskChange(title: Self.invoices2025.title))
        #expect(left.title == nil && left.name == Self.invoices2025.title, "the name stays the model's, to follow its next reading")
        #expect(try await events(w.h, [.taskEdited]).isEmpty, "and nothing is recorded, as nothing changed")
        let named = try await tasks.update(id, SearchTaskChange(title: "For the accountant"))
        _ = try await tasks.update(id, SearchTaskChange(title: "For the accountant"))
        #expect(named.title == "For the accountant", "a name of the user's is theirs")
        #expect(try await events(w.h, [.taskEdited]).count == 1, "and giving it again changes nothing more")
    }
}
