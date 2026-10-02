@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// Talking with a task's documents (docs/how-it-works.md#talking-with-a-tasks-documents): a question about a task's set
/// joins a queue of its own, and the model (a double here, `StubAnswerer`) answers it from the set as it is when its turn
/// comes, so adding documents and taking them out changes what the next answer draws on. An answer asked to find more
/// has its request read as a task's is, and what it finds outside the set waits for the user to add it. Questions wait
/// for Ollama, fail with the reason, can be stopped, asked again and cleared, and reach the archive's
/// `System/Conversations`, which a rebuild reads back.
@Suite struct ConversationTests {
    private let suite = SearchTaskTests()
    static let question = "What do these invoices come to?"
    static let reply = StubAnswerer.Reply(text: "Two invoices, 54.21 EUR and 18.40 EUR.")

    /// The corpus filed, and a task of its 2025 electricity and water invoices.
    struct World {
        let w: SearchTaskTests.World
        let tasks: SearchTaskActions
        let task: SearchTask
        var h: Harness { w.h }
        func id(_ name: String) throws -> Int64 { try w.id(name) }
    }

    func world(_ change: (inout PipelineConfig) -> Void = { _ in }) async throws -> World {
        let base = try await suite.world()
        let w = SearchTaskTests.World(h: base.h.with(change), ids: base.ids)
        let (queue, tasks) = w.h.searchTasks(StubInterpreter(plans: [SearchTaskTests.prompt: SearchTaskTests.invoices2025]))
        let task = try await tasks.create(prompt: SearchTaskTests.prompt)
        await queue.drain()
        return World(w: w, tasks: tasks, task: try await suite.task(tasks, task.id))
    }

    /// A value set once something that needs it exists, such as the actions a double calls while it answers.
    final class Later<Value: Sendable>: Sendable {
        private let value = Mutex<Value?>(nil)
        func set(_ new: Value) { value.withLock { $0 = new } }
        func get() throws -> Value { try #require(value.withLock { $0 }) }
    }

    private func turn(_ talk: TaskConversationActions, _ id: Int64) async throws -> TaskTurn {
        try #require(try await talk.store.turn(id: id))
    }

    // MARK: Asking

    @Test func aQuestionIsAnsweredFromTheSetAsItIsWhenItsTurnComes() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (edp, water, contract) = (try w.id("edp_2025_03.txt"), try w.id("aguas_2025_05.txt"), try w.id("edp_contract.txt"))
        let answerer = StubAnswerer(replies: [Self.question: StubAnswerer.Reply(text: Self.reply.text, sources: [edp, water])])
        let (queue, talk) = w.h.conversations(answerer, interpreter: StubInterpreter(plans: [:]))
        let asked = try await talk.ask(w.task.id, question: "  \(Self.question)\n")
        #expect(asked.question == Self.question && asked.state == .queued && asked.answer == nil,
                "the question joins the queue, without the space around it")
        await queue.drain()
        let profile = try await w.h.env.settings.current.modelProfile()
        let answered = try await turn(talk, asked.id)
        #expect(answered.state == .answered && answered.answer == Self.reply.text && answered.sources == [edp, water],
                "it is answered, with the documents the answer draws on")
        #expect(answered.model == profile.chatModel && answered.answered == w.h.env.time.now(),
                "by the model of the profile the task follows, and when")
        #expect(await answerer.calls.readings == [StubInterpreter.Reading(effort: w.task.effort, profile: profile)],
                "with the task's effort and profile")
        let first = try #require(await answerer.calls.contexts.first)
        #expect(Set(first.documents.map(\.id)) == [edp, water] && first.read.count == 2 && first.conversation.isEmpty,
                "shown every document of the set, each with its text, and no conversation before it")

        _ = try await w.tasks.add(w.task.id, documents: [contract])
        _ = try await w.tasks.remove(w.task.id, documents: [water])
        _ = try await talk.ask(w.task.id, question: "And the contract?")
        await queue.drain()
        let second = try #require(await answerer.calls.contexts.last)
        #expect(Set(second.documents.map(\.id)) == [edp, contract],
                "the next answer draws on the set as it is then: the document added in, the one taken out not")
        #expect(second.conversation == [Exchange(question: Self.question, answer: Self.reply.text)], "and is shown the conversation so far")
        let traceID = try #require(answered.lastTrace, "the answer was traced")
        let trace = try #require(try await w.h.services.traces.trace(id: traceID))
        #expect(trace.0.source == TraceSource.conversation.rawValue && trace.1.map(\.stage) == ["context", "answer"],
                "the answer is traced: what it was shown, then how it was answered")
    }

    @Test func aQuestionWithoutWordsTooLongOrAboutNoTaskIsRefusedAndNothingIsAsked() async throws {
        let w = try await world { $0.conversation.maxQuestionChars = 10 }
        defer { w.h.env.cleanup() }
        let (_, talk) = w.h.conversations(StubAnswerer(), interpreter: StubInterpreter(plans: [:]))
        await #expect(throws: ConversationError.emptyQuestion, "a question needs words") { try await talk.ask(w.task.id, question: " \n ") }
        await #expect(throws: ConversationError.questionTooLong(10), "and at most conversation.maxQuestionChars of them") {
            try await talk.ask(w.task.id, question: "far too long a question")
        }
        await #expect(throws: SearchTaskError.taskNotFound(999), "about a task there is") { try await talk.ask(999, question: "why?") }
        #expect(try await talk.store.turns(task: w.task.id).isEmpty, "nothing was asked")
        await #expect(throws: ConversationError.turnNotFound(999), "nor is a question there is not asked again") { try await talk.askAgain(999) }
    }

    // MARK: Finding more

    @Test func anAnswerAskedForMoreSuggestsWhatItFindsOutsideTheSetAndNeverAddsIt() async throws {
        let w = try await world { $0.conversation.maxSuggested = 1 }
        defer { w.h.env.cleanup() }
        let (contract, water) = (try w.id("edp_contract.txt"), try w.id("aguas_2025_05.txt"))
        let contracts = SearchPlan(title: "Contracts", labels: [SearchTaskTests.label(.type, "contract")], words: [], grouping: [])
        let answerer = StubAnswerer(replies: [
            "Find the contract": StubAnswerer.Reply(text: "Looking for it.", find: "the electricity contract"),
            "Find all invoices": StubAnswerer.Reply(text: "Looking for them.", find: "every invoice"),
            "Find the water bill": StubAnswerer.Reply(text: "Looking for it.", find: "water invoices"),
        ])
        let interpreter = StubInterpreter(plans: ["the electricity contract": contracts, "every invoice": SearchTaskTests.invoices,
                                                  "water invoices": SearchTaskTests.invoices2025])
        let (queue, talk) = w.h.conversations(answerer, interpreter: interpreter)
        let contractTurn = try await talk.ask(w.task.id, question: "Find the contract")
        let invoicesTurn = try await talk.ask(w.task.id, question: "Find all invoices")
        await queue.drain()
        let found = try #require(try await turn(talk, contractTurn.id).finding)
        #expect(found == TurnFinding(request: "the electricity contract", plan: contracts, documents: [contract], problem: nil),
                "the request is read as a task's is, and what it finds outside the set is kept with the answer")
        #expect(try await suite.task(w.tasks, w.task.id).documents == w.task.documents, "the set changes only when the user adds them")
        let readings = await interpreter.calls.readings
        #expect(readings.last?.effort == w.task.effort, "the request is read with the task's effort")
        let invoices = try #require(try await turn(talk, invoicesTurn.id).finding)
        #expect(invoices.documents == [try w.id("meo_2025_01.txt")],
                "at most conversation.maxSuggested documents, the newest by their own date, none of the set's")
        let traceID = try #require(try await turn(talk, contractTurn.id).lastTrace, "the answer was traced")
        let trace = try #require(try await w.h.services.traces.trace(id: traceID))
        #expect(trace.1.map(\.stage) == ["context", "answer", "interpret", "match"], "reading the request and finding are traced with the answer")

        _ = try await w.tasks.remove(w.task.id, documents: [water])
        let waterTurn = try await talk.ask(w.task.id, question: "Find the water bill")
        await queue.drain()
        #expect(try await turn(talk, waterTurn.id).finding?.documents == [], "a document the user took out is not suggested again")
    }

    @Test func aRequestForMoreThatCannotBeReadSaysWhyAndTheAnswerIsKept() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let answerer = StubAnswerer(fallback: StubAnswerer.Reply(text: "Looking for it.", find: "something unclear"))
        let (queue, talk) = w.h.conversations(answerer, interpreter: StubInterpreter(plans: [:]))
        let asked = try await talk.ask(w.task.id, question: "Find more")
        await queue.drain()
        let answered = try await turn(talk, asked.id)
        #expect(answered.state == .answered && answered.answer == "Looking for it.", "the answer is kept")
        #expect(answered.finding == TurnFinding(request: "something unclear", plan: nil, documents: [], problem: StubInterpreter.noAnswer),
                "with why nothing was found")
    }

    // MARK: Waiting, failing, stopping

    @Test func aQuestionWaitsWhileOllamaIsAwayAndIsAnsweredOnceItIsBack() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (away, talk) = w.h.conversations(StubAnswerer(error: OllamaError.unreachable("down")), interpreter: StubInterpreter(plans: [:]))
        let asked = try await talk.ask(w.task.id, question: Self.question)
        await away.drain()
        let waiting = try await turn(talk, asked.id)
        #expect(waiting.state == .queued && waiting.problem == nil, "the question waits in the queue, no failure")
        let status = await away.status
        let retry = w.h.env.time.now().addingTimeInterval(try #require(w.h.env.config.ingest.retryDelays.last))
        #expect(status.waitingForOllama && status.queued == 1 && status.retryAt == retry, "and the queue says it waits for Ollama, until when")
        #expect(status.progress(of: waiting) == .waitingForOllama(until: retry), "which the question shows")
        let (back, _) = w.h.conversations(StubAnswerer(fallback: Self.reply), interpreter: StubInterpreter(plans: [:]))
        await back.drain()
        #expect(try await turn(talk, asked.id).state == .queued, "it is not tried again before its time")
        w.h.env.time.advance(by: try #require(w.h.env.config.ingest.retryDelays.last))
        await back.drain()
        #expect(try await turn(talk, asked.id).answer == Self.reply.text, "and is answered once it is due and Ollama answers")
    }

    @Test func aQuestionAModelCannotAnswerFailsWithTheReasonAndCanBeAskedAgain() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let missing = OllamaError.modelNotFound("ministral-3:14b")
        let (failing, talk) = w.h.conversations(StubAnswerer(error: missing), interpreter: StubInterpreter(plans: [:]))
        let asked = try await talk.ask(w.task.id, question: Self.question)
        await failing.drain()
        let failed = try await turn(talk, asked.id)
        #expect(failed.state == .failed && failed.problem == missing.localizedDescription && failed.answer == nil,
                "the question fails saying which model is missing")
        #expect(await !failing.status.waitingForOllama, "Ollama answered, so nothing waits for it")
        let (working, again) = w.h.conversations(StubAnswerer(fallback: Self.reply), interpreter: StubInterpreter(plans: [:]))
        let requeued = try await again.askAgain(asked.id)
        #expect(requeued.state == .queued && requeued.problem == nil && requeued.answer == nil, "asked again, it is back in the queue")
        await #expect(throws: ConversationError.stillAnswering(asked.id), "and is not asked again while it waits") {
            try await again.askAgain(asked.id)
        }
        await working.drain()
        #expect(try await turn(talk, asked.id).answer == Self.reply.text, "then answered in its place")
    }

    @Test func aQuestionOfATaskWhoseProfileIsGoneFailsSayingSo() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let mine = try await w.h.env.settings.current.modelProfile()
        try await w.h.env.settings.update { $0.modelProfiles["mine"] = ModelProfile(name: "Mine", position: 9, chatModel: mine.chatModel,
                                                                                    visionModel: mine.visionModel, embedModel: mine.embedModel) }
        _ = try await w.tasks.update(w.task.id, SearchTaskChange(profile: "mine"))
        try await w.h.env.settings.update { $0.modelProfiles["mine"] = nil }
        let answerer = StubAnswerer()
        let (queue, talk) = w.h.conversations(answerer, interpreter: StubInterpreter(plans: [:]))
        let asked = try await talk.ask(w.task.id, question: Self.question)
        await queue.drain()
        let failed = try await turn(talk, asked.id)
        #expect(failed.state == .failed && failed.problem == ModelProfileError.unknown("mine").localizedDescription,
                "a profile the settings no longer list fails the question, saying so")
        #expect(await answerer.calls.questions.isEmpty, "and no other profile answers in its place")
    }

    @Test func aQuestionBeingAnsweredWhenTheAppStoppedIsAnsweredFirstAtTheNextStart() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, talk) = w.h.conversations(StubAnswerer(fallback: Self.reply), interpreter: StubInterpreter(plans: [:]))
        let first = try await talk.ask(w.task.id, question: Self.question)
        let second = try await talk.ask(w.task.id, question: "And the second?")
        _ = try await talk.store.begin(first.id)
        #expect(try await turn(talk, first.id).state == .answering, "as the app left it")
        await queue.start()
        let answered = await Patience.until { (try? await talk.store.turn(id: second.id))?.state == .answered }
        await queue.stop()
        #expect(answered, "both are answered once the queue starts again")
        let traces = try await [first.id, second.id].asyncMap { try await turn(talk, $0).lastTrace ?? 0 }
        #expect(traces[0] < traces[1], "the one interrupted first, in its place")
    }

    @Test func stoppingAQuestionKeepsWhatCameOfItsAnswerAndOneWaitingIsTakenOut() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let actions = Later<TaskConversationActions>()
        let stopping = Later<Int64>()
        // The user stops it from the app, in a task of its own, not in the one answering.
        let answerer = StubAnswerer(fallback: Self.reply) { _ in try await Task { try await actions.get().stop(try stopping.get()) }.value }
        let (queue, talk) = w.h.conversations(answerer, interpreter: StubInterpreter(plans: [:]))
        actions.set(talk)
        let asked = try await talk.ask(w.task.id, question: Self.question)
        stopping.set(asked.id)
        await queue.drain()
        let stopped = try await turn(talk, asked.id)
        #expect(stopped.state == .failed && stopped.problem == TaskConversationQueue.stoppedProblem,
                "a question stopped as it is answered says it was stopped")
        #expect(stopped.answer == "Two", "and keeps what came of its answer")

        let waiting = try await talk.ask(w.task.id, question: "Another?")
        try await talk.stop(waiting.id)
        let withdrawn = try await turn(talk, waiting.id)
        #expect(withdrawn.state == .failed && withdrawn.problem == TaskConversationQueue.stoppedProblem && withdrawn.answer == nil,
                "one waiting is taken out of the queue, with nothing to keep")
        try await talk.stop(waiting.id)
        #expect(try await turn(talk, waiting.id) == withdrawn, "a question no longer in the queue is left as it is")
        await #expect(throws: ConversationError.turnNotFound(999), "and one there is not is no question") { try await talk.stop(999) }
    }

    @Test func anAnswerFinishedByAnotherProcessAfterItWasStoppedIsNotKept() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (_, talk) = w.h.conversations(StubAnswerer(), interpreter: StubInterpreter(plans: [:]))
        let asked = try await talk.ask(w.task.id, question: Self.question)
        _ = try await talk.store.begin(asked.id)
        try await talk.stop(asked.id)
        let kept = try await talk.store.finish(asked.id, answer: TaskAnswer(text: "late", sources: [], find: nil, model: "m", problem: nil),
                                               finding: nil, trace: nil)
        let after = try await turn(talk, asked.id)
        #expect(!kept && after.answer == nil && after.state == .failed,
                "a question stopped while another process answered it keeps nothing of that answer")
    }

    // MARK: Clearing and the conversation as it is read

    @Test func clearingAConversationRemovesEveryQuestionEvenOneBeingAnsweredAndHistoryRecordsIt() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let actions = Later<TaskConversationActions>()
        let task = w.task.id
        // The user clears it from the app, in a task of its own, not in the one answering.
        let answerer = StubAnswerer(replies: ["Clear it": StubAnswerer.Reply(text: "Never kept")]) { question in
            if question == "Clear it" { _ = try await Task { try await actions.get().clear(task) }.value }
        }
        let (queue, talk) = w.h.conversations(answerer, interpreter: StubInterpreter(plans: [:]))
        actions.set(talk)
        _ = try await talk.ask(task, question: Self.question)
        _ = try await talk.ask(task, question: "And then?")
        await queue.drain()
        #expect(try await talk.clear(task) == 2, "both questions go")
        #expect(try await talk.store.turns(task: task).isEmpty, "with their answers")
        let cleared = try await suite.events(w.h, [.taskEdited]).last
        #expect(cleared?.summary == "Cleared the conversation about “\(w.task.name)”: 2 questions" && cleared?.actor == .user,
                "History records it")
        #expect(try await talk.clear(task) == 0, "clearing an empty conversation removes nothing")
        await #expect(throws: SearchTaskError.taskNotFound(999), "nor clears that of a task there is not") { try await talk.clear(999) }

        _ = try await talk.ask(task, question: "Clear it")
        await queue.drain()
        #expect(try await talk.store.turns(task: task).isEmpty, "an answer being written when its conversation is cleared is not kept")
    }

    @Test func theConversationShowsTheChangesMadeToTheSetBetweenItsQuestions() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, talk) = w.h.conversations(StubAnswerer(fallback: Self.reply), interpreter: StubInterpreter(plans: [:]))
        _ = try await w.tasks.update(w.task.id, SearchTaskChange(title: "Before"))
        w.h.env.time.advance(by: 1)
        _ = try await talk.ask(w.task.id, question: Self.question)
        await queue.drain()
        w.h.env.time.advance(by: 1)
        _ = try await w.tasks.add(w.task.id, documents: [try w.id("edp_contract.txt")])
        w.h.env.time.advance(by: 1)
        _ = try await talk.ask(w.task.id, question: "And now?")
        let items = try await talk.store.conversation(task: w.task.id)
        #expect(items.map { $0.turn?.question ?? $0.change ?? "" }
                    == [Self.question, "Added 1 document to “Before”", "And now?"],
                "the documents added between the questions show between them; what changed before the first does not")
        #expect(try await talk.store.conversation(task: 999).isEmpty, "a task without questions has no conversation")
    }

    @Test func removingATaskRemovesItsConversation() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, talk) = w.h.conversations(StubAnswerer(), interpreter: StubInterpreter(plans: [:]))
        let asked = try await talk.ask(w.task.id, question: Self.question)
        try await w.tasks.delete(w.task.id)
        #expect(try await talk.store.turn(id: asked.id) == nil, "its questions go with it")
        await queue.drain()
        #expect(try await talk.store.queuedCount() == 0, "and none of them is answered")
    }

    // MARK: What the app follows

    @Test func theStatusSaysWhichQuestionIsAnsweredAndBringsItsAnswerAsItIsWritten() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let seen = Mutex<[ConversationQueueStatus]>([])
        let answerer = StubAnswerer(fallback: Self.reply) { _ in
            // The subscriber is sent the answer's first word before it is written on.
            _ = await Patience.until { seen.withLock { $0.contains { $0.answering?.progress.text == "Two" } } }
        }
        let (queue, talk) = w.h.conversations(answerer, interpreter: StubInterpreter(plans: [:]))
        let updates = await queue.statusUpdates()
        let subscriber = Task { for await status in updates { seen.withLock { $0.append(status) } } }
        defer { subscriber.cancel() }
        let asked = try await talk.ask(w.task.id, question: Self.question)
        await queue.drain()
        let model = try await w.h.env.settings.current.modelProfile().chatModel
        let answering = seen.withLock { $0.compactMap(\.answering) }.first { $0.progress.text == "Two" }
        #expect(answering?.turn == asked.id && answering?.task == w.task.id && answering?.model == model,
                "a subscriber is told which question is answered, by which model, with what has come of its answer")
        #expect(await Patience.until { seen.withLock { $0.last?.answering == nil } }, "and that nothing is answered once it is done")
    }

    @Test func whereAQuestionIsInTheQueueFollowsTheStatus() {
        let asked = TaskTurn(id: 7, task: 1, question: "?", state: .queued, answer: nil, sources: [], finding: nil, model: nil, problem: nil,
                             lastTrace: nil, asked: TestTime.start, answered: nil)
        let answering = ConversationQueueStatus.Answering(task: 1, turn: 7, model: "m", since: TestTime.start,
                                                          progress: AnswerProgress(text: "So far", thinking: false))
        let other = ConversationQueueStatus.Answering(task: 1, turn: 8, model: "m", since: TestTime.start,
                                                      progress: AnswerProgress(text: "", thinking: true))
        #expect(ConversationQueueStatus.idle.progress(of: asked) == .waiting, "next, while nothing is answered")
        #expect(ConversationQueueStatus(answering: other, queued: 1, waitingForOllama: false).progress(of: asked) == .waitingForTurn,
                "behind the question being answered")
        let retry = TestTime.start.addingTimeInterval(30)
        #expect(ConversationQueueStatus(answering: nil, queued: 1, waitingForOllama: true, retryAt: retry).progress(of: asked)
                    == .waitingForOllama(until: retry), "until Ollama can be reached, tried again then")
        var taken = asked
        taken.state = .answering
        #expect(ConversationQueueStatus(answering: answering, queued: 0, waitingForOllama: false).progress(of: taken) == .answering(answering),
                "being answered, with what has come of it")
        #expect(ConversationQueueStatus.idle.progress(of: taken) == .answering(nil), "or by another process, which this one cannot say")
        var trying = answering
        trying.progress = .notBegun
        #expect(ConversationQueueStatus(answering: trying, queued: 0, waitingForOllama: true, retryAt: retry).progress(of: taken)
                    == .waitingForOllama(until: nil), "tried again while Ollama was away, it waits for Ollama until the model begins")
        #expect(ConversationQueueStatus(answering: trying, queued: 0, waitingForOllama: false).progress(of: taken) == .answering(trying),
                "with Ollama there, it is being answered, the model not yet begun")
        var done = asked
        done.state = .answered
        #expect(ConversationQueueStatus(answering: answering, queued: 0, waitingForOllama: false).progress(of: done) == nil,
                "an answered question is in the queue no more, whatever a status not yet updated says")
        #expect(ConversationQueueStatus(answering: answering, queued: 0, waitingForOllama: false).settled.answering?.progress.text == "",
                "what a list of questions reloads on leaves out the words being written")
    }

    // MARK: The archive's record

    @Test func aConversationIsWrittenIntoTheArchiveAndComesBackAfterARebuild() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let edp = try w.id("edp_2025_03.txt")
        let answerer = StubAnswerer(replies: [Self.question: StubAnswerer.Reply(text: "Line one\nLine two", sources: [edp],
                                                                                  find: "the contract", problem: "cut off")])
        let contracts = SearchPlan(title: "Contracts", labels: [SearchTaskTests.label(.type, "contract")], words: [], grouping: [])
        let (queue, talk) = w.h.conversations(answerer, interpreter: StubInterpreter(plans: ["the contract": contracts]))
        let answered = try await talk.ask(w.task.id, question: Self.question)
        await queue.drain()
        let waiting = try await talk.ask(w.task.id, question: "Still waiting?")
        _ = try await talk.store.begin(waiting.id)

        let records = ArchiveRecords(database: w.h.env.database, settings: w.h.env.settings, config: w.h.env.config, registry: nil,
                                     time: w.h.env.time)
        try await records.flush()
        let url = w.h.env.layout.conversationFile(task: w.task.id)
        let file = try String(contentsOf: url, encoding: .utf8)
        #expect(url.path.hasSuffix("System/Conversations/_\(w.task.id).md"), "each task's conversation has a file of its own in System")
        #expect(file.contains("question: \(Self.question)") && file.contains("state: answering"),
                "with every question and its state in its front matter")
        #expect(file.contains("# \(w.task.name)") && file.contains("> \(Self.question)") && file.contains("Line one\nLine two")
                    && file.contains("Drawn from: edp_2025_03.txt (\(edp))") && file.contains("Looked for “the contract”: edp_contract.txt"),
                "and below it, for people, each question, its answer and the documents it draws on and found, by name")

        let database = try AppDatabase.inMemory()
        _ = try await ArchiveRecords(database: database, settings: w.h.env.settings, config: w.h.env.config, registry: nil,
                                     time: w.h.env.time).rebuild()
        let rebuilt = TaskConversationStore(database: database, time: w.h.env.time)
        let before = try await turn(talk, answered.id)
        let after = try #require(try await rebuilt.turn(id: answered.id))
        #expect(after.question == before.question && after.answer == before.answer && after.sources == before.sources
                    && after.finding == before.finding && after.problem == before.problem && after.model == before.model,
                "a rebuild brings the answer back as it was")
        #expect(after.lastTrace == nil, "traces are the index's own and are not kept")
        #expect(try await rebuilt.turn(id: waiting.id)?.state == .queued, "a question being answered is waiting again")

        try await w.tasks.delete(w.task.id)
        try await records.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path), "removing the task removes its conversation's file")
    }

    @Test func aConversationEditedByHandIsReadBackAndOneOfATaskThereIsNotIsLeftAside() async throws {
        let w = try await world()
        defer { w.h.env.cleanup() }
        let (queue, talk) = w.h.conversations(StubAnswerer(fallback: Self.reply), interpreter: StubInterpreter(plans: [:]))
        let asked = try await talk.ask(w.task.id, question: Self.question)
        await queue.drain()
        let records = ArchiveRecords(database: w.h.env.database, settings: w.h.env.settings, config: w.h.env.config, registry: nil,
                                     time: w.h.env.time)
        try await records.flush()
        let url = w.h.env.layout.conversationFile(task: w.task.id)
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: Self.reply.text, with: "Corrected by hand")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        let stray = w.h.env.layout.conversationFile(task: 999)
        try String(contentsOf: url, encoding: .utf8).write(to: stray, atomically: true, encoding: .utf8)
        try await records.reconcile()
        #expect(try await turn(talk, asked.id).answer == "Corrected by hand", "a correction made in the file is read back")
        #expect(try await talk.store.turns(task: 999).isEmpty, "a file of a task the index does not have is left as it is")
        #expect(w.h.env.layout.task(ofConversationFile: "_12.md") == 12 && w.h.env.layout.task(ofConversationFile: "_x.md") == nil
                    && w.h.env.layout.task(ofConversationFile: "_.md") == nil, "a conversation's file is known by its task's number")
        #expect(RecordKind(key: RecordKind.conversation(task: 12).key) == .conversation(task: 12), "and so is its mark")
    }
}

extension Array {
    /// The values `transform` makes of the elements, in order, each awaited in turn.
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
