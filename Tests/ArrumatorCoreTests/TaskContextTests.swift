@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// What an answer about a task's documents is shown (`TaskContextBuilder`, docs/how-it-works.md#talking-with-a-tasks-documents):
/// the set as it is when the question is answered, the documents the question concerns first, as much of their text as
/// the context holds, the rest by name, and the latest of the conversation so far.
@Suite struct TaskContextTests {
    private let suite = ConversationTests()

    @Test func anAnswerIsShownTheDocumentsTheQuestionConcernsFirstAsMuchTextAsFitsAndTheRestByName() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let (edp, water, meo, contract) = (try w.id("edp_2025_03.txt"), try w.id("aguas_2025_05.txt"), try w.id("meo_2025_01.txt"),
                                           try w.id("edp_contract.txt"))
        let texts = SearchTaskTests.corpus.mapValues(\.text)
        var config = w.h.env.config
        config.conversation.contextChars = try #require(texts["aguas_2025_05.txt"]).count + 1
        config.conversation.maxListed = 2
        let builder = TaskContextBuilder(database: w.h.env.database, search: w.h.search, config: config)
        let set = [edp, water, meo, contract]
        let context = try await builder.context(for: "the water bill", set: set, earlier: [])
        #expect(context.read.map(\.id) == [water] && context.read.first?.text == texts["aguas_2025_05.txt"],
                "the document the question concerns comes first, with its text, as much as fits")
        #expect(context.listed.map(\.id) == [edp, meo] && context.listed.allSatisfy { $0.text == nil },
                "the rest are listed by name, the newest by their own date first, at most conversation.maxListed")
        #expect(context.unlisted == 1, "and the answer is told how many more there are")
        #expect(context.read.first?.labels.contains(SearchTaskTests.label(.topic, "water")) == true && context.read.first?.date == "2025-05-10",
                "each with its date and labels")

        let earlier = TaskTurn(id: 1, task: w.task.id, question: "Which is the contract?", state: .answered, answer: "This one.",
                               sources: [contract], finding: nil, model: "m", problem: nil, lastTrace: nil, asked: TestTime.start, answered: nil)
        config.conversation.contextChars = try #require(texts["edp_contract.txt"]).count
        let followed = try await TaskContextBuilder(database: w.h.env.database, search: w.h.search, config: config)
            .context(for: "translate it", set: set, earlier: [earlier])
        #expect(followed.read.map(\.id) == [contract], "a question that goes on about the last answer is shown what it drew on first")

        try await w.h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET content_json = NULL WHERE id = ?", arguments: [water])
        }
        config.conversation.contextChars = 10_000
        let unread = try await TaskContextBuilder(database: w.h.env.database, search: w.h.search, config: config)
            .context(for: "the water bill", set: [water, edp], earlier: [])
        #expect(unread.listed.map(\.id) == [water] && unread.read.map(\.id) == [edp], "a document whose text is not read yet is listed by name")
        #expect(try await builder.context(for: "anything", set: [], earlier: []).documents.isEmpty, "an empty set shows nothing")
    }

    @Test func anAnswerIsShownTheLatestExchangesThatFitTheLatestCutWhenItAloneIsLonger() {
        func turn(_ id: Int64, _ question: String, _ answer: String?, _ state: TurnState = .answered) -> TaskTurn {
            TaskTurn(id: id, task: 1, question: question, state: state, answer: answer, sources: [], finding: nil, model: nil, problem: nil,
                     lastTrace: nil, asked: TestTime.start, answered: nil)
        }
        let earlier = [turn(1, "q1", "aaaa"), turn(2, "q2", "bbbb"), turn(3, "q3", nil, .failed), turn(4, "q4", "cccc")]
        #expect(TaskContextBuilder.exchanges(earlier, maxChars: 12) == [Exchange(question: "q2", answer: "bbbb"), Exchange(question: "q4", answer: "cccc")],
                "the latest exchanges that fit, the first asked first; a question without an answer is no exchange")
        #expect(TaskContextBuilder.exchanges(earlier, maxChars: 5) == [Exchange(question: "q4", answer: "ccc" + TaskContextBuilder.cut)],
                "the latest alone, cut to fit, when it is longer than all there is room for")
        #expect(TaskContextBuilder.exchanges(earlier, maxChars: 0).isEmpty, "and none without room")
    }
}
