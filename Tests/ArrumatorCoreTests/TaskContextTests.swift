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
        let context = try await builder.context(for: "the water bill", set: set, earlier: []).shown
        #expect(context.read.map(\.id) == [water] && context.read.first?.text == texts["aguas_2025_05.txt"],
                "the document the question concerns comes first, with its text, as much as fits")
        #expect(context.listed.map(\.id) == [edp, meo] && context.listed.allSatisfy { $0.text == nil },
                "the rest are listed by name, the newest by their own date first, at most conversation.maxListed")
        #expect(context.unlisted == 1, "and the answer is told how many more there are")
        #expect(context.read.first?.labels.contains(SearchTaskTests.label(.topic, "water")) == true && context.read.first?.date == "2025-05-10",
                "each with its date and labels")

        let earlier = TaskTurn(id: 1, task: w.task.id, question: "Which is the contract?", state: .answered, answer: "This one.",
                               sources: [contract], finding: nil, model: "m", problem: nil, lastTrace: nil, asked: TestTime.start, answered: nil,
                               retryAt: nil)
        config.conversation.contextChars = try #require(texts["edp_contract.txt"]).count
        let followed = try await TaskContextBuilder(database: w.h.env.database, search: w.h.search, config: config)
            .context(for: "translate it", set: set, earlier: [earlier]).shown
        #expect(followed.read.map(\.id) == [contract], "a question that goes on about the last answer is shown what it drew on first")

        try await w.h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET content_json = NULL WHERE id = ?", arguments: [water])
        }
        config.conversation.contextChars = 10_000
        let unread = try await TaskContextBuilder(database: w.h.env.database, search: w.h.search, config: config)
            .context(for: "the water bill", set: [water, edp], earlier: []).shown
        #expect(unread.listed.map(\.id) == [water] && unread.read.map(\.id) == [edp], "a document whose text is not read yet is listed by name")
        #expect(try await builder.context(for: "anything", set: [], earlier: []).shown.documents.isEmpty, "an empty set shows nothing")
    }

    /// Twelve documents in the order a question concerns them, by number, and the text of each as an answer would be
    /// shown it: the third has none yet; the fourth and sixth are short; the rest are as long as `room` holds 1 of.
    static let ranked: [Int64] = Array(1...12)
    static let room = 100
    static let texts: [Int64: String] = Dictionary(uniqueKeysWithValues: ranked.compactMap { id in
        switch id {
        case 3: nil
        case 4: (id, String(repeating: "d", count: 30))
        case 6: (id, String(repeating: "f", count: 5))
        default: (id, String(repeating: "x", count: 60))
        }
    })

    /// `TaskContextBuilder.choose` over `ranked` with `room` and `maxListed`, the documents' texts `texts`, and the
    /// documents whose text it read.
    static func choose(room: Int, maxListed: Int, texts: [Int64: String] = texts) throws -> (read: [Int64], listed: [Int64], textsRead: [Int64]) {
        var textsRead: [Int64] = []
        let chosen = try TaskContextBuilder.choose(ranked, room: room, maxListed: maxListed, hasText: { texts[$0] != nil }, record: { id in
            var document = DocumentRecord.arrived(path: "/archive/\(id).pdf", sha256: "\(id)", size: 1, uttype: "com.adobe.pdf", inode: nil,
                                                  modified: nil, now: TestTime.start)
            document.id = id
            return document
        }, text: { document in
            let id = try #require(document.id)
            textsRead.append(id)
            return texts[id]
        })
        return (chosen.read.map(\.id), chosen.listed.map(\.id), textsRead)
    }

    @Test func onlyTheTextOfTheDocumentsShownOrListedIsRead() throws {
        let fitting = try Self.choose(room: Self.room, maxListed: 2)
        #expect(fitting.read == [1, 4] && fitting.listed == [2, 3], "what fits is shown with its text, the rest listed, at most conversation.maxListed")
        #expect(fitting.textsRead == [1, 2, 3, 4, 5],
                "and once the list is full, the first whose text is too long for the room left ends the choice: the text of the set's other seven is never read")
        let full = try Self.choose(room: 120, maxListed: 2)
        #expect(full.read == [1, 2] && full.listed == [3, 4] && full.textsRead == [1, 2],
                "with no room left for any text, the documents listed are listed by name, and no more text is read")
        let whole = try Self.choose(room: 10_000, maxListed: 2)
        #expect(whole.read == Self.ranked.filter { $0 != 3 } && whole.listed == [3], "a set the context holds is shown whole")
    }

    @Test func aDocumentWithoutTextNeverEndsTheChoice() throws {
        // The first three have no text yet; the rest are short enough for the room to hold them all.
        let texts = Dictionary(uniqueKeysWithValues: Self.ranked.filter { $0 > 3 }.map { ($0, String(repeating: "x", count: 5)) })
        let chosen = try Self.choose(room: Self.room, maxListed: 2, texts: texts)
        #expect(chosen.listed == [1, 2] && chosen.read == Array(4...12),
                "once the list is full, a document without text is passed over, and those after it are shown with their text")
        #expect(chosen.textsRead == [1, 2] + Array(4...12), "and the one passed over is not read")
    }

    @Test func aDocumentNotReadYetIsPassedOverOnceTheListIsFull() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let (edp, water, meo) = (try w.id("edp_2025_03.txt"), try w.id("aguas_2025_05.txt"), try w.id("meo_2025_01.txt"))
        try await w.h.env.database.writer.write { db in
            try db.execute(sql: "UPDATE documents SET content_json = NULL WHERE id = ?", arguments: [water])
        }
        var config = w.h.env.config
        config.conversation.maxListed = 0
        config.conversation.contextChars = 10_000
        let chosen = try await TaskContextBuilder(database: w.h.env.database, search: w.h.search, config: config)
            .context(for: "the water bill", set: [water, edp, meo], earlier: []).shown
        #expect(Set(chosen.read.map(\.id)) == [edp, meo] && chosen.listed.isEmpty && chosen.unlisted == 1,
                "the document the question concerns most, not read yet, is counted, and the others after it are shown with their text")
    }

    @Test func theChoiceSaysWhetherTheQuestionsMeaningOrderedTheDocuments() async throws {
        let w = try await suite.world()
        defer { w.h.env.cleanup() }
        let (edp, water) = (try w.id("edp_2025_03.txt"), try w.id("aguas_2025_05.txt"))
        let config = w.h.env.config
        let words = try await TaskContextBuilder(database: w.h.env.database, search: w.h.search, config: config)
            .context(for: "the water bill", set: [edp, water], earlier: [])
        #expect(!words.semanticUsed && words.semanticUnavailableReason == SearchService.noEmbedder,
                "without an embedding model the words alone order the documents, and the choice says why")
        let meaning = SearchService(database: w.h.env.database, vectors: await SearchTests.vectors([(water, 0.9), (edp, 0.1)]),
                                    embedder: SearchTests.FixedEmbedder(vector: [1, 0]), config: config.search, time: w.h.env.time)
        let both = try await TaskContextBuilder(database: w.h.env.database, search: meaning, config: config)
            .context(for: "the water bill", set: [edp, water], earlier: [])
        #expect(both.semanticUsed && both.semanticUnavailableReason == nil && both.shown.documents.first?.id == water,
                "with one, its meaning orders them too")
    }

    @Test func anAnswerIsShownTheLatestExchangesThatFitTheLatestCutWhenItAloneIsLonger() {
        func turn(_ id: Int64, _ question: String, _ answer: String?, _ state: TurnState = .answered) -> TaskTurn {
            TaskTurn(id: id, task: 1, question: question, state: state, answer: answer, sources: [], finding: nil, model: nil, problem: nil,
                     lastTrace: nil, asked: TestTime.start, answered: nil, retryAt: nil)
        }
        let earlier = [turn(1, "q1", "aaaa"), turn(2, "q2", "bbbb"), turn(3, "q3", nil, .failed), turn(4, "q4", "cccc")]
        #expect(TaskContextBuilder.exchanges(earlier, maxChars: 12) == [Exchange(question: "q2", answer: "bbbb"), Exchange(question: "q4", answer: "cccc")],
                "the latest exchanges that fit, the first asked first; a question without an answer is no exchange")
        #expect(TaskContextBuilder.exchanges(earlier, maxChars: 5) == [Exchange(question: "q4", answer: "ccc" + TaskContextBuilder.cut)],
                "the latest alone, cut to fit, when it is longer than all there is room for")
        #expect(TaskContextBuilder.exchanges(earlier, maxChars: 0).isEmpty, "and none without room")
    }
}
